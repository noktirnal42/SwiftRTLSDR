// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A coarse carrier-offset estimate for QPSK and offset QPSK, to start the demodulator's carrier loop close to the
/// carrier instead of sweeping for it (meteor_demod sweeps, which takes seconds and can settle on a false lock).
///
/// Raising the signal to the fourth power strips the modulation: every QPSK point to the fourth power is the same, so
/// the result has a spectral line at four times the carrier offset. Offset QPSK has it too: I and Q are independent
/// ±1 pulse trains, and (I + jQ)⁴ has the same non-zero mean whatever the half-symbol delay between them.
/// The samples lose their DC, are raised to the fourth power, summed in groups down to about 36 kHz, and transformed;
/// four transforms (about 0.45 s) are averaged, and the strongest line within the search range is the estimate (a
/// line that stands out clearly sooner, as a good signal's does after one transform, is reported at once). A
/// continuous-wave spur also has a line there (a tone to the fourth power is a tone), so the plain spectrum is
/// checked too: a suppressed-carrier signal has no line at its carrier, a spur does.
struct LRPTCarrierSearch {
    struct Estimate: Sendable {
        /// Carrier offset, in hertz.
        var hz: Double
        /// The line's height over the median of the search range, in dB (noise alone reaches about 7 over four
        /// transforms, 12 over one).
        var strengthDB: Double
        /// A line at the same frequency in the plain spectrum: a tone, not a modulated carrier.
        var isTone: Bool
    }

    static let size = 4096
    static let averages = 4
    /// Strength that ends the averaging early.
    static let clearLineDB = 20.0

    let maximumHz: Double
    private let decimation: Int
    private let outputRate: Double
    private let fft = RadixTwoFFT(size: size)
    private let window: [Double]
    private var biasI = 0.0, biasQ = 0.0
    private var sumI = 0.0, sumQ = 0.0, plainI = 0.0, plainQ = 0.0
    private var summed = 0
    private var real = [Double](repeating: 0, count: size), imaginary = [Double](repeating: 0, count: size)
    private var plainReal = [Double](repeating: 0, count: size), plainImaginary = [Double](repeating: 0, count: size)
    private var filled = 0
    private var power = [Double](repeating: 0, count: size), plainPower = [Double](repeating: 0, count: size)
    private var transforms = 0

    init(sampleRate: Double, maximumHz: Double) {
        self.maximumHz = maximumHz
        decimation = max(1, Int(sampleRate / 36_000))
        outputRate = sampleRate / Double(decimation)
        window = (0..<Self.size).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(Self.size)) }
    }

    /// Takes one sample; every `averages` transforms, or sooner for a clear line, returns an estimate.
    mutating func push(_ i: Float, _ q: Float) -> Estimate? {
        biasI += 0.001 * (Double(i) - biasI)
        biasQ += 0.001 * (Double(q) - biasQ)
        let x = Double(i) - biasI, y = Double(q) - biasQ
        let squareI = x * x - y * y, squareQ = 2 * x * y
        sumI += squareI * squareI - squareQ * squareQ
        sumQ += 2 * squareI * squareQ
        plainI += x
        plainQ += y
        summed += 1
        guard summed == decimation else { return nil }
        real[filled] = sumI * window[filled]
        imaginary[filled] = sumQ * window[filled]
        plainReal[filled] = plainI * window[filled]
        plainImaginary[filled] = plainQ * window[filled]
        sumI = 0; sumQ = 0; plainI = 0; plainQ = 0; summed = 0
        filled += 1
        guard filled == Self.size else { return nil }
        filled = 0
        fft.forward(real: &real, imaginary: &imaginary)
        fft.forward(real: &plainReal, imaginary: &plainImaginary)
        for k in 0..<Self.size {
            power[k] += real[k] * real[k] + imaginary[k] * imaginary[k]
            plainPower[k] += plainReal[k] * plainReal[k] + plainImaginary[k] * plainImaginary[k]
        }
        transforms += 1
        let result = estimate()
        guard transforms == Self.averages || result.strengthDB >= Self.clearLineDB else { return nil }
        for k in 0..<Self.size { power[k] = 0; plainPower[k] = 0 }
        transforms = 0
        return result
    }

    /// Bin k of an N-point transform at `rate` is at (k < N/2 ? k : k − N) · rate / N.
    private func frequency(_ bin: Double) -> Double {
        (bin < Double(Self.size / 2) ? bin : bin - Double(Self.size)) * outputRate / Double(Self.size)
    }

    private func estimate() -> Estimate {
        let n = Self.size
        let reach = min(n / 2 - 2, Int(4 * maximumHz / outputRate * Double(n)))
        let bins = Array(0...reach) + Array((n - reach)..<n)
        var best = 0
        for k in bins where power[k] > power[best] { best = k }
        // Parabolic interpolation between the neighbouring bins (logarithmic, for the Hann window).
        let left = log(max(1e-300, power[(best + n - 1) % n])), centre = log(max(1e-300, power[best]))
        let right = log(max(1e-300, power[(best + 1) % n]))
        let denominator = left - 2 * centre + right
        let shift = denominator < 0 ? max(-0.5, min(0.5, 0.5 * (left - right) / denominator)) : 0
        let hz = frequency(Double(best) + shift) / 4

        let strength = 10 * log10(max(1e-300, power[best]) / max(1e-300, Self.median(bins.map { power[$0] })))
        // The plain spectrum at the same frequency (one bin either side), against its own median.
        let plainBin = Int((hz / outputRate * Double(n)).rounded())
        let plainPeak = (-1...1).map { plainPower[((plainBin + $0) % n + n) % n] }.max()!
        let plainMedian = Self.median(bins.map { plainPower[$0] })
        let isTone = plainPeak > 30 * plainMedian
        return Estimate(hz: hz, strengthDB: strength, isTone: isTone)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}

/// An in-place radix-2 FFT (the same transform as RTLSDRScan's `FFT`; RTLSDRDecoders depends on no other module).
struct RadixTwoFFT {
    let size: Int
    private let cosines: [Double]
    private let sines: [Double]
    private let bitReversed: [Int]

    init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "the FFT size must be a power of two")
        self.size = size
        cosines = (0..<size / 2).map { cos(2 * Double.pi * Double($0) / Double(size)) }
        sines = (0..<size / 2).map { sin(2 * Double.pi * Double($0) / Double(size)) }
        let bits = size.trailingZeroBitCount
        bitReversed = (0..<size).map { index in
            var reversed = 0
            for bit in 0..<bits where index & (1 << bit) != 0 { reversed |= 1 << (bits - 1 - bit) }
            return reversed
        }
    }

    /// X[k] = Σ x[n]·e^(−2πikn/N), unscaled.
    func forward(real: inout [Double], imaginary: inout [Double]) {
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                for index in 0..<size {
                    let partner = bitReversed[index]
                    if partner > index { re.swapAt(index, partner); im.swapAt(index, partner) }
                }
                var length = 2
                while length <= size {
                    let half = length / 2, stride = size / length
                    var start = 0
                    while start < size {
                        for k in 0..<half {
                            let wr = cosines[k * stride], wi = -sines[k * stride]
                            let a = start + k, b = a + half
                            let tr = wr * re[b] - wi * im[b], ti = wr * im[b] + wi * re[b]
                            re[b] = re[a] - tr; im[b] = im[a] - ti
                            re[a] += tr; im[a] += ti
                        }
                        start += length
                    }
                    length <<= 1
                }
            }
        }
    }
}
