// SPDX-License-Identifier: GPL-2.0-or-later
//
// LoRa reception: channel filter, preamble detection, carrier and timing synchronisation, symbol demodulation.
// Written for this package. The synchronisation uses the relations the LoRa literature describes (an up-chirp's
// dechirped peak moves with timing and frequency offset alike, a down-chirp's with frequency but against timing).
import Foundation

/// One LoRa frame received.
public struct LoRaFrame: Sendable {
    public var header: LoRaHeader
    public var payload: [UInt8]
    /// Whether the payload CRC held (nil if the frame had none).
    public var crcValid: Bool?
    public var symbols: [Int]
    /// Where the frame's preamble was found, in input samples since the stream began.
    public var sampleIndex: Double
    /// The transmitter's carrier relative to the tuned frequency, hertz.
    public var carrierOffsetHz: Double
    /// Signal to noise in the LoRa bandwidth, from the preamble, dB.
    public var snrDB: Double
}

/// Receives LoRa frames with an explicit header from u8 I/Q or complex float samples.
///
/// The input rate must be a whole multiple of the bandwidth (1 MS/s for 125, 250 or 500 kHz). A low-pass keeps the
/// channel; every `oversampling`-th sample then makes up a chirp of 2^SF chips, at a phase chosen to the sample.
/// Preamble up-chirps, dechirped and transformed, peak at the same bin window after window (the sum of timing and
/// frequency offset); the fractional frequency offset is the peak's phase advance per symbol; the down-chirps of the
/// start-of-frame delimiter peak at the frequency offset minus the timing, which separates the two. With the frame
/// aligned and the carrier removed, the sync word must be where it belongs, and the symbols are read one by one; their
/// spacing follows the carrier offset (a transmitter whose crystal is fast is fast in both), given the RF frequency.
public final class LoRaReceiver {
    public let parameters: LoRaParameters
    public let sampleRate: Double
    public let oversampling: Int
    /// The RF frequency the receiver listens on, for the clock drift that goes with a carrier offset (nil: none).
    public let centerFrequencyHz: Double?
    public var detectionThreshold = 8.0              // preamble peak over the mean of the other bins, as a power ratio
    public private(set) var rejectedPreambles = 0

    private let chips: Int
    private let symbolSamples: Int
    private let fft: RadixTwoFFT
    private let upchirp: [(Double, Double)]
    private var fftReal: [Double], fftImaginary: [Double]
    // Front end: oscillator and low-pass at the input rate.
    private let offsetHz: Double
    private var oscillator = (1.0, 0.0)
    private var rotations = 0
    private let taps: [Float]
    private var historyI: [Float], historyQ: [Float], historyIndex = 0
    // Filtered samples.
    private var re: [Float] = [], im: [Float] = []
    private var base = 0                               // stream index of re[0]
    private var position = 0                           // next search window, in re/im
    private var run: [(window: Int, bin: Int, real: Double, imaginary: Double)] = []      // preamble windows, stream index
    private var leftoverByte: UInt8?, leftoverFloat: Float?   // the I of a pair split between blocks

    /// - Parameters:
    ///   - offsetHz: where the channel sits relative to the tuned frequency.
    ///   - centerFrequencyHz: the RF frequency, for following the symbol clock (nil if unknown; ignored below 1 MHz).
    public init(parameters: LoRaParameters, sampleRate: Double, offsetHz: Double = 0, centerFrequencyHz: Double? = nil) {
        self.parameters = parameters
        self.sampleRate = sampleRate
        self.offsetHz = offsetHz
        self.centerFrequencyHz = centerFrequencyHz.flatMap { $0 >= 1e6 ? $0 : nil }
        oversampling = max(1, Int((sampleRate / parameters.bandwidth).rounded()))
        precondition(abs(Double(oversampling) * parameters.bandwidth - sampleRate) < 1, "the sample rate must be a multiple of the bandwidth")
        chips = parameters.chips
        symbolSamples = chips * oversampling
        fft = RadixTwoFFT(size: chips)
        fftReal = [Double](repeating: 0, count: chips)
        fftImaginary = [Double](repeating: 0, count: chips)
        let n = Double(chips)
        upchirp = (0..<chips).map { k in
            let phase = 2 * Double.pi * (Double(k * k) / (2 * n) - Double(k) / 2)
            return (cos(phase), sin(phase))
        }
        // Low-pass with its edges at ±0.7 × bandwidth, flat past the ±half the chirps sweep (the rest is room for a
        // carrier offset), windowed sinc; none at one sample a chip.
        if oversampling > 1 {
            let count = 16 * oversampling + 1, cutoff = 2 * 0.7 * parameters.bandwidth / sampleRate
            taps = (0..<count).map { n in
                let t = Double(n - count / 2)
                let sinc = t == 0 ? cutoff : sin(Double.pi * cutoff * t) / (Double.pi * t)
                return Float(sinc * (0.54 - 0.46 * cos(2 * Double.pi * Double(n) / Double(count - 1))))
            }
        } else {
            taps = [1]
        }
        historyI = [Float](repeating: 0, count: taps.count)
        historyQ = [Float](repeating: 0, count: taps.count)
    }

