// SPDX-License-Identifier: GPL-2.0-or-later
//
// From u8 I/Q near a narrow FSK telemetry signal to its frequency, with the carrier found and followed. Written for
// this package; shared by the radiosonde receivers.
import Foundation

/// Turns u8 I/Q (tuned near a narrow FSK signal) into the signal's instantaneous frequency in hertz, which the sondes'
/// frame synchronisers read as FM audio.
///
/// An oscillator moves the signal to zero, a boxcar decimates to about `audioRate`, a low-pass keeps the signal and
/// little noise, and a discriminator gives the frequency. A filter that narrow needs the carrier found first (a dongle's
/// crystal alone can be 20 kHz off at 403 MHz), so the decimated samples' spectrum is also averaged over half a second
/// and, while no frame has decoded for a while, the listening frequency is moved to the centre of the power standing
/// above the noise. A receiver that decodes frames keeps the listening frequency on the signal by calling `listen(at:)`.
public final class FMFrontEnd {
    public let inputRate: Double
    /// Samples a second of `process(iq:)`'s output.
    public let audioRate: Double
    /// Input samples per output sample.
    public let decimation: Int
    private(set) var offsetHz: Double
    private var oscillator = (1.0, 0.0)            // e^(−2πi·offset·t), advanced by a rotation each sample
    private var rotations = 0
    private var sumI = 0.0, sumQ = 0.0, summed = 0
    private let taps: [Double]
    private var historyI: [Double], historyQ: [Double], historyIndex = 0
    private var previous = (0.0, 0.0)
    // Carrier search: power spectra of the decimated samples, averaged.
    private static let searchSize = 1024, searchAverages = 24
    private let reachHz: Double, spanHz: Double
    private let fft = RadixTwoFFT(size: searchSize)
    private var searchReal = [Double](repeating: 0, count: searchSize), searchImaginary = [Double](repeating: 0, count: searchSize)
    private var searchPower = [Double](repeating: 0, count: searchSize)
    private var searchFilled = 0, searchTransforms = 0
    private var samplesSinceGoodFrame = Int.max / 2
    /// The last carrier search: offset from where the receiver was listening (hertz) and how far the signal stood
    /// above the noise (dB); nil until the first half second.
    public private(set) var lastSearch: (offsetHz: Double, snrDB: Double)?

