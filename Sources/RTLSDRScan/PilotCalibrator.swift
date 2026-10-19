// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Measures a dongle's crystal error from the 19 kHz stereo pilot of an FM broadcast (SH-9's second route, for a dongle
/// with no ATSC reception).
///
/// The pilot is a real 19 kHz tone in the station's own time base. A crystal fast by p ppm makes it appear at
/// 19 000 / (1 + p) Hz, so p = 19 000 / measured − 1, positive when fast (the same convention as `CarrierCalibrator`).
/// The discriminator output does not depend on where the carrier sits in the passband, so the tuned offset does not matter
/// as long as the station is inside it; a strong, stereo station is needed.
///
/// **The reference is the broadcaster's, and it is loose on paper.** Broadcast rules allow the pilot to be 19 kHz ±2 Hz,
/// which is ±105 ppm at 19 kHz. Real exciters are usually much closer, but one station cannot show that: agreement between
/// several stations, measured the same way, is the evidence. `referenceUncertaintyPPM` carries whatever the caller
/// accepts for the reference; 0 means "the pilot is exact", which nothing here proves.
///
/// Stages: FM discriminator (phase step per sample), boxcar decimation to about 128 kS/s, a Hann-windowed transform of
/// `fftSize` decimated samples per segment (about 4 s at the default 2^19), a quadratic peak fit inside ±`searchHz`
/// of the pilot. Each segment gives one estimate; the measurement averages them and reports their standard error.
public final class FMPilotCalibrator {
    public struct Measurement: Sendable, Equatable {
        /// The pilot's measured frequency, in the dongle's time base (nominal hertz).
        public var pilotHz: Double
        /// The crystal's error, positive when fast.
        public var ppm: Double
        /// One standard error of `ppm` from the spread of the segments. nil until there are two segments.
        public var standardErrorPPM: Double?
        /// `standardErrorPPM` plus `referenceUncertaintyPPM`. nil when `standardErrorPPM` is nil.
        public var uncertaintyPPM: Double?
        /// The pilot's line over the median of the bins searched, dB. Below `minimumSNRdB` the pilot is not reported.
        public var snrDB: Double
        /// Segments averaged.
        public var segments: Int
    }

    /// The nominal pilot frequency.
    public static let nominalPilotHz = 19_000.0
    /// The broadcast rule's tolerance on the pilot (±2 Hz), in ppm at 19 kHz. The bound on paper, not a measurement.
    public static let regulatoryPilotTolerancePPM = 2.0 / nominalPilotHz * 1e6
    /// A peak this far above the median of its search band counts as a pilot.
    public static let minimumSNRdB = 10.0

    public let sampleRate: Double
    /// Samples per decimated output sample (the boxcar length).
    public let decimation: Int
    /// The rate after decimation, in nominal hertz.
    public var decimatedRate: Double { sampleRate / Double(decimation) }
    public let fftSize: Int
    /// How far either side of 19 kHz the pilot is searched.
    public let searchHz: Double
    /// The accuracy the caller accepts for the pilot itself (see the type's note). Added to every uncertainty.
    public let referenceUncertaintyPPM: Double

    private let fft: FFT
    private let window: [Double]
    private var previousI = 0.0, previousQ = 0.0, havePrevious = false
    private var boxSum = 0.0, boxCount = 0
    private var segment: [Double] = []
    private var estimatesHz: [Double] = []
    private var lastSNR = 0.0
    private var spectrum: [Double]
    private var real: [Double], imaginary: [Double]

