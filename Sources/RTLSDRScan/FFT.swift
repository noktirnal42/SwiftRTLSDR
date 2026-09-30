// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A complex, in-place, radix-2 FFT. Plain Swift, so it builds everywhere; fast enough for scanning (a 1024-point
/// transform is tens of microseconds).
public struct FFT: Sendable {
    public let size: Int
    private let cosines: [Double]          // cos(2πk/size), k < size/2
    private let sines: [Double]
    private let bitReversed: [Int]

    /// nil unless `size` is a power of two, at least 2.
    public init?(size: Int) {
        guard size >= 2, size & (size - 1) == 0 else { return nil }
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

    /// X[k] = Σ x[n]·e^(−2πikn/N), unscaled. Both arrays must hold `size` values.
    public func forward(real: inout [Double], imaginary: inout [Double]) {
        precondition(real.count == size && imaginary.count == size, "the FFT needs exactly \(size) values")
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                for index in 0..<size {
                    let partner = bitReversed[index]
                    if partner > index {
                        re.swapAt(index, partner)
                        im.swapAt(index, partner)
                    }
                }
                var length = 2
                while length <= size {
                    let half = length / 2
                    let stride = size / length
                    var start = 0
                    while start < size {
                        for k in 0..<half {
                            let wr = cosines[k * stride], wi = -sines[k * stride]
                            let a = start + k, b = a + half
                            let tr = wr * re[b] - wi * im[b]
                            let ti = wr * im[b] + wi * re[b]
                            re[b] = re[a] - tr
                            im[b] = im[a] - ti
                            re[a] += tr
                            im[a] += ti
                        }
                        start += length
                    }
                    length <<= 1
                }
            }
        }
    }
}

/// Averaged power spectra (Welch's method without overlap) of interleaved unsigned 8-bit I/Q.
///
/// Bins are in frequency order with DC at index `fftSize / 2`: bin `j` sits at `(j − fftSize/2) · sampleRate / fftSize`
/// from the tuned frequency. Power is linear and relative to a full-scale complex tone, which reads 1 (0 dB) in its bin.
public struct SpectrumEstimator: Sendable {
    public let fftSize: Int
    private let fft: FFT
    private let window: [Double]
    private let normalisation: Double

    /// nil unless `fftSize` is a power of two, at least 2.
    public init?(fftSize: Int) {
        guard let fft = FFT(size: fftSize) else { return nil }
        self.fftSize = fftSize
        self.fft = fft
        // Hann window: low leakage, so a strong carrier does not raise the floor far from itself.
        window = (0..<fftSize).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize)) }
        let sum = window.reduce(0, +)
        normalisation = 1 / (sum * sum)
    }

    /// How many transforms `byteCount` bytes provide.
    public func frames(inByteCount byteCount: Int) -> Int { byteCount / (2 * fftSize) }

    /// The average of as many whole transforms as the samples hold; nil if they hold none.
    public func averagePower(_ bytes: UnsafeBufferPointer<UInt8>) -> [Double]? {
        let frames = frames(inByteCount: bytes.count)
        guard frames > 0 else { return nil }
        var sum = [Double](repeating: 0, count: fftSize)
        var real = [Double](repeating: 0, count: fftSize)
        var imaginary = [Double](repeating: 0, count: fftSize)
        for frame in 0..<frames {
            let base = frame * fftSize * 2
            for n in 0..<fftSize {
                real[n] = (Double(bytes[base + 2 * n]) - 127.5) / 127.5 * window[n]
                imaginary[n] = (Double(bytes[base + 2 * n + 1]) - 127.5) / 127.5 * window[n]
            }
            fft.forward(real: &real, imaginary: &imaginary)
            // Reorder so that negative frequencies come first (DC in the middle).
            let half = fftSize / 2
            for k in 0..<fftSize {
                let source = (k + half) % fftSize
                sum[k] += real[source] * real[source] + imaginary[source] * imaginary[source]
            }
        }
        let scale = normalisation / Double(frames)
        return sum.map { $0 * scale }
    }

    public func averagePower(_ bytes: [UInt8]) -> [Double]? {
        bytes.withUnsafeBufferPointer { averagePower($0) }
    }
}