    /// I/Q at `sampleRate` with the signal `offsetHz` above the tuned frequency. `channelCutoffHz` is the low-pass's
    /// cutoff (the signal's deviation plus its keying rate, about); `searchSpanHz` is how far from the strongest line
    /// the signal's power is counted when the carrier is centred (the half width of its spectrum, about).
    public init(sampleRate: Double, offsetHz: Double = 0, channelCutoffHz: Double, targetAudioRate: Double = 48_000,
                searchSpanHz: Double = 7_000) {
        inputRate = sampleRate
        self.offsetHz = offsetHz
        decimation = max(1, Int((sampleRate / targetAudioRate).rounded()))
        audioRate = sampleRate / Double(decimation)
        reachHz = min(20_000, 0.42 * audioRate)
        spanHz = searchSpanHz
        let count = 49, cutoff = channelCutoffHz / audioRate
        taps = (0..<count).map { n in
            let t = Double(n - count / 2)
            let sinc = t == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * t) / (.pi * t)
            return sinc * (0.54 - 0.46 * cos(2 * .pi * Double(n) / Double(count - 1)))
        }
        historyI = [Double](repeating: 0, count: count)
        historyQ = [Double](repeating: 0, count: count)
    }

    /// Where the receiver is listening, relative to the tuned frequency.
    public var listeningOffsetHz: Double { offsetHz }

    /// Listens at `offset` (hertz from the tuned frequency) from now on: the signal has been seen there.
    public func listen(at offset: Double) {
        offsetHz = max(-inputRate / 2, min(inputRate / 2, offset))
    }

    /// A frame decoded cleanly: the carrier search leaves the listening frequency alone for a few seconds.
    public func noteGoodFrame() { samplesSinceGoodFrame = 0 }

    /// The frequency of the signal in hertz, one value per `decimation` input samples.
    public func process(iq block: [UInt8]) -> [Float] {
        var audio: [Float] = []
        audio.reserveCapacity(block.count / 2 / decimation + 1)
        let step = -2 * Double.pi * offsetHz / inputRate
        let rotation = (cos(step), sin(step))
        var index = 0
        while index + 1 < block.count {
            let i = Double(block[index]) - 127.5, q = Double(block[index + 1]) - 127.5
            index += 2
            let (c, s) = oscillator
            sumI += i * c - q * s
            sumQ += i * s + q * c
            oscillator = (c * rotation.0 - s * rotation.1, c * rotation.1 + s * rotation.0)
            rotations += 1
            if rotations == 4096 {                      // keep it on the unit circle
                let norm = (oscillator.0 * oscillator.0 + oscillator.1 * oscillator.1).squareRoot()
                oscillator = (oscillator.0 / norm, oscillator.1 / norm)
                rotations = 0
            }
            summed += 1
            guard summed == decimation else { continue }
            search(sumI, sumQ)
            historyI[historyIndex] = sumI
            historyQ[historyIndex] = sumQ
            sumI = 0; sumQ = 0; summed = 0
            var fi = 0.0, fq = 0.0, h = historyIndex
            for tap in taps {
                fi += tap * historyI[h]; fq += tap * historyQ[h]
                h = h == 0 ? taps.count - 1 : h - 1
            }
            historyIndex = (historyIndex + 1) % taps.count
            // Frequency, in hertz: the phase step between filtered samples.
            let angle = atan2(fq * previous.0 - fi * previous.1, fi * previous.0 + fq * previous.1)
            previous = (fi, fq)
            audio.append(Float(angle * audioRate / (2 * .pi)))
        }
        return audio
    }

    /// Adds a decimated sample to the carrier search; every half second, moves the listening frequency to the signal if
    /// no frame has decoded for a while.
    private func search(_ i: Double, _ q: Double) {
        let n = Self.searchSize
        let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(searchFilled) / Double(n))
        searchReal[searchFilled] = i * window
        searchImaginary[searchFilled] = q * window
        searchFilled += 1
        samplesSinceGoodFrame += 1
        guard searchFilled == n else { return }
        searchFilled = 0
        fft.forward(real: &searchReal, imaginary: &searchImaginary)
        for k in 0..<n { searchPower[k] += searchReal[k] * searchReal[k] + searchImaginary[k] * searchImaginary[k] }
        searchTransforms += 1
        guard searchTransforms == Self.searchAverages else { return }
        defer { for k in 0..<n { searchPower[k] = 0 }; searchTransforms = 0 }

        // Bins within the reach (the boxcar's useful band), in frequency order, smoothed over five bins.
        let binHz = audioRate / Double(n)
        let reach = min(n / 2 - 3, Int(reachHz / binHz))
        let bins = Array(-reach...reach)
        let power: [Double] = bins.map { k in
            var sum = 0.0
            for d in -2...2 { sum += searchPower[((k + d) % n + n) % n] }
            return sum / 5
        }
        let floor = power.sorted()[power.count / 2]
        guard floor > 0, let peak = power.indices.max(by: { power[$0] < power[$1] }) else { return }
        let snr = 10 * log10(power[peak] / floor)
        // The centre of the power above the noise within the span of the peak (the lobes of the FSK spectrum).
        var weight = 0.0, moment = 0.0
        let span = Int(spanHz / binHz)
        for index in max(0, peak - span)...min(power.count - 1, peak + span) where power[index] > 2 * floor {
            weight += power[index] - floor
            moment += (power[index] - floor) * Double(bins[index]) * binHz
        }
        guard weight > 0 else { return }
        let centre = moment / weight
        lastSearch = (centre, snr)
        if snr >= 6 && abs(centre) > 300 && samplesSinceGoodFrame > Int(3 * audioRate) {
            listen(at: offsetHz + centre)
        }
    }
}
