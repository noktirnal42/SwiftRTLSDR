// SPDX-License-Identifier: GPL-2.0-or-later
//
// LRPT framing: from soft QPSK symbols to error-corrected CADUs (CCSDS transfer frames with a 0x1ACFFC1D marker,
// randomised, Reed-Solomon (255,223) interleaved 4 deep). The structure (find the encoded marker in each CADU-length
// window, derotate, Viterbi-decode with the traceback delay carried into the next window) and the correlator, soft-bit
// helpers and derandomiser are ported from meteor_decode by dbdexter-dev (MIT licence,
// https://github.com/dbdexter-dev/meteor_decode: decode.c, correlator/correlator.c, utils.c, ecc/descramble.c;
// copyright notice in NOTICE). NRZ-M is undone on the decoded bits, where SatDump undoes it for Meteor-M N2-3/N2-4
// (its "M2-x" pipeline). See PROVENANCE.md.

/// Constants of the Meteor-M LRPT link.
public enum LRPT {
    public static let frequencies = [137_100_000, 137_900_000]
    public static let symbolRate = 72_000
    public static let syncWord: UInt32 = 0x1acf_fc1d
    public static let caduBytes = 1024            // marker + 1020
    static let caduSoftSymbols = caduBytes * 8 * 2
    static let correlationThreshold = 42          // of 64: a marker right at the window start is taken at once

    /// How the satellite transmits: Meteor-M N2 used plain QPSK; N2-3 and N2-4 use offset QPSK with NRZ-M
    /// (differentially coded) data.
    public enum Mode: String, Sendable, CaseIterable {
        case qpsk            // Meteor-M N2 (and N2-2 early on): QPSK, 72 ksym/s
        case oqpskNRZM       // Meteor-M N2-3, N2-4: OQPSK, NRZ-M, 72 ksym/s
        public var isOffset: Bool { self == .oqpskNRZM }
        public var isDifferential: Bool { self == .oqpskNRZM }
    }

    /// The CCSDS pseudo-random sequence (x^8 + x^7 + x^5 + x^3 + 1, all ones at start), 255 bytes, XORed over the
    /// 1020 bytes after the marker.
    static let pseudoNoise: [UInt8] = {
        var noise = [UInt8](repeating: 0, count: 255)
        var state: UInt8 = 0xff
        for index in 0..<255 {
            for _ in 0..<8 {
                let newBit = (state >> 7 & 1) ^ (state >> 5 & 1) ^ (state >> 3 & 1) ^ (state & 1)
                noise[index] = noise[index] << 1 | (state & 1)
                state = (state >> 1) | (newBit << 7)
            }
        }
        return noise
    }()

    /// The Reed-Solomon code of the frames, in the conventional (not dual) basis.
    static let reedSolomon = ReedSolomon(length: 255, parityCount: 32, polynomial: 0x187, firstRoot: 112, rootStep: 11)

    /// Randomises (or derandomises) the 1020 bytes after the marker.
    static func derandomize(_ cadu: inout [UInt8]) {
        for index in 0..<1020 { cadu[4 + index] ^= pseudoNoise[index % 255] }
    }

    /// Corrects the four interleaved codewords of a CADU in place. Returns the symbols corrected, or nil if any
    /// codeword is beyond repair.
    static func correct(_ cadu: inout [UInt8]) -> Int? {
        var total = 0
        var failed = false
        var block = [UInt8](repeating: 0, count: 255)
        for interleave in 0..<4 {
            for j in 0..<255 { block[j] = cadu[4 + j * 4 + interleave] }
            if let fixed = reedSolomon.correct(&block) {
                total += fixed
                for j in 0..<255 { cadu[4 + j * 4 + interleave] = block[j] }
            } else {
                failed = true
            }
        }
        return failed ? nil : total
    }

    /// Adds the parity of the four interleaved codewords (bytes 4 + 892 ... 1023) to a CADU: for making test signals.
    static func addParity(_ cadu: inout [UInt8]) {
        for interleave in 0..<4 {
            let data = (0..<223).map { cadu[4 + $0 * 4 + interleave] }
            for (j, parity) in reedSolomon.parity(for: data).enumerated() { cadu[4 + (223 + j) * 4 + interleave] = parity }
        }
    }
}

/// QPSK phase ambiguities the correlator resolves.
enum LRPTPhase: Int {
    case p0 = 0, p90, p180, p270
}