    // MARK: Input

    /// Interleaved u8 I/Q, as the dongle gives it; a block may end between the I and Q of a sample.
    public func process(iq block: [UInt8]) -> [LoRaFrame] {
        var index = 0
        if let i = leftoverByte, !block.isEmpty {
            push(Float(i) - 127.5, Float(block[0]) - 127.5)
            leftoverByte = nil
            index = 1
        }
        while index + 1 < block.count {
            push(Float(block[index]) - 127.5, Float(block[index + 1]) - 127.5)
            index += 2
        }
        if index < block.count { leftoverByte = block[index] }
        return demodulate()
    }

    /// Interleaved complex floats (I, Q), as GNU Radio and SDR programs write them.
    public func process(complex block: [Float]) -> [LoRaFrame] {
        var index = 0
        if let i = leftoverFloat, !block.isEmpty {
            push(i, block[0])
            leftoverFloat = nil
            index = 1
        }
        while index + 1 < block.count {
            push(block[index], block[index + 1])
            index += 2
        }
        if index < block.count { leftoverFloat = block[index] }
        return demodulate()
    }

    @inline(__always)
    private func push(_ i: Float, _ q: Float) {
        var x = i, y = q
        if offsetHz != 0 {
            let (c, s) = oscillator
            x = Float(Double(i) * c - Double(q) * s)
            y = Float(Double(i) * s + Double(q) * c)
            let step = -2 * Double.pi * offsetHz / sampleRate
            oscillator = (c * cos(step) - s * sin(step), c * sin(step) + s * cos(step))
            rotations += 1
            if rotations == 4096 {
                let norm = (oscillator.0 * oscillator.0 + oscillator.1 * oscillator.1).squareRoot()
                oscillator = (oscillator.0 / norm, oscillator.1 / norm)
                rotations = 0
            }
        }
        if taps.count == 1 { re.append(x); im.append(y); return }
        historyI[historyIndex] = x
        historyQ[historyIndex] = y
        var fi: Float = 0, fq: Float = 0, h = historyIndex
        for tap in taps {
            fi += tap * historyI[h]; fq += tap * historyQ[h]
            h = h == 0 ? taps.count - 1 : h - 1
        }
        historyIndex = (historyIndex + 1) % taps.count
        re.append(fi)
        im.append(fq)
    }

    // MARK: Chirps

    private struct Peak {
        var bin: Int
        var power: Double
        var ratio: Double                 // peak power over the mean of the other bins
        var real: Double, imaginary: Double
        /// Signal to noise in the bandwidth: the peak and its neighbours over the bins away from it.
        var snr: Double
        /// Where between the bins the peak lies, −0.5 … 0.5 (Jacobsen's estimate from the peak and its neighbours).
        var fraction: Double
    }

