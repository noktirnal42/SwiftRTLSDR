// SPDX-License-Identifier: GPL-2.0-or-later
//
// ACARS reception: AM demodulation of several channels from one capture, and coherent detection of the 2400 bit/s MSK
// (1200 and 2400 Hz tones) in the audio. Written for this package; see PROVENANCE.md.
import Foundation

/// Bits from ACARS audio (the AM-demodulated channel, any rate from about 9.6 kHz; 12.5 kHz as acarsdec uses).
///
/// MSK is offset QPSK with half-sine pulses two bits long: against a reference at the centre frequency (1800 Hz) the
/// bits fall alternately on the in-phase and the quadrature arm, the sign of the pulses turning every second bit. One
/// loop follows the reference's phase, and the bit clock is tied to it (a bit lasts three quarters of a cycle of
/// 1800 Hz), so locking the one locks the other. The decision on one arm, times the other arm, is the phase error.
/// The loop follows a modem clock up to about 0.25% off (4.5 Hz on the tones); the AM envelope carries no tuning error.
public final class ACARSDemodulator {
    public let sampleRate: Double
    public let frames = ACARSFrameDecoder()
    private let centre: Double                     // radians a sample at 1800 Hz
    private let pulse: Double                      // samples in two bits
    private var phase = 0.0, clock = 0.0, correction = 0.0
    private var bit = 0
    private var dc = 0.0
    private var re: [Double], im: [Double]
    private var index = 0
    private var levelSum = 0.0, levelCount = 0
    /// The mean matched-filter amplitude over the last message (relative), for a signal-strength figure.
    public private(set) var lastLevel = 0.0
    /// The audio's mean (the AM carrier, for an envelope) when the last message ended.
    public private(set) var lastCarrier = 0.0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        centre = 2 * Double.pi * 1800 / sampleRate
        pulse = 2 * sampleRate / 2400
        let length = Int(pulse.rounded(.up)) + 2
        re = [Double](repeating: 0, count: length)
        im = [Double](repeating: 0, count: length)
    }

    public func process(audio: [Float]) -> [ACARSMessage] {
        var messages: [ACARSMessage] = []
        let length = re.count
        for sample in audio {
            // Remove the AM carrier's DC (the lowest tone is 1200 Hz).
            dc += (Double(sample) - dc) * 0.01
            let x = Double(sample) - dc
            let step = centre + correction
            phase += step
            if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
            re[index] = x * cos(phase)
            im[index] = -x * sin(phase)
            index = (index + 1) % length
            clock += step
            guard clock >= 1.5 * Double.pi - step / 2 else { continue }
            clock -= 1.5 * Double.pi
            // The bit ended `lag` samples ago (negative: is about to): the matched filter is the half sine over the two
            // bits before that instant.
            let lag = clock / step
            var vr = 0.0, vi = 0.0
            for back in 0..<length {
                let offset = lag - Double(back)                 // the sample's time after the end of the bit
                guard offset <= 0, offset >= -pulse else { continue }
                let weight = sin(Double.pi * (offset + pulse) / pulse)
                let k = (index - 1 - back + length) % length
                vr += weight * re[k]
                vi += weight * im[k]
            }
            let level = (vr * vr + vi * vi).squareRoot()
            levelSum += level
            levelCount += 1
            let nr = vr / (level + 1e-12), ni = vi / (level + 1e-12)
            let onReal = bit & 1 == 0
            var value = onReal ? nr : ni
            let error = onReal ? (nr >= 0 ? ni : -ni) : (ni >= 0 ? -nr : nr)
            if bit & 2 != 0 { value = -value }
            bit = (bit + 1) & 3
            correction = 0.55 * correction + 0.0017 * error
            if let message = frames.push(value > 0) {
                lastLevel = levelSum / Double(max(1, levelCount))
                lastCarrier = dc
                messages.append(message)
            }
            if levelCount > 4_000 { levelSum = 0; levelCount = 0 }
        }
        return messages
    }
}

