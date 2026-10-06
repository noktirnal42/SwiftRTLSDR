// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// One channel taken out of a u8 I/Q capture: moved to zero by an oscillator, decimated by a second-order CIC in
/// integers (so that its integrators may wrap), then by a Hann-windowed sinc low-pass to `sampleRate / (first × second)`.
/// The ACARS and VDL Mode 2 receivers share it; they differ in the low-pass and in what they do with the samples.
final class ChannelDecimator {
    /// The CIC's and the FIR's decimations for a total of `total` input samples to one output sample: the largest
    /// divisor of `total` up to 16 for the CIC (its droop and aliasing stay mild), the rest for the FIR.
    static func split(total: Int) -> (first: Int, second: Int) {
        let first = (2...16).reversed().first { total % $0 == 0 } ?? 1
        return (first, total / first)
    }

    private let step: (Double, Double)
    private var oscillator = (1.0, 0.0)
    private var rotations = 0
    private let first: Int, second: Int
    private var i1 = (0 as Int64, 0 as Int64), i2 = (0 as Int64, 0 as Int64)
    private var c1 = (0 as Int64, 0 as Int64), c2 = (0 as Int64, 0 as Int64)
    private var phase = 0
    private let taps: [Double]
    private var historyI: [Double], historyQ: [Double]
    private var historyIndex = 0, secondPhase = 0
    private var leftover: UInt8?

    /// - Parameters:
    ///   - offsetHz: the channel's frequency relative to the capture's centre.
    ///   - cutoffHz: the low-pass's −6 dB point at the CIC's output rate; it is flat well below it. `transitionHz` sets its
    ///     length (four times the CIC's output rate over it: a Hann window's main lobe).
    ///   - outputScale: the gain of the whole path to samples in the output; 1 leaves a full-scale input (±127.5) as
    ///     ±127.5, and 1/127.5 as ±1.
    init(sampleRate: Double, offsetHz: Double, first: Int, second: Int, cutoffHz: Double, transitionHz: Double, outputScale: Double) {
        self.first = first
        self.second = second
        let w = -2 * Double.pi * offsetHz / sampleRate
        step = (cos(w), sin(w))
        let middle = sampleRate / Double(first)
        let count = Int((4 * middle / transitionHz).rounded()) | 1
        let cutoff = 2 * cutoffHz / middle
        let raw = (0..<count).map { n -> Double in
            let t = Double(n - count / 2)
            let sinc = t == 0 ? cutoff : sin(Double.pi * cutoff * t) / (Double.pi * t)
            return sinc * (0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(count - 1)))
        }
        let gain = raw.reduce(0, +)
        taps = raw.map { $0 / gain * outputScale }
        historyI = [Double](repeating: 0, count: count)
        historyQ = [Double](repeating: 0, count: count)
    }

    /// The channel's samples for one block of interleaved I, Q octets, as interleaved I, Q floats. An odd octet at the end
    /// of a block waits for the next one.
    func process(_ block: [UInt8]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(block.count / (first * second) + 4)
        var index = 0
        if let i = leftover, !block.isEmpty {
            push(i, block[0], into: &out)
            leftover = nil
            index = 1
        }
        while index + 1 < block.count {
            push(block[index], block[index + 1], into: &out)
            index += 2
        }
        if index < block.count { leftover = block[index] }
        return out
    }

    @inline(__always)
    private func push(_ iByte: UInt8, _ qByte: UInt8, into out: inout [Float]) {
        let x = Double(iByte) - 127.5, y = Double(qByte) - 127.5
        let (c, s) = oscillator
        let mi = x * c - y * s, mq = x * s + y * c
        oscillator = (c * step.0 - s * step.1, c * step.1 + s * step.0)
        rotations += 1
        if rotations == 4_096 {
            let norm = (oscillator.0 * oscillator.0 + oscillator.1 * oscillator.1).squareRoot()
            oscillator = (oscillator.0 / norm, oscillator.1 / norm)
            rotations = 0
        }
        // CIC, second order, in integers (×256) so that the integrators may wrap.
        i1.0 &+= Int64((mi * 256).rounded()); i1.1 &+= Int64((mq * 256).rounded())
        i2.0 &+= i1.0; i2.1 &+= i1.1
        phase += 1
        guard phase == first else { return }
        phase = 0
        let d1 = (i2.0 &- c1.0, i2.1 &- c1.1)
        c1 = i2
        let d2 = (d1.0 &- c2.0, d1.1 &- c2.1)
        c2 = d1
        let scale = 1 / (256 * Double(first * first))
        historyI[historyIndex] = Double(d2.0) * scale
        historyQ[historyIndex] = Double(d2.1) * scale
        historyIndex = (historyIndex + 1) % taps.count
        secondPhase += 1
        guard secondPhase == second else { return }
        secondPhase = 0
        var fi = 0.0, fq = 0.0, h = historyIndex
        for tap in taps {
            h = h == 0 ? taps.count - 1 : h - 1
            fi += tap * historyI[h]
            fq += tap * historyQ[h]
        }
        out.append(Float(fi))
        out.append(Float(fq))
    }
}
