// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Measures a dongle's crystal error from a carrier of known frequency (a signal generator, a GPS-disciplined beacon,
/// an ATSC pilot, any steady unmodulated line).
///
/// The dongle's tuner and sample clock run from one crystal, so a crystal fast by p ppm tunes p ppm high and samples
/// p ppm fast: a carrier at f, tuned to c, shows at m = f/(1 + p) − c in the nominal spectrum, which gives
/// p = f/(c + m) − 1. Long transforms (Hann window, averaged over the capture) find the line; quadratic interpolation
/// of the log power around the peak places it to a fraction of a bin. The result is what `setFrequencyCorrection(ppm:)`
/// takes, provided the capture was made with no correction applied.
public final class CarrierCalibrator {
    public struct Measurement: Sendable, Equatable {
        /// Where the line was, from the tuned frequency, in nominal hertz.
        public var offsetHz: Double
        /// The crystal's error: positive when fast.
        public var ppm: Double
        /// The line over the median of the bins searched, dB.
        public var snrDB: Double
        /// Width of the line at half its power: about 1.5 bins for a steady carrier, much more for a modulated or
        /// drifting one.
        public var widthHz: Double
        public var binHz: Double
        public var transforms: Int
        /// One standard error of `ppm` from the spread of the per-transform estimates (each transform's own peak). nil
        /// until there are two transforms to compare.
        public var standardErrorPPM: Double?
        /// `standardErrorPPM` plus the reference's own accuracy (`referenceUncertaintyPPM`), summed without
        /// cancellation so it is the conservative figure to quote. nil when `standardErrorPPM` is nil.
        public var uncertaintyPPM: Double?
    }

    public let sampleRate: Double
    public let tunedHz: Double
    public let carrierHz: Double
    /// Only lines within this many ppm of where the carrier would be with a perfect crystal are considered.
    public let searchPPM: Double
    /// The accuracy of the carrier's frequency itself, in ppm (a GPS-disciplined source: about 0.001; an ATSC pilot
    /// from a station that is not checked: a couple of ppm). Added to the uncertainty of every measurement.
    public let referenceUncertaintyPPM: Double
    private let fft: FFT
    private let window: [Double]
    private var power: [Double]
    private var transformPower: [Double]
    private var transformPPM: [Double] = []
    private var real: [Double], imaginary: [Double]
    private var filled = 0
    private var leftover: UInt8?
    public private(set) var transforms = 0
    public var binHz: Double { sampleRate / Double(fft.size) }
    public var fftSize: Int { fft.size }

    /// Drops samples gathered towards a transform not yet complete: call where the stream has a gap.
    public func discardPartialTransform() {
        filled = 0
        leftover = nil
    }

