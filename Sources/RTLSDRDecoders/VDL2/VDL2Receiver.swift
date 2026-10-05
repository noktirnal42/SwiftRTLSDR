// SPDX-License-Identifier: GPL-2.0-or-later
//
// VDL Mode 2 reception: D8PSK at 10500 symbols/s on 25 kHz channels, several channels from one capture. Written for
// this package (dumpvdl2's receiver was read and not followed); see PROVENANCE.md.
import Foundation

/// Bursts from one channel's complex baseband at 42 kS/s (four samples a symbol), filtered to about ±13 kHz so that a
/// carrier several kilohertz off still passes.
///
/// A burst starts with five ramp-up symbols and a 16-symbol synchronisation sequence. Each sample's product with the
/// conjugate of the sample a symbol earlier removes the carrier phase and leaves the phase steps (turned by the carrier
/// offset times a symbol), so their correlation with the sequence's steps finds a burst and its offset whatever the
/// offset is (up to half the symbol rate). For each burst found, the samples are moved by that offset and filtered for
/// the raised-cosine pulses (α 0.6) the transmitter sends: the filter turns them into α 0.35 pulses, still free of
/// intersymbol interference, with less noise than any flat filter wide enough for them. The sequence's known phases
/// then set the carrier phase, a decision-directed loop follows it, a Gardner detector follows the timing, and the phase
/// steps between decisions are the symbols (so a slip of the loop costs one symbol, not the rest of the burst).
public final class VDL2Demodulator {
    public struct Burst: Sendable {
        /// The burst's frames as received (each with its FCS, not yet checked).
        public var frames: [[UInt8]]
        /// Samples (at 42 kS/s) from the start of the stream to the burst's first synchronisation symbol.
        public var sampleIndex: Int
        public var frequencyOffsetHz: Double
        /// Mean symbol power and the noise around the decisions, dB relative to an input amplitude of 1.
        public var levelDB: Double
        public var noiseDB: Double
        /// Reed-Solomon octets repaired; the header needed a bit repaired.
        public var correctedOctets: Int
        public var headerCorrected: Bool
        public var octets: Int
    }

    public static let sampleRate = 42_000.0
    static let sps = 4
    /// Phase after each synchronisation symbol, in π/4, from the last ramp-up symbol's.
    static let syncPhases: [Int] = {
        var phase = 0
        return VDL2Burst.syncSteps.map { phase = (phase + $0) & 7; return phase }
    }()

    /// The detection threshold: |correlation| over its largest possible value for products of that energy (1 for a
    /// clean burst).
    public var threshold = 0.6
    private let taps: [Double]
    private let syncWeights: [(Double, Double)]
    private var re: [Double] = [], im: [Double] = []
    private var base = 0                                    // absolute index of re[0]
    private var next = 0                                    // the next sample to test as a burst's last sync symbol
    private var metric: [(index: Int, value: Double, re: Double, im: Double, power: Double)] = []
    private var tracks: [Track] = []
    private var quietUntil = 0
    private var noiseFloor = 0.0

    public init() {
        // Receive filter: (raised cosine α 0.35) / (raised cosine α 0.6) in frequency, ±6 symbols, Hann-windowed.
        let fs = Self.sampleRate, rs = VDL2Burst.symbolRate
        func rc(_ f: Double, _ a: Double) -> Double {
            let f1 = (1 - a) * rs / 2, f2 = (1 + a) * rs / 2, af = abs(f)
            if af <= f1 { return 1 }
            if af >= f2 { return 0 }
            return 0.5 * (1 + cos(Double.pi / (a * rs) * (af - f1)))
        }
        let half = 6 * Self.sps, steps = 2_000
        let top = (1 + 0.35) * rs / 2
        taps = (-half...half).map { n in
            var sum = 0.0
            for i in 0..<steps {
                let f = (Double(i) + 0.5) * top / Double(steps)
                sum += rc(f, 0.35) / rc(f, 0.6) * cos(2 * Double.pi * f * Double(n) / fs)
            }
            let window = 0.5 + 0.5 * cos(Double.pi * Double(n) / Double(half + 1))
            return 2 * sum * top / Double(steps) / fs * window
        }
        syncWeights = VDL2Burst.syncSteps.map { (cos(Double.pi / 4 * Double($0)), -sin(Double.pi / 4 * Double($0))) }
    }

    private var filterGain: Double { taps.reduce(0, +) }