    /// - Parameters:
    ///   - sampleRate: the nominal sample rate (2.048 MS/s is what the broadcast FM band is normally received at). Its
    ///     decimation is the nearest whole number that leaves about 128 kS/s.
    ///   - fftSize: a power of two; the bin width is `decimatedRate / fftSize` (0.24 Hz at the default).
    public init?(sampleRate: Double, fftSize: Int = 1 << 19, searchHz: Double = 15, referenceUncertaintyPPM: Double = 0) {
        guard sampleRate > 0, let fft = FFT(size: fftSize), searchHz > 0, referenceUncertaintyPPM >= 0 else { return nil }
        self.sampleRate = sampleRate
        self.decimation = max(1, Int((sampleRate / 128_000).rounded()))
        self.fftSize = fftSize
        self.searchHz = searchHz
        self.referenceUncertaintyPPM = referenceUncertaintyPPM
        self.fft = fft
        window = (0..<fftSize).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize)) }
        spectrum = [Double](repeating: 0, count: fftSize)
        real = [Double](repeating: 0, count: fftSize)
        imaginary = [Double](repeating: 0, count: fftSize)
        segment.reserveCapacity(fftSize)
    }

    /// Interleaved unsigned 8-bit I/Q, any amount at a time.
    public func process(iq block: [UInt8]) {
        var index = 0
        while index + 1 < block.count {
            let i = Double(block[index]) - 127.5, q = Double(block[index + 1]) - 127.5
            index += 2
            defer { previousI = i; previousQ = q; havePrevious = true }
            guard havePrevious else { continue }
            // The phase step between neighbouring samples is proportional to the instantaneous frequency.
            let step = atan2(q * previousI - i * previousQ, i * previousI + q * previousQ)
            boxSum += step
            boxCount += 1
            if boxCount == decimation {
                segment.append(boxSum / Double(decimation))
                boxSum = 0
                boxCount = 0
                if segment.count == fftSize { finishSegment() }
            }
        }
    }

    /// Drops the samples gathered towards a segment, and the discriminator's memory: call where the stream has a gap.
    public func discardPartialSegment() {
        segment.removeAll(keepingCapacity: true)
        boxSum = 0
        boxCount = 0
        havePrevious = false
    }

    private func finishSegment() {
        let size = fftSize
        for n in 0..<size {
            real[n] = segment[n] * window[n]
            imaginary[n] = 0
        }
        segment.removeAll(keepingCapacity: true)
        fft.forward(real: &real, imaginary: &imaginary)
        for k in 0..<size { spectrum[k] = real[k] * real[k] + imaginary[k] * imaginary[k] }
        let bin = decimatedRate / Double(size)
        if let peak = peakHz(in: spectrum, bin: bin) {
            estimatesHz.append(peak.hz)
            lastSNR = peak.snrDB
        }
    }

    /// The pilot's frequency in one spectrum, from the strongest bin within `searchHz` of 19 kHz, refined by a quadratic
    /// fit of the log power. nil when the peak is not above the noise by `minimumSNRdB`.
    private func peakHz(in spectrum: [Double], bin: Double) -> (hz: Double, snrDB: Double)? {
        let size = spectrum.count
        func index(_ hz: Double) -> Int { ((Int((hz / bin).rounded()) % size) + size) % size }
        func frequency(_ k: Int) -> Double { Double(k < size / 2 ? k : k - size) * bin }
        let centre = Self.nominalPilotHz
        let firstBin = Int(((centre - searchHz) / bin).rounded(.down)), lastBin = Int(((centre + searchHz) / bin).rounded(.up))
        var best = firstBin, bestPower = -1.0
        var searched: [Double] = []
        searched.reserveCapacity(lastBin - firstBin + 1)
        for n in firstBin...lastBin {
            let p = spectrum[index(Double(n) * bin)]
            searched.append(p)
            if p > bestPower { bestPower = p; best = n }
        }
        searched.sort()
        let median = max(searched[searched.count / 2], 1e-300)
        let snr = 10 * log10(max(bestPower, 1e-300) / median)
        guard snr >= Self.minimumSNRdB else { return nil }
        let k = index(Double(best) * bin)
        let a = log(max(spectrum[(k - 1 + size) % size], 1e-300))
        let b = log(max(bestPower, 1e-300))
        let c = log(max(spectrum[(k + 1) % size], 1e-300))
        let denominator = a - 2 * b + c
        let fraction = denominator < 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / denominator)) : 0
        return (frequency(k) + fraction * bin, snr)
    }

    /// The pilot as found so far; nil before one whole segment, or when no pilot stands out of the noise.
    public func measurement() -> Measurement? {
        guard !estimatesHz.isEmpty else { return nil }
        let hz = estimatesHz.reduce(0, +) / Double(estimatesHz.count)
        let standardError: Double? = estimatesHz.count >= 2 ? CarrierCalibrator.standardError(estimatesHz) / Self.nominalPilotHz * 1e6 : nil
        return Measurement(
            pilotHz: hz,
            ppm: (Self.nominalPilotHz / hz - 1) * 1e6,
            standardErrorPPM: standardError,
            uncertaintyPPM: standardError.map { $0 + referenceUncertaintyPPM },
            snrDB: lastSNR,
            segments: estimatesHz.count
        )
    }
}
