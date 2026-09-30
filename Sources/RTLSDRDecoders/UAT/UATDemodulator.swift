// SPDX-License-Identifier: GPL-2.0-or-later
//
// UAT demodulation, following the method of dump978.c by Oliver Jowett (GPL-2.0-or-later,
// https://github.com/mutability/dump978): phase differences between samples, a fuzzy sync-word search, a slicing
// threshold taken from the sync word, then Reed-Solomon. See PROVENANCE.md.
import Foundation

/// Finds UAT frames (978 MHz) in interleaved unsigned 8-bit I/Q sampled at 2.083334 MS/s (two samples per bit).
///
/// UAT is binary continuous-phase FSK at 1.041667 Mbit/s: the phase advances for a 1 and retreats for a 0. Every frame
/// starts with a 36-bit sync word (one for aircraft, its inverse for ground stations). The search runs on both
/// sample phases and tolerates up to 4 wrong sync bits; the threshold between "advancing" and "retreating" is the
/// middle of the two averages seen in the sync word, which absorbs a frequency offset. Frames are accepted only if the
/// Reed-Solomon code can repair them. Feed blocks in order; state carries across blocks.
public final class UATDemodulator {
    public static let sampleRate = UAT.sampleRate

    /// The phase of each (I, Q) pair, 0 ..< 65536 for 0 ..< 2π.
    private static let phases: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 65_536)
        for i in 0..<256 {
            for q in 0..<256 {
                let angle = atan2(Double(q) - 127.5, Double(i) - 127.5) + .pi
                table[i << 8 | q] = UInt16(min(65_535, max(0, (32_768 * angle / .pi).rounded())))
            }
        }
        return table
    }()

    private static let maximumSyncErrors = 4
    private static let frameBits = [UAT.basicFrameBytes, UAT.longFrameBytes, UAT.uplinkFrameBytes].map { $0 * 8 }
    private static let longestFrameBits = UAT.uplinkFrameBytes * 8

    private var carry: [UInt16] = []
    private var carryStart = 0
    public private(set) var framesFound = 0

    public init() {}

    public func process(_ block: [UInt8]) -> [UATFrame] {
        block.withUnsafeBufferPointer { process($0) }
    }

    public func process(_ block: UnsafeBufferPointer<UInt8>) -> [UATFrame] {
        var phi = carry
        phi.reserveCapacity(carry.count + block.count / 2)
        for pair in 0..<(block.count / 2) { phi.append(Self.phases[Int(block[2 * pair]) << 8 | Int(block[2 * pair + 1])]) }

        var frames: [UATFrame] = []
        var sync0: UInt64 = 0, sync1: UInt64 = 0
        let mask: UInt64 = (1 << UInt64(UAT.syncBits)) - 1
        let lastBit = phi.count / 2 - (UAT.syncBits + Self.longestFrameBits)
        var bit = 0
        while bit < lastBit {
            sync0 = ((sync0 << 1) | (Self.difference(phi[2 * bit], phi[2 * bit + 1]) > 0 ? 1 : 0)) & mask
            sync1 = ((sync1 << 1) | (Self.difference(phi[2 * bit + 1], phi[2 * bit + 2]) > 0 ? 1 : 0)) & mask
            defer { bit += 1 }
            guard bit >= UAT.syncBits else { continue }

            for (sync, kind) in [(UAT.downlinkSync, UATFrame.Kind.downlink), (UAT.uplinkSync, .uplink)] {
                let first = Self.close(sync0, sync), second = Self.close(sync1, sync)
                guard first || second else { continue }
                let startBit = bit - UAT.syncBits + 1
                let index = startBit * 2 + (first ? 0 : 1)
                // The match may be a sample early or late: demodulate at both and keep the one needing fewer repairs.
                let a = demodulate(phi, at: index, sync: sync, kind: kind)
                let b = demodulate(phi, at: index + 1, sync: sync, kind: kind)
                let best: (frame: UATFrame, bits: Int, at: Int)?
                switch (a, b) {
                case let (a?, b?): best = a.frame.correctedSymbols <= b.frame.correctedSymbols ? (a.frame, a.bits, index) : (b.frame, b.bits, index + 1)
                case let (a?, nil): best = (a.frame, a.bits, index)
                case let (nil, b?): best = (b.frame, b.bits, index + 1)
                default: best = nil
                }
                if let best {
                    var frame = best.frame
                    frame.sampleIndex = carryStart + best.at
                    frames.append(frame)
                    // Skip the frame; the sync registers refill from the samples after it.
                    bit = startBit + best.bits - 1
                    sync0 = 0
                    sync1 = 0
                }
                break
            }
        }
        // Keep the last sync word's worth of bits too, so a sync word split across blocks is still found.
        let keepFrom = max(0, min(phi.count, (bit - UAT.syncBits) * 2))
        carry = Array(phi[keepFrom...])
        carryStart += keepFrom
        framesFound += frames.count
        return frames
    }

    /// Signed phase change from one sample to the next (wrapping around the circle).
    @inline(__always)
    static func difference(_ from: UInt16, _ to: UInt16) -> Int { Int(Int16(truncatingIfNeeded: Int(to) - Int(from))) }

    /// At most `maximumSyncErrors` bits differ.
    private static func close(_ word: UInt64, _ expected: UInt64) -> Bool {
        (word ^ expected).nonzeroBitCount <= maximumSyncErrors
    }

    /// Checks the sync word at `index`, slices the frame after it, and error-corrects it.
    private func demodulate(_ phi: [UInt16], at index: Int, sync: UInt64, kind: UATFrame.Kind) -> (frame: UATFrame, bits: Int)? {
        // The threshold is the middle of the average phase change for the sync word's ones and zeros.
        var oneTotal = 0, ones = 0, zeroTotal = 0, zeros = 0
        for i in 0..<UAT.syncBits {
            let change = Self.difference(phi[index + 2 * i], phi[index + 2 * i + 1])
            if sync & (1 << UInt64(35 - i)) != 0 { oneTotal += change; ones += 1 } else { zeroTotal += change; zeros += 1 }
        }
        let center = (oneTotal / ones + zeroTotal / zeros) / 2
        var errors = 0
        for i in 0..<UAT.syncBits {
            let change = Self.difference(phi[index + 2 * i], phi[index + 2 * i + 1])
            if (sync & (1 << UInt64(35 - i)) != 0) != (change >= center) { errors += 1 }
        }
        guard errors <= Self.maximumSyncErrors else { return nil }

        let start = index + 2 * UAT.syncBits
        func slice(_ byteCount: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: byteCount)
            for bit in 0..<(byteCount * 8) where Self.difference(phi[start + 2 * bit], phi[start + 2 * bit + 1]) > center {
                bytes[bit / 8] |= 0x80 >> UInt8(bit % 8)
            }
            return bytes
        }
        switch kind {
        case .downlink:
            guard let result = UAT.correctDownlink(slice(UAT.longFrameBytes)) else { return nil }
            let bits = result.payload.count == UAT.longPayloadBytes ? UAT.longFrameBytes * 8 : UAT.basicFrameBytes * 8
            return (UATFrame(kind: .downlink, payload: result.payload, correctedSymbols: result.corrected), UAT.syncBits + bits)
        case .uplink:
            guard let result = UAT.correctUplink(slice(UAT.uplinkFrameBytes)) else { return nil }
            return (UATFrame(kind: .uplink, payload: result.payload, correctedSymbols: result.corrected), UAT.syncBits + UAT.uplinkFrameBytes * 8)
        }
    }
}