    /// Feeds samples (interleaved I, Q); returns the bursts completed.
    public func process(_ samples: [Float]) -> [Burst] {
        re.reserveCapacity(re.count + samples.count / 2)
        for n in stride(from: 0, to: samples.count - 1, by: 2) {
            re.append(Double(samples[n]))
            im.append(Double(samples[n + 1]))
        }
        search()
        var bursts: [Burst] = []
        tracks.removeAll { track in
            switch track.advance(self) {
            case .waiting: return false
            case .failed: return true
            case .done(let burst): bursts.append(burst); return true
            }
        }
        trim()
        return bursts
    }

    // MARK: Search

    private func sample(_ n: Int) -> (Double, Double) { (re[n - base], im[n - base]) }

    private func search() {
        let span = 15 * Self.sps
        let end = base + re.count
        next = max(next, base + span + Self.sps)
        while next < end {
            let n = next
            next += 1
            var cr = 0.0, ci = 0.0, energy = 0.0, power = 0.0
            for k in 0..<16 {
                let m = n - Self.sps * (15 - k)
                let (ar, ai) = sample(m), (br, bi) = sample(m - Self.sps)
                let dr = ar * br + ai * bi, di = ai * br - ar * bi            // x[m] · conj(x[m − 4])
                let (wr, wi) = syncWeights[k]
                cr += dr * wr - di * wi
                ci += dr * wi + di * wr
                energy += dr * dr + di * di
                power += ar * ar + ai * ai
            }
            power /= 16
            // At most 1 (Cauchy-Schwarz), and 1 only when all 16 products are equal in size and turned as the steps are:
            // a window that a few strong samples dominate (a burst's ramp-up) scores low.
            let value = energy > 0 ? ((cr * cr + ci * ci) / (16 * energy)).squareRoot() : 0
            // The noise floor follows the quietest stretches: down within a few milliseconds, up over seconds (bursts
            // fill a busy channel most of the time).
            noiseFloor = noiseFloor == 0 ? power : noiseFloor + (power - noiseFloor) * (power < noiseFloor ? 0.01 : 0.00002)
            metric.append((n, value, cr, ci, power))
            if metric.count > 3 { metric.removeFirst() }
            guard metric.count == 3 else { continue }
            let (a, b, c) = (metric[0], metric[1], metric[2])
            guard b.value >= threshold, b.value > a.value, b.value >= c.value, b.index >= quietUntil,
                  noiseFloor == 0 || b.power > 2 * noiseFloor else { continue }
            // A peak: refine the timing to a fraction of a sample, and take the offset from the correlation's angle.
            let (ya, yb, yc) = (a.value, b.value, c.value)
            let denominator = ya - 2 * yb + yc
            let delta = denominator < 0 ? max(-0.5, min(0.5, 0.5 * (ya - yc) / denominator)) : 0
            let last = Double(b.index) + delta
            let offset = atan2(b.im, b.re) * VDL2Burst.symbolRate / (2 * Double.pi)
            tracks.append(Track(start: last - Double(15 * Self.sps), offsetHz: offset, taps: taps))
            quietUntil = b.index + 2 * Self.sps
        }
    }

    private func trim() {
        let keep = min(next - 20 * Self.sps, tracks.map { $0.oldestNeeded }.min() ?? Int.max) - 2 * taps.count
        let drop = keep - base
        guard drop > 50_000 else { return }
        re.removeFirst(drop)
        im.removeFirst(drop)
        base += drop
    }

    // MARK: One burst

