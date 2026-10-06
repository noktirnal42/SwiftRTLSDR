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
    private var audioCount = 0, startedBlocks = 0

    /// A message with where and how strongly it was received.
    public struct Decoded: Sendable {
        public var message: ACARSMessage
        /// The mean matched-filter amplitude from the block's SOH to its end, in the audio's units.
        public var level: Double
        /// The audio's mean (the AM carrier, for an envelope) when the message ended.
        public var carrier: Double
        /// Audio samples from the start of the stream to the end of the message.
        public var sampleIndex: Int
    }

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        centre = 2 * Double.pi * 1800 / sampleRate
        pulse = 2 * sampleRate / 2400
        let length = Int(pulse.rounded(.up)) + 2
        re = [Double](repeating: 0, count: length)
        im = [Double](repeating: 0, count: length)
    }

    public func process(audio: [Float]) -> [ACARSMessage] { decode(audio: audio).map(\.message) }

    /// Feeds audio; returns the messages completed, each with its own level, carrier and time.
    public func decode(audio: [Float]) -> [Decoded] {
        var messages: [Decoded] = []
        let length = re.count
        for sample in audio {
            audioCount += 1
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
            let message = frames.push(value > 0)
            if frames.blocksStarted != startedBlocks {          // an SOH went by: this block's level starts here
                startedBlocks = frames.blocksStarted
                levelSum = 0
                levelCount = 0
            }
            if let message {
                messages.append(Decoded(message: message, level: levelSum / Double(max(1, levelCount)), carrier: dc,
                                        sampleIndex: audioCount))
            }
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
        /// Input samples from the start of the stream to the end of the message.
        public var sampleIndex: Int
    }

    public let sampleRate: Double
    public let centerHz: Double
    public let channels: [Double]
    public let audioRate: Double
    private var paths: [ChannelPath]
    private let total: Int

    /// - Parameters:
    ///   - channels: the frequencies to decode, hertz; each must lie inside ±(sampleRate/2 − 15 kHz) of `centerHz`.
    public init(sampleRate: Double, centerHz: Double, channels: [Double]) {
        precondition(!channels.isEmpty)
        self.sampleRate = sampleRate
        self.centerHz = centerHz
        self.channels = channels
        total = max(1, Int((sampleRate / 12_500).rounded()))
        let (first, second) = ChannelDecimator.split(total: total)
        audioRate = sampleRate / Double(total)
        paths = channels.map { ChannelPath(sampleRate: sampleRate, offsetHz: $0 - centerHz, first: first, second: second) }
    }

    public func process(iq block: [UInt8]) -> [Reception] {
        var receptions: [Reception] = []
        for (n, path) in paths.enumerated() {
            for decoded in path.process(block) {
                receptions.append(Reception(message: decoded.message, channel: n, frequencyHz: channels[n],
                                            levelDB: 20 * log10(max(decoded.carrier, 1e-9) / 128),
                                            sampleIndex: decoded.sampleIndex * total))
            }
        }
        return receptions.enumerated().sorted { ($0.element.sampleIndex, $0.offset) < ($1.element.sampleIndex, $1.offset) }.map(\.element)
    }

    /// One channel: the shared front end (low-pass flat to 4.5 kHz, down by 8.5 kHz, so that nothing folds into the band
    /// when the rate drops to 12.5 kHz), the envelope, the demodulator.
    final class ChannelPath {
        let demodulator: ACARSDemodulator
        private let decimator: ChannelDecimator

        init(sampleRate: Double, offsetHz: Double, first: Int, second: Int) {
            decimator = ChannelDecimator(sampleRate: sampleRate, offsetHz: offsetHz, first: first, second: second,
                                         cutoffHz: 6_000, transitionHz: 3_500, outputScale: 1)
            demodulator = ACARSDemodulator(sampleRate: sampleRate / Double(first * second))
        }

        func process(_ block: [UInt8]) -> [ACARSDemodulator.Decoded] {
            let iq = decimator.process(block)
            var audio = [Float](repeating: 0, count: iq.count / 2)
            for n in audio.indices { audio[n] = (iq[2 * n] * iq[2 * n] + iq[2 * n + 1] * iq[2 * n + 1]).squareRoot() }
            return demodulator.decode(audio: audio)
        }
    }
}
