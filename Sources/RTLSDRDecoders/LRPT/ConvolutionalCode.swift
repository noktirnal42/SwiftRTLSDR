// SPDX-License-Identifier: GPL-2.0-or-later
//
// The CCSDS rate-1/2, K=7 convolutional code (G1 = 0x79, G2 = 0x5B) as Meteor-M LRPT uses it. The Viterbi decoder is a
// port of ecc/viterbi.c from meteor_decode by dbdexter-dev (MIT licence, https://github.com/dbdexter-dev/meteor_decode;
// copyright notice in NOTICE), keeping its metric, normalisation and traceback so that both decode alike.
// See PROVENANCE.md.

/// The convolutional encoder. Each data bit yields two channel bits, sent G2 first, then G1.
public struct ConvolutionalEncoder: Sendable {
    public static let g1: UInt32 = 0x79
    public static let g2: UInt32 = 0x5b
    public static let constraintLength = 7
    public private(set) var state: UInt32

    public init(state: UInt32 = 0) { self.state = state }

    /// Encodes one bit; returns the channel bits in transmission order (G2, G1).
    public mutating func encode(_ bit: UInt8) -> (UInt8, UInt8) {
        state = ((state >> 1) | (UInt32(bit & 1) << 6)) & 0x7f
        return (parity(state & Self.g2), parity(state & Self.g1))
    }

    /// Encodes whole bytes, MSB first, into channel bits (G2, G1 per data bit).
    public mutating func encode(bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 16)
        for byte in bytes {
            for shift in (0..<8).reversed() {
                let (a, b) = encode(byte >> UInt8(shift) & 1)
                out.append(a)
                out.append(b)
            }
        }
        return out
    }

    private func parity(_ word: UInt32) -> UInt8 { UInt8(word.nonzeroBitCount & 1) }

    /// meteor_decode's packing of a 32-bit word: 64 channel bits, G1 in the high bit of each pair (the correlator
    /// swaps the pairs back into transmission order).
    static func encodeWord(_ data: UInt32, state: UInt32 = 0) -> UInt64 {
        var state = state
        var output: UInt64 = 0
        for i in (0..<32).reversed() {
            state = ((state >> 1) | ((data >> UInt32(i)) << 6)) & 0x7f
            let g1 = UInt64((state & g1).nonzeroBitCount & 1), g2 = UInt64((state & g2).nonzeroBitCount & 1)
            output |= (g1 << 1 | g2) << UInt64(i << 1)
        }
        return output
    }
}

/// Soft-decision Viterbi decoder for the code above. Soft symbols are signed bytes, negative meaning 1, in
/// transmission order. Output lags input by `delayBytes`: the first call's first 8 bytes are traceback warm-up.
final class ViterbiDecoder {
    static let states = 128                        // 1 << K
    static let memoryDepth = 128                   // traceback memory, bits
    static let memoryStart = 64                    // the part of the traceback not yet converged
    static let memoryBacktrace = 64
    static let delayBytes = memoryStart / 8        // 8

    private var metrics = [Int16](repeating: 0, count: states)
    private var nextMetrics = [Int16](repeating: 0, count: states)
    private var previous = [UInt8](repeating: 0, count: memoryDepth * states / 2)
    private var depth = 0
    private let outputTable: [Int]                 // encoder output (G1 << 1 | G2) for input 0 from each state

    init() {
        outputTable = (0..<Self.states).map { state in
            let next = UInt32(state >> 1)
            return Int((next & ConvolutionalEncoder.g1).nonzeroBitCount & 1) << 1 | Int((next & ConvolutionalEncoder.g2).nonzeroBitCount & 1)
        }
    }

    func reset() {
        for index in metrics.indices { metrics[index] = 0; nextMetrics[index] = 0 }
        depth = 0
    }