    /// Dechirps the chirp of `chips` samples from `start` (every `oversampling`-th sample), removing `cfo` bins of
    /// carrier offset, and returns the strongest bin. `down`: the chirp is a down-chirp. `window`: taper the samples
    /// (Hann) first, so that a fraction of a chip of timing error leaks no power far from the peak (for measuring).
    private func peak(at start: Int, down: Bool = false, cfo: Double = 0, window: Bool = false) -> Peak {
        let n = Double(chips)
        for k in 0..<chips {
            let x = Double(re[start + k * oversampling]), y = Double(im[start + k * oversampling])
            let (c, s) = upchirp[k]
            // × conj(up-chirp) for up-chirps, × up-chirp for down-chirps.
            var a = down ? x * c - y * s : x * c + y * s
            var b = down ? x * s + y * c : y * c - x * s
            if cfo != 0 {
                let phase = -2 * Double.pi * cfo * Double(k) / n
                let (pc, ps) = (cos(phase), sin(phase))
                (a, b) = (a * pc - b * ps, a * ps + b * pc)
            }
            let taper = window ? 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / n) : 1
            fftReal[k] = a * taper
            fftImaginary[k] = b * taper
        }
        fft.forward(real: &fftReal, imaginary: &fftImaginary)
        var best = 0, bestPower = -1.0, total = 0.0
        for k in 0..<chips {
            let power = fftReal[k] * fftReal[k] + fftImaginary[k] * fftImaginary[k]
            total += power
            if power > bestPower { bestPower = power; best = k }
        }
        let others = max(1e-30, (total - bestPower) / Double(chips - 1))
        var near = 0.0
        for d in -2...2 {
            let k = wrap(best + d)
            let power = fftReal[k] * fftReal[k] + fftImaginary[k] * fftImaginary[k]
            near += power
        }
        let noise = max(1e-30, (total - near) / Double(chips - 5))
        let signal = max(0, near - 5 * noise)
        // (X[k−1] − X[k+1]) / (2X[k] − X[k−1] − X[k+1]), real part.
        let l = wrap(best - 1), r = wrap(best + 1)
        let numerator = (fftReal[l] - fftReal[r], fftImaginary[l] - fftImaginary[r])
        let denominator = (2 * fftReal[best] - fftReal[l] - fftReal[r], 2 * fftImaginary[best] - fftImaginary[l] - fftImaginary[r])
        let magnitude = denominator.0 * denominator.0 + denominator.1 * denominator.1
        let fraction = magnitude > 0 ? (numerator.0 * denominator.0 + numerator.1 * denominator.1) / magnitude : 0
        return Peak(bin: best, power: bestPower, ratio: bestPower / others, real: fftReal[best], imaginary: fftImaginary[best],
                    snr: signal / noise / Double(chips), fraction: max(-0.5, min(0.5, fraction)))
    }

    private func wrap(_ bin: Int) -> Int { (bin % chips + chips) % chips }

    /// Distance between two bins around the circle.
    private func apart(_ a: Int, _ b: Int) -> Int { min(wrap(a - b), wrap(b - a)) }

    // MARK: Frames

    private func demodulate() -> [LoRaFrame] {
        var frames: [LoRaFrame] = []
        let p = parameters
        // Room for the rest of the preamble, the sync word and the delimiter after a detection.
        let lookahead = (p.preambleLength + 8) * symbolSamples
        while position + symbolSamples <= re.count {
            // A window waiting for the samples after it was measured already (measuring it twice would put a zero
            // phase step in the run).
            if run.last?.window != base + position {
                let found = peak(at: position)
                let entry = (window: base + position, bin: found.bin, real: found.real, imaginary: found.imaginary)
                if found.ratio >= detectionThreshold, let last = run.last, apart(found.bin, last.bin) <= 1 {
                    run.append(entry)
                } else {
                    run = found.ratio >= detectionThreshold ? [entry] : []
                }
            }
            guard run.count >= 4 else { position += symbolSamples; continue }
            guard position + lookahead + symbolSamples <= re.count else { break }     // wait for more samples
            switch attempt(at: position) {
            case .frame(let frame, let end):
                frames.append(frame)
                position = end
                run = []
            case .needMore:
                return frames + finishTrim()
            case .none:
                rejectedPreambles += 1
                position += symbolSamples
                run = []
            }
        }
        return frames + finishTrim()
    }

    private func finishTrim() -> [LoRaFrame] {
        let drop = position - symbolSamples
        if drop > 4 * symbolSamples + 1_000_000 {
            re.removeFirst(drop)
            im.removeFirst(drop)
            base += drop
            position -= drop
        }
        return []
    }

    private enum Attempt {
        case frame(LoRaFrame, end: Int)
        case needMore
        case none
    }

    /// Synchronises on the preamble whose last window found so far starts at `window`, then reads the frame.
    private func attempt(at window: Int) -> Attempt {
        let p = parameters
        // Fractional carrier offset: the peak's phase advance from one preamble chirp to the next. A tone between bins
        // turns by π(N−1)/N from one bin to the next, so a peak that moved a bin (the clock drifting) is turned back.
        var sumReal = 0.0, sumImaginary = 0.0
        for index in 1..<run.count {
            let (a, b) = (run[index].real, run[index].imaginary), (c, d) = (run[index - 1].real, -run[index - 1].imaginary)
            var moved = wrap(run[index].bin - run[index - 1].bin)
            if moved > chips / 2 { moved -= chips }
            let turn = Double.pi * Double(moved) * Double(chips - 1) / Double(chips)
            let (re, im) = (a * c - b * d, a * d + b * c)
            sumReal += re * cos(turn) - im * sin(turn)
            sumImaginary += re * sin(turn) + im * cos(turn)
        }
        let fraction = atan2(sumImaginary, sumReal) / (2 * Double.pi)
        let up = peak(at: window, cfo: fraction)

        // The delimiter: the window, among the next few, where a down-chirp stands out most.
        var down: Peak?, downWindow = -1
        for step in 1...(p.preambleLength + 6) {
            let at = window + step * symbolSamples
            guard at + symbolSamples <= re.count else { return .needMore }
            let candidate = peak(at: at, down: true, cfo: fraction)
            if candidate.ratio >= detectionThreshold && candidate.power > peak(at: at, cfo: fraction).power
                && candidate.power > (down?.power ?? 0) {
                down = candidate
                downWindow = step
            }
        }
        guard let down else { return .none }
        // Up = timing + offset, down = offset − timing (mod chips), fractions included. With the fractional offset
        // already removed the rest is a whole number of bins, so rounding sheds the noise; it is taken within a quarter
        // of the bandwidth. The timing runs on by offset × bandwidth / RF chips a window (the clock drift) between the
        // two measurements, which takes that much times half the windows between them off the mean.
        let upPosition = Double(up.bin) + up.fraction, downPosition = Double(down.bin) + down.fraction
        var mean = (upPosition + downPosition) / 2
        while mean > Double(chips) / 4 { mean -= Double(chips) / 2 }
        while mean <= -Double(chips) / 4 { mean += Double(chips) / 2 }
        if let rf = centerFrequencyHz { mean /= 1 - Double(downWindow) * p.bandwidth / (2 * rf) }
        let whole = mean.rounded()
        var timing = (upPosition - whole).truncatingRemainder(dividingBy: Double(chips))   // chips the window runs late
        if timing < 0 { timing += Double(chips) }
        let totalCFO = whole + fraction
        var start = window - Int((timing * Double(oversampling)).rounded())
        while start < 0 { start += symbolSamples }
        // Refine to the sample, the carrier offset fixed: the preamble peak at bin 0, strongest.
        var bestStart = start, bestPower = -1.0
        for delta in -oversampling...oversampling where start + delta >= 0 {
            let candidate = peak(at: start + delta, cfo: totalCFO)
            if candidate.bin == 0 && candidate.power > bestPower { bestPower = candidate.power; bestStart = start + delta }
        }
        start = bestStart

        // The sync word: two symbols at their offsets, within the chirps that follow.
        let (sync0, sync1) = p.syncSymbols
        var syncIndex = -1
        for k in 0...(p.preambleLength + 4) {
            let first = start + k * symbolSamples
            guard first + 2 * symbolSamples <= re.count else { return .needMore }
            if apart(peak(at: first, cfo: totalCFO).bin, sync0) <= 1 && apart(peak(at: first + symbolSamples, cfo: totalCFO).bin, sync1) <= 1 {
                syncIndex = k
                break
            }
        }
        guard syncIndex >= 0 else { return .none }
        // Signal to noise on the last preamble chirp (tapered: the Hann window's power loss cancels in the ratio, its
        // noise bandwidth of 1.5 bins does not).
        let preamble = peak(at: start + max(0, syncIndex - 1) * symbolSamples, cfo: totalCFO, window: true)
        let snr = 10 * log10(max(1e-9, preamble.snr * 1.5))

        // Symbols: after the sync word and 2.25 down-chirps, spaced by the symbol clock the carrier offset implies.
        let offsetHz = totalCFO * p.bandwidth / Double(chips)
        let drift = centerFrequencyHz.map { offsetHz / $0 } ?? 0
        let spacing = Double(symbolSamples) * (1 - drift)
        // From the aligned preamble chirp on, every symbol is `spacing` long (the sync word and the delimiter too).
        let dataStart = Double(start) + (Double(syncIndex) + 4.25) * spacing
        func symbol(_ index: Int) -> Int? {
            let at = Int((dataStart + Double(index) * spacing).rounded())
            guard at + symbolSamples <= re.count else { return nil }
            return peak(at: at, cfo: totalCFO).bin
        }
        var symbols: [Int] = []
        for index in 0..<8 {
            guard let value = symbol(index) else { return .needMore }
            symbols.append(value)
        }
        guard let (header, _) = LoRaCoding.header(symbols[...], p) else { return .none }
        let total = 8 + LoRaCoding.payloadSymbols(header, p)
        for index in 8..<total {
            guard let value = symbol(index) else { return .needMore }
            symbols.append(value)
        }
        guard let decoded = LoRaCoding.decode(symbols, p) else { return .none }
        let end = Int((dataStart + Double(total) * spacing).rounded())
        let frame = LoRaFrame(header: header, payload: decoded.payload, crcValid: decoded.crcValid, symbols: symbols,
                              sampleIndex: Double(base + start), carrierOffsetHz: offsetHz + self.offsetHz, snrDB: snr)
        return .frame(frame, end: end)
    }
}
