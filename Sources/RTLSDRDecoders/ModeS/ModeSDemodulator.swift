// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A Mode S frame found in the sample stream, parity checked.
public struct ModeSFrame: Sendable, Equatable {
    public var message: ModeSMessage
    /// Index of the preamble's first sample in the whole stream (2 MS/s, so 0.5 µs per sample).
    public var sampleIndex: Int
    /// Signal level of the preamble pulses, dB relative to full scale.
    public var signalDBFS: Double
    /// Bit repaired by the parity check, if any.
    public var correctedBit: Int?
}

/// Finds Mode S replies and ADS-B squitters (1090 MHz) in interleaved unsigned 8-bit I/Q sampled at 2 MS/s.
///
/// Mode S is pulse-position modulated at 1 Mbit/s: a preamble of four 0.5 µs pulses (at 0, 1, 3.5 and 4.5 µs), then
/// from 8 µs one bit per microsecond, a 1 being a pulse in the first half and a 0 in the second. At 2 MS/s that is two
/// samples per bit. Frames are accepted only if their parity checks:
///
/// * DF17/18 (ADS-B): the CRC must be zero. One wrong bit (never a format bit) is repaired, but only for an address
///   already confirmed, because noise would otherwise pass once in about 2^16 tries.
/// * DF11 (all-call reply): the CRC must be zero, or differ only in the 7-bit interrogator code for a confirmed address.
/// * Replies that overlay the address on the parity (DF0/4/5/16/20/21): accepted only when the recovered address was
///   recently confirmed, since any bit pattern "recovers" some address.
///
/// An address is confirmed by a zero-syndrome DF17, DF11 or DF18 (CF 0) frame, or by `confirm(address:)`; frames that
/// were accepted only because their address was known do not extend its life.
///
/// Feed blocks in order with `process`; state carries across blocks, so frames straddling a boundary are found.
public final class ModeSDemodulator {
    public static let sampleRate = 2_000_000