    fileprivate final class Track {
        enum Progress { case waiting, failed, done(Burst) }

        let start: Double                       // absolute time (samples) of the first synchronisation symbol
        let offsetHz: Double
        let taps: [Double]
        private let rotation: (Double, Double)
        private var mixed: [(Double, Double)] = []
        private var mixedBase: Int
        private var phasor = (1.0, 0.0)
        private var filtered: [Int: (Double, Double)] = [:]
        private var decoder = VDL2BurstDecoder()
        private var k = 0                       // the next symbol, from the first synchronisation symbol
        private var t: Double
        private var sync: [(Double, Double)] = []
        private var theta = 0.0, omega = 0.0
        private var amplitude = 1.0
        private var previous: (Double, Double) = (0, 0)
        private var previousIndex = 0
        private var previousSureness = Float.infinity     // the last synchronisation symbol is known
        private var signal = 0.0, noise = 0.0, counted = 0

        init(start: Double, offsetHz: Double, taps: [Double]) {
            self.start = start
            self.offsetHz = offsetHz
            self.taps = taps
            t = start
            let w = -2 * Double.pi * offsetHz / VDL2Demodulator.sampleRate
            rotation = (cos(w), sin(w))
            mixedBase = Int(start.rounded(.down)) - 2 * taps.count
        }

        var oldestNeeded: Int { min(mixedBase + mixed.count, Int(t) - 2 * taps.count) }

        /// The receive filter's output at sample `n` (after moving the burst to zero).
        private func output(_ n: Int, _ d: VDL2Demodulator) -> (Double, Double)? {
            if let y = filtered[n] { return y }
            let half = taps.count / 2
            let last = n + half
            guard last < d.base + d.re.count else { return nil }
            while mixedBase + mixed.count <= last {
                let (xr, xi) = d.sample(mixedBase + mixed.count)
                mixed.append((xr * phasor.0 - xi * phasor.1, xr * phasor.1 + xi * phasor.0))
                phasor = (phasor.0 * rotation.0 - phasor.1 * rotation.1, phasor.0 * rotation.1 + phasor.1 * rotation.0)
                if mixed.count % 1024 == 0 {
                    let norm = (phasor.0 * phasor.0 + phasor.1 * phasor.1).squareRoot()
                    phasor = (phasor.0 / norm, phasor.1 / norm)
                }
            }
            var yr = 0.0, yi = 0.0
            for (i, tap) in taps.enumerated() {
                let (mr, mi) = mixed[n - half + i - mixedBase]
                yr += tap * mr
                yi += tap * mi
            }
            filtered[n] = (yr, yi)
            if filtered.count > 64 { filtered = filtered.filter { $0.key >= n - 16 } }
            return (yr, yi)
        }

        /// Cubic (Lagrange) interpolation of the filter's output at time `time`.
        private func value(at time: Double, _ d: VDL2Demodulator) -> (Double, Double)? {
            let i = Int(time.rounded(.down)), mu = time - Double(i)
            guard let y0 = output(i - 1, d), let y1 = output(i, d), let y2 = output(i + 1, d), let y3 = output(i + 2, d) else { return nil }
            let c0 = -mu * (mu - 1) * (mu - 2) / 6, c1 = (mu + 1) * (mu - 1) * (mu - 2) / 2
            let c2 = -(mu + 1) * mu * (mu - 2) / 2, c3 = (mu + 1) * mu * (mu - 1) / 6
            return (c0 * y0.0 + c1 * y1.0 + c2 * y2.0 + c3 * y3.0, c0 * y0.1 + c1 * y1.1 + c2 * y2.1 + c3 * y3.1)
        }

        func advance(_ d: VDL2Demodulator) -> Progress {
            let sps = Double(VDL2Demodulator.sps)
            while true {
                guard let r = value(at: t, d) else { return .waiting }
                if k < 16 {
                    sync.append(r)
                    k += 1
                    t += sps
                    if k == 16 { startTracking() }
                    previous = r
                    continue
                }
                guard let middle = value(at: t - sps / 2, d) else { return .waiting }
                // Carrier: predict, decide the nearest of the eight phases, correct.
                theta += omega
                let (c, s) = (cos(theta), sin(theta))
                let zr = r.0 * c + r.1 * s, zi = r.1 * c - r.0 * s
                let index = Int((atan2(zi, zr) / (Double.pi / 4)).rounded()) & 7
                let ideal = Double(index) * Double.pi / 4
                let er = zr * cos(ideal) + zi * sin(ideal), ei = zi * cos(ideal) - zr * sin(ideal)
                let error = atan2(ei, er)
                let sureness = Float(Double.pi / 8 - abs(error))
                theta += 0.08 * error
                omega += 0.002 * error
                signal += er * er + ei * ei
                noise += ei * ei + (er - amplitude) * (er - amplitude)
                counted += 1
                // Timing: Gardner's detector on the samples a half symbol apart.
                let timing = (middle.0 * (previous.0 - r.0) + middle.1 * (previous.1 - r.1)) / (amplitude * amplitude)
                t += sps + 0.05 * max(-1, min(1, timing))
                previous = r
                let step = (index - previousIndex) & 7
                previousIndex = index
                // A step is as sure as the less sure of the two decisions it lies between.
                let reliability = min(sureness, previousSureness)
                previousSureness = sureness
                k += 1
                switch decoder.push(step: step, reliability: reliability) {
                case .more:
                    continue
                case .failed:
                    return .failed
                case .frames(let frames, let corrected, let headerCorrected, let octets):
                    let level = signal / Double(max(1, counted))
                    let noisePower = noise / Double(max(1, counted))
                    let gain = d.filterGain
                    return .done(Burst(frames: frames, sampleIndex: Int(start.rounded()), frequencyOffsetHz: offsetHz + omega / (2 * Double.pi) * VDL2Burst.symbolRate,
                                       levelDB: 10 * log10(max(level, 1e-20) / (gain * gain)),
                                       noiseDB: 10 * log10(max(noisePower, 1e-20) / (gain * gain)),
                                       correctedOctets: corrected, headerCorrected: headerCorrected, octets: octets))
                }
            }
        }

        /// The carrier's phase and the remaining frequency error from the synchronisation symbols' known phases.
        private func startTracking() {
            var unwrapped: [Double] = []
            var last = 0.0
            amplitude = 0
            for (n, r) in sync.enumerated() {
                let known = Double(VDL2Demodulator.syncPhases[n]) * Double.pi / 4
                var angle = atan2(r.1, r.0) - known
                while angle - last > Double.pi { angle -= 2 * Double.pi }
                while angle - last < -Double.pi { angle += 2 * Double.pi }
                unwrapped.append(angle)
                last = angle
                amplitude += (r.0 * r.0 + r.1 * r.1).squareRoot()
            }
            amplitude /= 16
            let mean = unwrapped.reduce(0, +) / 16
            var slope = 0.0, denominator = 0.0
            for (n, angle) in unwrapped.enumerated() {
                slope += (Double(n) - 7.5) * (angle - mean)
                denominator += (Double(n) - 7.5) * (Double(n) - 7.5)
            }
            omega = slope / denominator
            theta = mean + omega * 7.5
            previousIndex = 0                   // the last synchronisation symbol's phase, by definition
        }
    }
}