/// ACARS from u8 I/Q: any number of channels inside the capture, each moved to zero, decimated to about 12.5 kHz,
/// AM-demodulated and decoded.
public final class ACARSReceiver {
    public struct Reception: Sendable {
        public var message: ACARSMessage
        public var channel: Int
        public var frequencyHz: Double
        /// The channel's carrier level when the message ended, dB below full scale.
        public var levelDB: Double
        /// Input samples since the stream began.
        public var sampleIndex: Int
    }

    public let sampleRate: Double
    public let centerHz: Double
    public let channels: [Double]
    public let audioRate: Double
    private var paths: [ChannelPath]
    private var samples = 0

    /// - Parameters:
    ///   - channels: the frequencies to decode, hertz; each must lie inside ±(sampleRate/2 − 15 kHz) of `centerHz`.
    public init(sampleRate: Double, centerHz: Double, channels: [Double]) {
        precondition(!channels.isEmpty)
        self.sampleRate = sampleRate
        self.centerHz = centerHz
        self.channels = channels
        let total = max(1, Int((sampleRate / 12_500).rounded()))
        let first = (2...16).reversed().first { total % $0 == 0 } ?? 1
        audioRate = sampleRate / Double(total)
        paths = channels.map { ChannelPath(sampleRate: sampleRate, offsetHz: $0 - centerHz, first: first, second: total / first) }
    }

    public func process(iq block: [UInt8]) -> [Reception] {
        var receptions: [Reception] = []
        for (n, path) in paths.enumerated() {
            for message in path.process(block) {
                receptions.append(Reception(message: message, channel: n, frequencyHz: channels[n],
                                            levelDB: 20 * log10(max(path.demodulator.lastCarrier, 1e-9) / 128), sampleIndex: samples))
            }
        }
        samples += block.count / 2
        return receptions
    }

    /// One channel: oscillator, a second-order CIC (integer, wrapping), an FIR to the audio rate, the envelope.
    final class ChannelPath {
        let demodulator: ACARSDemodulator
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

        init(sampleRate: Double, offsetHz: Double, first: Int, second: Int) {
            self.first = first
            self.second = second
            let w = -2 * Double.pi * offsetHz / sampleRate
            step = (cos(w), sin(w))
            let middle = sampleRate / Double(first)
            demodulator = ACARSDemodulator(sampleRate: middle / Double(second))
            // Low-pass at the middle rate: flat to 4.5 kHz (the MSK reaches 3.6), down by 8.5 kHz, so nothing folds
            // into the band when the rate drops to 12.5 kHz. Hann-windowed sinc.
            let count = Int((4 * middle / 3_500).rounded()) | 1
            let cutoff = 2 * 6_000 / middle
            taps = (0..<count).map { n in
                let t = Double(n - count / 2)
                let sinc = t == 0 ? cutoff : sin(Double.pi * cutoff * t) / (Double.pi * t)
                return sinc * (0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(count - 1)))
            }
            historyI = [Double](repeating: 0, count: count)
            historyQ = [Double](repeating: 0, count: count)
        }

        func process(_ block: [UInt8]) -> [ACARSMessage] {
            var audio: [Float] = []
            audio.reserveCapacity(block.count / (2 * first * second) + 2)
            var index = 0
            if let i = leftover, !block.isEmpty {
                push(i, block[0], into: &audio)
                leftover = nil
                index = 1
            }
            while index + 1 < block.count {
                push(block[index], block[index + 1], into: &audio)
                index += 2
            }
            if index < block.count { leftover = block[index] }
            return demodulator.process(audio: audio)
        }

        @inline(__always)
        private func push(_ iByte: UInt8, _ qByte: UInt8, into audio: inout [Float]) {
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
            audio.append(Float((fi * fi + fq * fq).squareRoot()))
        }
    }
}