    /// Magnitude of each (I, Q) byte pair, scaled so that full scale (127.5) is about 23 000.
    private static let magnitudes: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 65_536)
        for i in 0..<256 {
            for q in 0..<256 {
                let x = Double(i) - 127.5, y = Double(q) - 127.5
                table[i << 8 | q] = UInt16(min(65_535, ((x * x + y * y).squareRoot() * 180).rounded()))
            }
        }
        return table
    }()
    private static let fullScale = 127.5 * 180

    private static let preambleSamples = 16
    private static let longFrameSamples = preambleSamples + 112 * 2

    /// How long an address stays "confirmed", in samples (60 s).
    public var addressLifetimeSamples = 60 * sampleRate
    /// Repair single-bit errors in DF17/18.
    public var correctsSingleBitErrors = true

    private var carry: [UInt16] = []           // magnitudes not yet fully examined, from the previous block
    private var carryStart = 0                 // stream index of carry[0]
    private var pendingByte: UInt8?            // an I without its Q, when a block had an odd length
    private var knownAddresses: [UInt32: Int] = [:]
    public private(set) var framesFound = 0

    public init() {}

    /// Marks `address` as confirmed (for example from another receiver) until `addressLifetimeSamples` from now.
    public func confirm(address: UInt32) {
        knownAddresses[address] = carryStart + carry.count
    }

    public func process(_ block: [UInt8]) -> [ModeSFrame] {
        block.withUnsafeBufferPointer { process($0) }
    }

    public func process(_ block: UnsafeBufferPointer<UInt8>) -> [ModeSFrame] {
        var magnitude = carry
        magnitude.reserveCapacity(carry.count + block.count / 2 + 1)
        var next = 0
        if let i = pendingByte, !block.isEmpty {
            magnitude.append(Self.magnitudes[Int(i) << 8 | Int(block[0])])
            pendingByte = nil
            next = 1
        }
        while next + 1 < block.count {
            magnitude.append(Self.magnitudes[Int(block[next]) << 8 | Int(block[next + 1])])
            next += 2
        }
        if next < block.count { pendingByte = block[next] }
        return scan(magnitude, lookAhead: true)
    }

    /// Examines the samples still held back as look-ahead. Call once, at the end of a recording.
    public func flush() -> [ModeSFrame] {
        pendingByte = nil
        return scan(carry, lookAhead: false)
    }

    private func scan(_ input: [UInt16], lookAhead: Bool) -> [ModeSFrame] {
        // Without look-ahead the stream has ended: pad with silence so that short frames near the end can be read.
        let magnitude = lookAhead ? input : input + [UInt16](repeating: 0, count: Self.longFrameSamples)
        let base = carryStart
        var frames: [ModeSFrame] = []
        var index = 0
        let lastStart = lookAhead ? magnitude.count - Self.longFrameSamples : input.count - 1
        while index <= lastStart {
            if let frame = frame(at: index, in: magnitude, streamIndex: base + index) {
                frames.append(frame)
                index += Self.preambleSamples + frame.message.bytes.count * 16
            } else {
                index += 1
            }
        }
        // Keep what could still start a frame once more samples arrive.
        let keepFrom = min(max(0, index), input.count)
        carry = lookAhead ? Array(input[keepFrom...]) : []
        carryStart = base + (lookAhead ? keepFrom : input.count)
        framesFound += frames.count
        let now = carryStart
        if knownAddresses.count > 4096 || frames.count > 0 {
            knownAddresses = knownAddresses.filter { now - $0.value < addressLifetimeSamples }
        }
        return frames
    }

    /// Checks for a preamble at `start` and, if there is one, tries to decode the frame after it.
    private func frame(at start: Int, in m: [UInt16], streamIndex: Int) -> ModeSFrame? {
        func at(_ offset: Int) -> Int { Int(m[start + offset]) }
        let p0 = at(0), p1 = at(1), p2 = at(2), p3 = at(3), p4 = at(4), p5 = at(5), p6 = at(6)
        let p7 = at(7), p8 = at(8), p9 = at(9), p10 = at(10)

        // Pulses at samples 0, 2, 7 and 9 with gaps between them: the classic pattern, for pulses that start on (or
        // close to) a sample boundary.
        // This runs for every sample, so it sticks to scalar arithmetic and rejects the common case (noise) early.
        let q11 = at(11), q12 = at(12), q13 = at(13), q14 = at(14)
        var aligned = p0 > p1 && p1 < p2 && p2 > p3 && p3 < p0 && p4 < p0 && p5 < p0 && p6 < p0 && p7 > p8 && p8 < p9 && p9 > p6
        if aligned {
            let high = (p0 + p2 + p7 + p9) / 6
            aligned = p4 < high && p5 < high && q11 < high && q12 < high && q13 < high && q14 < high
        }

        // A pulse that starts part-way through a sample puts the rest of its energy in the next one, which breaks the
        // comparisons above. Then each pulse's two samples together must stand well above every quiet sample (4-6 and
        // 11-14 are empty for any straddle under a whole sample).
        let pairA = p0 + p1, pairB = p2 + p3, pairC = p7 + p8, pairD = p9 + p10
        let weakest = min(min(pairA, pairB), min(pairC, pairD))
        if !aligned {
            let loudestQuiet = max(max(max(p4, p5), max(p6, q11)), max(max(q12, q13), q14))
            guard weakest > loudestQuiet else { return nil }
        }
        let total = pairA + pairB + pairC + pairD
        let split = Double(p1 + p3 + p8 + p10) / Double(max(1, total))
        if !aligned {
            // Straddles over three quarters of a sample are left to the next start position, where they read as
            // under a quarter: each frame is then accepted at one position only.
            let strongest = max(max(pairA, pairB), max(pairC, pairD))
            let quietSum = p4 + p5 + p6 + q11 + q12 + q13 + q14
            guard split <= 0.75, weakest * 2 > strongest, weakest * 7 > 3 * quietSum else { return nil }
        }

        // First attempt: a bit is 1 when its first half carries more energy. Second: the straddle model.
        let preamble = aligned ? (p0, p2, p7, p9) : (pairA, pairB, pairC, pairD)
        if split < 0.5, let frame = accept(slice(m, start), preamble: preamble, streamIndex: streamIndex) { return frame }
        guard split > 0.05 else { return nil }
        return accept(sliceStraddled(m, start, split: split, amplitude: Double(total) / 4), preamble: preamble, streamIndex: streamIndex)
    }

    /// Bits by comparing the two halves of each bit period.
    private func slice(_ m: [UInt16], _ start: Int) -> [UInt8] {
        func bit(_ index: Int) -> Bool { m[start + 16 + 2 * index] > m[start + 17 + 2 * index] }
        var format = 0
        for index in 0..<5 { format = format << 1 | (bit(index) ? 1 : 0) }
        var message = [UInt8](repeating: 0, count: format >= 16 ? 14 : 7)
        for index in 0..<(message.count * 8) where bit(index) { message[index / 8] |= 0x80 >> UInt8(index % 8) }
        return message
    }

    /// Bits for pulses that start `split` of a sample late: a pulse puts (1 - split) of its amplitude in its own sample
    /// and `split` in the next, so a 0 (pulse in the second half) spills into the first half of the following bit. Each
    /// bit is the hypothesis whose expected pair of samples is nearer, given the bit before it.
    private func sliceStraddled(_ m: [UInt16], _ start: Int, split: Double, amplitude: Double) -> [UInt8] {
        let own = (1 - split) * amplitude, spill = split * amplitude
        var previousWasZero = false
        var bits: [Bool] = []
        func decide(_ index: Int) -> Bool {
            let first = Double(m[start + 16 + 2 * index]), second = Double(m[start + 17 + 2 * index])
            let carried = previousWasZero ? spill : 0
            let one = (first - own - carried) * (first - own - carried) + (second - spill) * (second - spill)
            let zero = (first - carried) * (first - carried) + (second - own) * (second - own)
            let bit = one < zero
            previousWasZero = !bit
            return bit
        }
        for index in 0..<5 { bits.append(decide(index)) }
        let format = bits.reduce(0) { $0 << 1 | ($1 ? 1 : 0) }
        let count = format >= 16 ? 112 : 56
        for index in 5..<count { bits.append(decide(index)) }
        var message = [UInt8](repeating: 0, count: count / 8)
        for (index, bit) in bits.enumerated() where bit { message[index / 8] |= 0x80 >> UInt8(index % 8) }
        return message
    }

    /// Parity checks a candidate and builds the frame.
    private func accept(_ candidate: [UInt8], preamble: (Int, Int, Int, Int), streamIndex: Int) -> ModeSFrame? {
        var message = candidate
        let format = Int(message[0] >> 3)

        func known(_ address: UInt32) -> Bool {
            guard let seen = knownAddresses[address] else { return false }
            return streamIndex - seen < addressLifetimeSamples
        }
        func addressField(_ bytes: [UInt8]) -> UInt32 { UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) }

        // Noise passes a zero-syndrome check about once in 2^24 tries. Looser acceptances (a repaired bit, an
        // interrogator code, an address recovered from parity) are only trusted for addresses already confirmed.
        var corrected: Int?
        var recovered: UInt32?
        let syndrome = ModeSCRC.syndrome(message)
        // Only a clean frame that carries a real ICAO address confirms it: DF17, DF11 with no interrogator code, and
        // DF18 with CF 0. (Other DF18 control fields carry anonymous or TIS-B track addresses.)
        let confirms = syndrome == 0 && (format == 17 || format == 11 || (format == 18 && message[0] & 0x07 == 0))
        switch format {
        case 17, 18:
            if syndrome != 0 {
                var repaired = message
                guard correctsSingleBitErrors, let bit = ModeSCRC.correctSingleBit(&repaired), known(addressField(repaired)) else { return nil }
                message = repaired
                corrected = bit
            }
        case 11:
            guard syndrome == 0 || (syndrome & 0xFFFF80 == 0 && known(addressField(message))) else { return nil }
        case 0, 4, 5, 16, 20, 21:
            guard known(syndrome) else { return nil }
            recovered = syndrome
        default:
            return nil
        }

        let decoded = ModeSMessage(bytes: message, address: recovered)
        if confirms { knownAddresses[decoded.address] = streamIndex }
        let level = Double(preamble.0 + preamble.1 + preamble.2 + preamble.3) / 4 / Self.fullScale
        return ModeSFrame(message: decoded, sampleIndex: streamIndex, signalDBFS: 20 * log10(max(level, 1e-6)), correctedBit: corrected)
    }
}