    /// Decodes `byteCount` bytes (a multiple of 8) from `2 × 8 × byteCount` soft symbols. Returns the path-metric
    /// total, meteor_decode's measure of quality (lower is better; about 1100 per byte is enough to decode).
    func decode(into out: inout [UInt8], at outIndex: Int, soft: UnsafeBufferPointer<Int8>, at softIndex: Int, byteCount: Int) -> Int {
        precondition(byteCount % (Self.memoryBacktrace >> 3) == 0)
        var total = 0
        var input = softIndex
        var output = outIndex
        var remaining = byteCount
        while remaining > 0 {
            for _ in Self.memoryStart..<Self.memoryDepth {
                depth = (depth + 1) % Self.memoryDepth
                let y = soft[input], x = soft[input + 1]
                input += 2
                update(Int8(truncatingIfNeeded: -Int(x)), Int8(truncatingIfNeeded: -Int(y)))
            }
            var bestState = 0
            var bestMetric = metrics[0]
            for state in 1..<Self.states where metrics[state] > bestMetric {
                bestMetric = metrics[state]
                bestState = state
            }
            for state in 0..<Self.states { metrics[state] = metrics[state] &- bestMetric }
            total += 2 * ((127 * Self.memoryBacktrace) - Int(bestMetric))
            backtrace(&out, at: output, from: bestState)
            output += Self.memoryBacktrace >> 3
            remaining -= Self.memoryBacktrace >> 3
        }
        return total
    }

    @inline(__always)
    private static func metric(_ x: Int, _ y: Int, _ coding: Int) -> Int {
        max(-128, min(127, ((coding >> 1 != 0 ? x : -x) + (coding & 1 != 0 ? y : -y)) >> 1))
    }

    private func update(_ x: Int8, _ y: Int8) {
        let xi = Int(x), yi = Int(y)
        let l0 = Self.metric(xi, yi, 0), l1 = Self.metric(xi, yi, 1), l2 = Self.metric(xi, yi, 2), l3 = Self.metric(xi, yi, 3)
        let row = depth * (Self.states / 2)
        metrics.withUnsafeBufferPointer { metrics in
            nextMetrics.withUnsafeMutableBufferPointer { next in
                previous.withUnsafeMutableBufferPointer { previous in
                    var state = 0
                    while state < Self.states / 2 {
                        let ns0 = state, ns1 = state + (1 << 6), ns2 = state + 1, ns3 = ns1 + 1
                        let m0 = metrics[state << 1], m1 = metrics[(state << 1) + 1]
                        let m2 = metrics[(state << 1) + 2], m3 = metrics[(state << 1) + 3]
                        let best01 = m0 > m1 ? m0 : m1
                        let best23 = m2 > m3 ? m2 : m3
                        previous[row + ns0] = UInt8(m0 > m1 ? state << 1 : (state << 1) + 1)
                        previous[row + ns2] = UInt8(m2 > m3 ? (state << 1) + 2 : (state << 1) + 3)
                        // Both polynomials have their top bit set, so input 1 gives the opposite metric.
                        let code = outputTable[state << 1]
                        let lm0 = Int16(truncatingIfNeeded: code == 0 ? l0 : code == 1 ? l1 : code == 2 ? l2 : l3)
                        let lm1 = 0 &- lm0
                        next[ns0] = best01 &+ lm0
                        next[ns1] = best01 &+ lm1
                        next[ns2] = best23 &+ lm1
                        next[ns3] = best23 &+ lm0
                        state += 2
                    }
                }
            }
        }
        swap(&metrics, &nextMetrics)
    }

    private func backtrace(_ out: inout [UInt8], at index: Int, from start: Int) {
        var state = start
        var depth = self.depth
        let half = Self.states / 2
        for _ in 0..<Self.memoryStart {
            state = Int(previous[depth * half + (state & ~(1 << 6))])
            depth = (depth - 1 + Self.memoryDepth) % Self.memoryDepth
        }
        var position = index + Self.memoryBacktrace / 8
        for _ in 0..<(Self.memoryBacktrace / 8) {
            var byte: UInt8 = 0
            for bit in 0..<8 {
                byte |= UInt8(state >> 6) << UInt8(bit)
                state = Int(previous[depth * half + (state & ~(1 << 6))])
                depth = (depth - 1 + Self.memoryDepth) % Self.memoryDepth
            }
            position -= 1
            out[position] = byte
        }
    }
}