    /// - Parameters:
    ///   - fftSize: a power of two; the bin width is `sampleRate / fftSize` (2^18 at 1.024 MS/s: 3.9 Hz).
    public init?(
        sampleRate: Double, tunedHz: Double, carrierHz: Double, searchPPM: Double = 150, fftSize: Int = 1 << 18,
        referenceUncertaintyPPM: Double = 0
    ) {
        guard let fft = FFT(size: fftSize), sampleRate > 0, carrierHz > 0, referenceUncertaintyPPM >= 0 else { return nil }
        self.sampleRate = sampleRate
        self.tunedHz = tunedHz
        self.carrierHz = carrierHz
        self.searchPPM = searchPPM
        self.referenceUncertaintyPPM = referenceUncertaintyPPM
        self.fft = fft
        window = (0..<fftSize).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize)) }
        power = [Double](repeating: 0, count: fftSize)
        transformPower = [Double](repeating: 0, count: fftSize)
        real = [Double](repeating: 0, count: fftSize)
        imaginary = [Double](repeating: 0, count: fftSize)
    }

    /// Interleaved u8 I/Q; any amount at a time (a block may end between the I and the Q of a sample).
    public func process(iq block: [UInt8]) {
        var index = 0
        if let i = leftover, !block.isEmpty {
            push(i, block[0])
            leftover = nil
            index = 1
        }
        while index + 1 < block.count {
            push(block[index], block[index + 1])
            index += 2
        }
        if index < block.count { leftover = block[index] }
    }

    private func push(_ i: UInt8, _ q: UInt8) {
        real[filled] = (Double(i) - 127.5) * window[filled]
        imaginary[filled] = (Double(q) - 127.5) * window[filled]
        filled += 1
        if filled == fft.size {
            fft.forward(real: &real, imaginary: &imaginary)
            for k in 0..<fft.size {
                transformPower[k] = real[k] * real[k] + imaginary[k] * imaginary[k]
                power[k] += transformPower[k]
            }
            transforms += 1
            if let peak = peakOffset(in: transformPower) {
                transformPPM.append((carrierHz / (tunedHz + peak.offset) - 1) * 1e6)
            }
            filled = 0
        }
    }

    /// Where the strongest line is in `spectrum` (bins unshifted, as `FFT` returns them), searched within
    /// `searchPPM` of the expected place: its offset from the tuned frequency (quadratic interpolation of the log
    /// power), the peak power, and the median power of the bins searched.
    private func peakOffset(in spectrum: [Double]) -> (offset: Double, peak: Double, median: Double, width: Double)? {
        let size = fft.size, bin = sampleRate / Double(size)
        let expected = carrierHz - tunedHz
        let reach = carrierHz * searchPPM * 1e-6
        // Bin k (0 ..< size, unshifted) is at k·bin, or (k − size)·bin above the Nyquist frequency.
        func frequency(_ k: Int) -> Double { Double(k < size / 2 ? k : k - size) * bin }
        func index(_ hz: Double) -> Int { ((Int((hz / bin).rounded()) % size) + size) % size }
        let low = expected - reach, high = expected + reach
        guard low > -sampleRate / 2 + 2 * bin, high < sampleRate / 2 - 2 * bin else { return nil }
        let first = Int((low / bin).rounded(.down)), last = Int((high / bin).rounded(.up))
        var best = first, bestPower = -1.0
        var searched: [Double] = []
        for n in first...last {
            let p = spectrum[index(Double(n) * bin)]
            searched.append(p)
            if p > bestPower { bestPower = p; best = n }
        }
        let k = index(Double(best) * bin)
        let left = spectrum[(k - 1 + size) % size], right = spectrum[(k + 1) % size]
        // Quadratic through the log powers of the peak and its neighbours.
        let a = log(max(left, 1e-300)), b = log(max(bestPower, 1e-300)), c = log(max(right, 1e-300))
        let denominator = a - 2 * b + c
        let fraction = denominator < 0 ? max(-0.5, min(0.5, 0.5 * (a - c) / denominator)) : 0
        let offset = frequency(k) + fraction * bin
        // Half-power width: bins either side still above half the peak.
        var width = 1
        var step = 1
        while step < 200, spectrum[(k + step) % size] >= bestPower / 2 { width += 1; step += 1 }
        step = 1
        while step < 200, spectrum[(k - step + size) % size] >= bestPower / 2 { width += 1; step += 1 }
        searched.sort()
        return (offset, bestPower, max(searched[searched.count / 2], 1e-300), Double(width) * bin)
    }

    /// The line found so far; nil before a whole transform, or if the search range is not inside the spectrum.
    public func measurement() -> Measurement? {
        guard transforms > 0, let peak = peakOffset(in: power) else { return nil }
        let bin = sampleRate / Double(fft.size)
        let ppm = (carrierHz / (tunedHz + peak.offset) - 1) * 1e6
        let standardError: Double? = transformPPM.count >= 2 ? Self.standardError(transformPPM) : nil
        return Measurement(
            offsetHz: peak.offset, ppm: ppm, snrDB: 10 * log10(peak.peak / peak.median), widthHz: peak.width,
            binHz: bin, transforms: transforms,
            standardErrorPPM: standardError,
            uncertaintyPPM: standardError.map { $0 + referenceUncertaintyPPM }
        )
    }

    /// The standard error of the mean of `values` (their sample standard deviation over the root of their count).
    static func standardError(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return (variance / Double(values.count)).squareRoot()
    }

    /// The nominal pilot of an ATSC (US digital television) channel: 309 440.559 Hz above the channel's lower edge. A
    /// station may sit some way off it (within a kilohertz or so, and some deliberately), so this is a reference to a
    /// couple of ppm at UHF unless two stations agree. nil for a channel number outside 2-36.
    public static func atscPilotHz(channel: Int) -> Double? {
        let lowerEdgeMHz: Double
        switch channel {
        case 2...4: lowerEdgeMHz = 54 + Double(channel - 2) * 6
        case 5...6: lowerEdgeMHz = 76 + Double(channel - 5) * 6
        case 7...13: lowerEdgeMHz = 174 + Double(channel - 7) * 6
        case 14...36: lowerEdgeMHz = 470 + Double(channel - 14) * 6
        default: return nil
        }
        return lowerEdgeMHz * 1e6 + 309_440.559
    }
}