enum SoftBits {
    /// Hard decisions (negative = 1), packed MSB first; `count` must be a multiple of 8.
    static func hard(_ soft: UnsafeBufferPointer<Int8>, from start: Int, count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count / 8)
        for index in 0..<count where soft[start + index] < 0 { out[index >> 3] |= 0x80 >> UInt8(index & 7) }
        return out
    }

    /// Undoes a rotation of the (I, Q) pairs in place (after limiting to ±127 so that negation cannot overflow).
    static func derotate(_ soft: inout [Int8], from start: Int, count: Int, _ phase: LRPTPhase) {
        for index in start..<(start + count) { soft[index] = max(-127, soft[index]) }
        var index = start
        switch phase {
        case .p0: break
        case .p270:
            while index + 1 < start + count {
                let tmp = soft[index]; soft[index] = -soft[index + 1]; soft[index + 1] = tmp; index += 2
            }
        case .p180:
            for index in start..<(start + count) { soft[index] = -soft[index] }
        case .p90:
            while index + 1 < start + count {
                let tmp = soft[index]; soft[index] = soft[index + 1]; soft[index + 1] = -tmp; index += 2
            }
        }
    }
}

/// Finds the encoded frame marker in hard bits, at any bit offset and in any of the four QPSK rotations.
struct LRPTCorrelator {
    private let words: [UInt64]

    /// `differential`: the marker as NRZ-M coding leaves it (from a zero start; the other start is its complement,
    /// which the 180° rotation covers).
    init(differential: Bool) {
        var marker = LRPT.syncWord
        if differential {
            var previous: UInt32 = 0, coded: UInt32 = 0
            for bit in (0..<32).reversed() {
                previous ^= (marker >> UInt32(bit)) & 1
                coded |= previous << UInt32(bit)
            }
            marker = coded
        }
        let encoded = ConvolutionalEncoder.encodeWord(marker)
        words = (0..<4).map { phase in
            let rotated = Self.rotate(encoded, LRPTPhase(rawValue: phase)!)
            return ((rotated & 0x5555_5555_5555_5555) << 1) | ((rotated & 0xaaaa_aaaa_aaaa_aaaa) >> 1)
        }
    }

    private static func rotate(_ word: UInt64, _ phase: LRPTPhase) -> UInt64 {
        let i = word & 0xaaaa_aaaa_aaaa_aaaa, q = word & 0x5555_5555_5555_5555
        switch phase {
        case .p0: return word
        case .p90: return ((i ^ 0xaaaa_aaaa_aaaa_aaaa) >> 1) | (q << 1)
        case .p180: return ~word
        case .p270: return (i >> 1) | ((q ^ 0x5555_5555_5555_5555) << 1)
        }
    }

    private static func agreement(_ x: UInt64, _ y: UInt64) -> Int { 64 - (x ^ y).nonzeroBitCount }

    /// The best (bit offset, rotation, agreement out of 64). An offset of 0 wins at once above the threshold.
    func correlate(_ hard: [UInt8]) -> (offset: Int, phase: LRPTPhase, score: Int) {
        var window: UInt64 = 0
        for index in 0..<8 { window = window << 8 | UInt64(hard[index]) }
        for phase in 0..<4 where Self.agreement(words[phase], window) > LRPT.correlationThreshold {
            return (0, LRPTPhase(rawValue: phase)!, Self.agreement(words[phase], window))
        }
        var best = 0, bestOffset = 0, bestPhase = LRPTPhase.p0
        for index in 0..<(hard.count - 8) {
            let byte = hard[index + 8]
            for bit in 0..<8 {
                for phase in 0..<4 {
                    let score = Self.agreement(words[phase], window)
                    if score > best {
                        best = score
                        bestOffset = index * 8 + bit
                        bestPhase = LRPTPhase(rawValue: phase)!
                    }
                }
                window = (window << 1) | UInt64((byte >> (7 - UInt8(bit))) & 1)
            }
        }
        return (bestOffset, bestPhase, best)
    }
}

/// One CADU off the air: its 1024 bytes after decoding, derandomising and (if possible) correction.
public struct LRPTFrame: Sendable {
    public var bytes: [UInt8]
    /// Symbols the Reed-Solomon code corrected, or nil if it could not (the bytes are then as received).
    public var corrected: Int?
    /// meteor_decode's Viterbi quality figure: the average path metric per byte (lower is better, ~1100 decodes).
    public var viterbiMetric: Int
    /// How well the marker matched (of 64) and where it was found.
    public var markerScore: Int
    public var markerOffset: Int