/// VDL Mode 2 from u8 I/Q: channels anywhere inside the capture, each moved to zero and decimated to 42 kS/s.
public final class VDL2Receiver {
    public struct Reception: Sendable {
        public var frame: AVLCFrame
        public var burst: VDL2Demodulator.Burst
        public var channel: Int
        public var frequencyHz: Double
        /// Input samples from the start of the stream to the burst.
        public var sampleIndex: Int
    }

    public let sampleRate: Double
    public let centerHz: Double
    public let channels: [Double]
    private var paths: [Path]
    /// Frames whose FCS failed (bursts that decoded but carried a damaged frame).
    public private(set) var badFrames = 0

    /// - Parameters:
    ///   - sampleRate: a multiple of 42 kHz (1.05, 1.68, 2.1 MS/s, …).
    ///   - channels: hertz; each within ±(sampleRate/2 − 30 kHz) of `centerHz`.
    public init(sampleRate: Double, centerHz: Double, channels: [Double]) {
        precondition(!channels.isEmpty)
        let total = Int((sampleRate / VDL2Demodulator.sampleRate).rounded())
        precondition(Double(total) * VDL2Demodulator.sampleRate == sampleRate, "the sample rate must be a multiple of 42 kHz")
        self.sampleRate = sampleRate
        self.centerHz = centerHz
        self.channels = channels
        let first = (2...16).reversed().first { total % $0 == 0 } ?? 1
        paths = channels.map { Path(sampleRate: sampleRate, offsetHz: $0 - centerHz, first: first, second: total / first) }
    }

    public func process(iq block: [UInt8]) -> [Reception] {
        var receptions: [Reception] = []
        let total = Int((sampleRate / VDL2Demodulator.sampleRate).rounded())
        for (n, path) in paths.enumerated() {
            for burst in path.process(block) {
                for bytes in burst.frames {
                    guard let frame = AVLCFrame(bytes: bytes) else { badFrames += 1; continue }
                    receptions.append(Reception(frame: frame, burst: burst, channel: n, frequencyHz: channels[n],
                                                sampleIndex: burst.sampleIndex * total))
                }
            }
        }
        return receptions.sorted { $0.sampleIndex < $1.sampleIndex }
    }

    /// One channel: oscillator, second-order CIC (integer, wrapping), a low-pass FIR to 42 kS/s, the demodulator.
    final class Path {
        let demodulator = VDL2Demodulator()
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
            // Flat to ±13 kHz (the signal reaches 8.4 kHz, plus a carrier offset), down by 29 kHz (whatever folds back
            // from above 21 kHz lands outside ±13 kHz). Hann-windowed sinc, unity gain; amplitude 1 is full scale.
            let count = Int((4 * middle / 16_000).rounded()) | 1
            let cutoff = 2 * 21_000 / middle
            let raw = (0..<count).map { n -> Double in
                let t = Double(n - count / 2)
                let sinc = t == 0 ? cutoff : sin(Double.pi * cutoff * t) / (Double.pi * t)
                return sinc * (0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(count - 1)))
            }
            let gain = raw.reduce(0, +) * 127.5
            taps = raw.map { $0 / gain }
            historyI = [Double](repeating: 0, count: count)
            historyQ = [Double](repeating: 0, count: count)
        }

        func process(_ block: [UInt8]) -> [VDL2Demodulator.Burst] {
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
            return demodulator.process(out)
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
}