    public var isValid: Bool { corrected != nil }
    public var spacecraftID: Int { Int(bytes[4] & 0x3f) << 2 | Int(bytes[5] >> 6) }
    public var virtualChannel: Int { Int(bytes[5] & 0x3f) }
    public var counter: Int { Int(bytes[6]) << 16 | Int(bytes[7]) << 8 | Int(bytes[8]) }
}

/// Turns a stream of soft symbols (signed bytes, I then Q, negative = 1) into frames. Feed any amount at a time.
public final class LRPTFrameDecoder {
    public let mode: LRPT.Mode
    private let correlator: LRPTCorrelator
    private let viterbi = ViterbiDecoder()
    private var soft: [Int8] = []
    private var start = 0                          // where the next window begins in `soft`
    private var pending = [UInt8](repeating: 0, count: LRPT.caduBytes)   // the frame whose last bytes are still to come
    private var pendingMetric = 0
    private var pendingScore = 0
    private var pendingOffset = 0
    private var hasPending = false
    private var lastRawBit: UInt8 = 0              // NRZ-M: the last coded bit of the previous frame

    public init(mode: LRPT.Mode) {
        self.mode = mode
        correlator = LRPTCorrelator(differential: mode.isDifferential)
    }

    public func process(_ symbols: [Int8]) -> [LRPTFrame] {
        soft += symbols
        var frames: [LRPTFrame] = []
        // A window, and room for the marker anywhere in it.
        while soft.count - start >= 2 * LRPT.caduSoftSymbols, let produced = step() {
            frames += produced
        }
        if start > 4 * LRPT.caduSoftSymbols {
            soft.removeFirst(start)
            start = 0
        }
        return frames
    }

    /// Decodes one window: nil if the symbols it needs have not all arrived.
    private func step() -> [LRPTFrame]? {
        let length = LRPT.caduSoftSymbols
        guard soft.count - start >= length else { return nil }
        let hard = soft.withUnsafeBufferPointer { SoftBits.hard($0, from: start, count: length) }
        let (offset, phase, score) = correlator.correlate(hard)
        let window = start + offset
        guard window + length <= soft.count else { return nil }
        SoftBits.derotate(&soft, from: window, count: length, phase)

        var frames: [LRPTFrame] = []
        let delay = ViterbiDecoder.delayBytes
        soft.withUnsafeBufferPointer { buffer in
            // The first 8 bytes' worth of symbols finish the previous frame (the traceback runs 8 bytes behind).
            let finishing = viterbi.decode(into: &pending, at: LRPT.caduBytes - delay, soft: buffer, at: window, byteCount: delay)
            if hasPending {
                frames.append(finish(metric: pendingMetric + finishing))
            }
            // The rest start this frame.
            pendingMetric = viterbi.decode(into: &pending, at: 0, soft: buffer, at: window + 2 * 8 * delay, byteCount: LRPT.caduBytes - delay)
        }
        pendingScore = score
        pendingOffset = offset
        hasPending = true
        start = window + length
        return frames
    }

    private func finish(metric: Int) -> LRPTFrame {
        var bytes = pending
        if mode.isDifferential {
            // NRZ-M: a data bit is the change between consecutive coded bits.
            var previous = lastRawBit
            for index in 0..<bytes.count {
                let coded = bytes[index]
                bytes[index] = coded ^ ((coded >> 1) | (previous << 7))
                previous = coded & 1
            }
            lastRawBit = previous
        }
        LRPT.derandomize(&bytes)
        let corrected = LRPT.correct(&bytes)
        return LRPTFrame(bytes: bytes, corrected: corrected, viterbiMetric: metric / LRPT.caduBytes,
                         markerScore: pendingScore, markerOffset: pendingOffset)
    }

    /// Ends the stream: decodes what is left, then the frame still held back (its last bytes decoded from silence).
    public func flush() -> [LRPTFrame] {
        var frames: [LRPTFrame] = []
        while let produced = step() { frames += produced }
        if hasPending {
            let silence = [Int8](repeating: 0, count: 2 * 8 * ViterbiDecoder.delayBytes)
            let finishing = silence.withUnsafeBufferPointer {
                viterbi.decode(into: &pending, at: LRPT.caduBytes - ViterbiDecoder.delayBytes, soft: $0, at: 0, byteCount: ViterbiDecoder.delayBytes)
            }
            frames.append(finish(metric: pendingMetric + finishing))
            hasPending = false
        }
        soft.removeAll()
        start = 0
        return frames
    }
}
