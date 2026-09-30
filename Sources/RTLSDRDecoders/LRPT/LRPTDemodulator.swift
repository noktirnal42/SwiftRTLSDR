// SPDX-License-Identifier: GPL-2.0-or-later
//
// QPSK / OQPSK demodulation for Meteor-M LRPT, ported from meteor_demod by dbdexter-dev (MIT licence,
// https://github.com/dbdexter-dev/meteor_demod: demod.c and dsp/agc.c, filter.c, pll.c, timing.c, sincos.c; copyright
// notice in NOTICE): a DC-removing AGC, a root-raised-cosine matched filter that also interpolates, a Costas-style
// carrier loop and a Mueller-Müller symbol clock. See PROVENANCE.md. Unlike meteor_demod, the carrier loop is started
// from a coarse estimate (`LRPTCarrierSearch`) rather than left to sweep, and moved off false locks.
import Foundation

/// Turns u8 I/Q into soft QPSK symbols (signed bytes, I then Q) for `LRPTFrameDecoder`.
public final class LRPTDemodulator {
    public struct Status: Sendable {
        /// Carrier offset the loop is tracking, in hertz.
        public var carrierOffsetHz: Double
        public var locked: Bool
        /// Symbol rate the clock loop has settled on.
        public var symbolRate: Double
        public var gain: Float
        /// Signal-to-noise ratio estimated from the spread of the symbols about their ideal points, in dB.
        public var snrDB: Double
        /// The latest coarse carrier estimate (from the signal's fourth power), in hertz, and its strength in dB
        /// (usable from about 9); nil before the first (0.11 to 0.45 s in) or with coarse acquisition off.
        public var coarseCarrierHz: Double?
        public var coarseStrengthDB: Double?
    }

    public let sampleRate: Double
    public let symbolRate: Double
    public let offset: Bool
    private let interpolation: Int
    private let taps: Int
    private var coefficients: [Float]              // interpolation × taps, phase-major
    private var memoryI: [Float]
    private var memoryQ: [Float]
    private var memoryIndex = 0

    // AGC
    private var gain: Float = 1
    private var biasI: Float = 0, biasQ: Float = 0
    // Carrier loop
    private var pllFrequency: Float = 0, pllPhase: Float = 0
    private var pllAlpha: Float = 0, pllBeta: Float = 0
    private var pllError: Float = 1000
    private var frequencyLimit: Float
    private var sweepDirection: Float = 1
    public private(set) var locked = false
    private var search: LRPTCarrierSearch?
    private var coarse: LRPTCarrierSearch.Estimate?
    private var seeded = false                      // started from a coarse estimate: no sweeping
    private static let tanhTable: [Float] = (0..<32).map { Float(tanh(Double($0 - 16))) }
    // Symbol clock
    private var clockPhase: Float = 0, clockFrequency: Float, clockCentre: Float, clockMaximumDeviation: Float
    private var clockAlpha: Float = 0, clockBeta: Float = 0
    private var previousQ: Float = 0
    private var dualState = 1
    private var inphase: Float = 0
    // SNR estimate (running means of |I|, |Q| and their squares)
    private var meanMagnitude: Double = 0, meanSquare: Double = 0

    /// The latest symbols (I, Q), oldest first, for a constellation display.
    public var recentSymbols: [(Float, Float)] {
        recentFilled < recent.count ? Array(recent[..<recentIndex]) : Array(recent[recentIndex...] + recent[..<recentIndex])
    }
    private var recent = [(Float, Float)](repeating: (0, 0), count: 512)      // a ring
    private var recentIndex = 0, recentFilled = 0

    /// - Parameters:
    ///   - offset: OQPSK (Meteor-M N2-3, N2-4) instead of QPSK.
    ///   - rrcAlpha: roll-off of the matched filter (meteor_demod: 0.6).
    ///   - maximumCarrierOffset: how far the carrier loop searches, as a fraction of the symbol rate in radians
    ///     (meteor_demod's default 0.3 rad/symbol is about ±3.4 kHz at 72 ksym/s).
    ///   - coarseAcquisition: start the carrier loop from a coarse estimate; false sweeps as meteor_demod does.
    public init(sampleRate: Double, symbolRate: Double = Double(LRPT.symbolRate), offset: Bool,
                rrcAlpha: Float = 0.6, filterOrder: Int = 32, interpolation: Int = 5, pllBandwidth: Float = 1,
                symbolBandwidth: Float = 0.00005, maximumCarrierOffset: Float = 0.3, coarseAcquisition: Bool = true) {
        self.sampleRate = sampleRate
        self.symbolRate = symbolRate
        self.offset = offset
        self.interpolation = interpolation
        taps = filterOrder * 2 + 1
        let oversampling = Float(sampleRate / symbolRate)
        var coefficients = [Float](repeating: 0, count: taps * interpolation)
        for phase in 0..<interpolation {
            for tap in 0..<taps {
                coefficients[phase * taps + tap] = Self.rrc(tap * interpolation + phase, taps * interpolation, oversampling * Float(interpolation), rrcAlpha)
            }
        }
        self.coefficients = coefficients
        memoryI = [Float](repeating: 0, count: taps)
        memoryQ = [Float](repeating: 0, count: taps)

        let multiplier: Float = offset ? 1 : 2
        let loopBandwidth = 2 * Float.pi * pllBandwidth / (multiplier * Float(symbolRate))
        frequencyLimit = offset ? min(1, maximumCarrierOffset) / 2 : min(1, maximumCarrierOffset)
        (pllAlpha, pllBeta) = Self.loopGains(damping: 0.7071067811865475, bandwidth: loopBandwidth)
        if coarseAcquisition {
            let limitHz = Double(frequencyLimit) * symbolRate * (offset ? 2 : 1) / (2 * .pi)
            search = LRPTCarrierSearch(sampleRate: sampleRate, maximumHz: limitHz)
        }

        clockFrequency = 2 * Float.pi * Float(symbolRate) / (Float(sampleRate) * Float(interpolation))
        clockCentre = clockFrequency
        clockMaximumDeviation = clockFrequency / Float(1 << 12)
        (clockAlpha, clockBeta) = Self.loopGains(damping: 1, bandwidth: symbolBandwidth / Float(interpolation))
    }

    private static func loopGains(damping: Float, bandwidth: Float) -> (Float, Float) {
        let denominator = 1 + 2 * damping * bandwidth + bandwidth * bandwidth
        return (4 * damping * bandwidth / denominator, 4 * bandwidth * bandwidth / denominator)
    }

    /// meteor_demod's root-raised-cosine taps with a Blackman-like window (after michael-joost.de/rrcfilter.pdf).
    private static func rrc(_ stage: Int, _ taps: Int, _ oversampling: Float, _ alpha: Float) -> Float {
        let norm: Float = 2.0 / 5.0
        let order = (taps - 1) / 2
        if order == stage { return norm * (1 - alpha + 4 * alpha / .pi) }
        let t = Float(abs(order - stage)) / oversampling
        var coefficient = sinf(.pi * t * (1 - alpha)) + 4 * alpha * t * cosf(.pi * t * (1 + alpha))
        let intermediate = Float.pi * t * (1 - (4 * alpha * t) * (4 * alpha * t))
        coefficient *= 0.42 - 0.5 * cosf(2 * .pi * Float(stage) / Float(taps - 1)) + 0.08 * cosf(4 * .pi * Float(stage) / Float(taps - 1))
        return coefficient / intermediate * norm
    }

    /// meteor_demod's fixed-point sine (a parabolic approximation in Q14).
    @inline(__always)
    static func fastSin(_ x: Float) -> Float {
        let qN = 14
        let a: Int32 = 1 << 14, b = Int32((2 - 3.14159 / 4) * Float(1 << 14)), c = b - (1 << 14)
        var fixed = Int16(truncatingIfNeeded: Int32(x * 65_536 / (2 * .pi)))
        let sign = fixed
        fixed &= 0x7fff                               // clear bit qN + 1 (the sign)
        fixed &-= Int16(1 << qN)
        let x2 = (Int32(fixed) * Int32(fixed)) >> (2 * qN - 14)
        var y = b - Int32(truncatingIfNeeded: (Int64(x2) * Int64(c)) >> 14)
        y = a - Int32(truncatingIfNeeded: (Int64(x2) * Int64(y)) >> 14)
        return Float(sign < 0 ? -y : y) / Float(1 << 14)
    }

    @inline(__always)
    static func fastCos(_ x: Float) -> Float { fastSin(x + .pi / 2) }

    // MARK: Loop pieces

    @inline(__always)
    private func filterOutput(_ phase: Int) -> (Float, Float) {
        var i: Float = 0, q: Float = 0
        var j = (interpolation - phase - 1) * taps
        for index in memoryIndex..<taps {
            i += memoryI[index] * coefficients[j]; q += memoryQ[index] * coefficients[j]; j += 1
        }
        for index in 0..<memoryIndex {
            i += memoryI[index] * coefficients[j]; q += memoryQ[index] * coefficients[j]; j += 1
        }
        return (i, q)
    }

    @inline(__always)
    private func agc(_ i: Float, _ q: Float) -> (Float, Float) {
        biasI = biasI * (1 - 0.001) + 0.001 * i
        biasQ = biasQ * (1 - 0.001) + 0.001 * q
        let si = (i - biasI) * gain, sq = (q - biasQ) * gain
        gain += 0.0001 * (190 - (si * si + sq * sq).squareRoot())
        gain = max(0, gain)
        return (si, sq)
    }

    @inline(__always)
    private func mix(_ i: Float, _ q: Float) -> (Float, Float) {
        let sine = Self.fastSin(-pllPhase), cosine = Self.fastCos(-pllPhase)
        let result = (i * cosine - q * sine, i * sine + q * cosine)
        pllPhase += pllFrequency
        if pllPhase >= 2 * .pi { pllPhase -= 2 * .pi }
        return result
    }

    @inline(__always)
    private static func tanhLUT(_ value: Float) -> Float {
        if value > 15 { return 1 }
        if value < -16 { return -1 }
        return tanhTable[Int(value) + 16]
    }

    private func updateCarrier(_ i: Float, _ q: Float) {
        let error = Self.tanhLUT(i) * q - Self.tanhLUT(q) * i
        pllPhase = Float(fmod(Double(pllPhase + pllAlpha * error), 2 * .pi))
        pllFrequency += pllBeta * error
        pllError = pllError * (1 - 0.001) + abs(error) * 0.001
        if pllError < 85 && !locked { locked = true } else if pllError > 105 && locked { locked = false }
        if !locked && !seeded { pllFrequency += 0.000001 * sweepDirection }
        sweepDirection = pllFrequency >= frequencyLimit ? -1 : pllFrequency <= -frequencyLimit ? 1 : sweepDirection
        pllFrequency = max(-frequencyLimit, min(frequencyLimit, pllFrequency))
    }

    private func retime(_ q: Float) {
        func sign(_ x: Float) -> Float { x > 0 ? 1 : x < 0 ? -1 : 0 }
        let error = sign(previousQ) * q - sign(q) * previousQ
        previousQ = q
        var delta = clockFrequency - clockCentre
        clockPhase -= 2 * .pi + clockAlpha * error
        delta -= clockBeta * error
        delta = max(-clockMaximumDeviation, min(clockMaximumDeviation, delta))
        clockFrequency = clockCentre + delta
    }

    private func record(_ i: Float, _ q: Float) {
        let magnitude = Double(abs(i) + abs(q)) / 2
        meanMagnitude = meanMagnitude * 0.999 + magnitude * 0.001
        meanSquare = meanSquare * 0.999 + Double(i * i + q * q) / 2 * 0.001
        recent[recentIndex] = (i, q)
        recentIndex = (recentIndex + 1) % recent.count
        recentFilled = min(recentFilled + 1, recent.count)
    }

    // MARK: Samples in, symbols out

    /// Demodulates interleaved u8 I/Q (an even count). Returns soft symbols, I then Q, as meteor_demod writes them.
    public func process(_ iq: [UInt8]) -> [Int8] {
        var soft: [Int8] = []
        soft.reserveCapacity(Int(Double(iq.count / 2) / sampleRate * symbolRate * 2) + 16)
        var index = 0
        while index + 1 < iq.count {
            push(Float(Int(iq[index]) - 128), Float(Int(iq[index + 1]) - 128), into: &soft)
            index += 2
        }
        return soft
    }

    /// Demodulates complex float samples (I, Q interleaved).
    public func process(floats: [Float]) -> [Int8] {
        var soft: [Int8] = []
        var index = 0
        while index + 1 < floats.count {
            push(floats[index], floats[index + 1], into: &soft)
            index += 2
        }
        return soft
    }

    /// Loop frequency in radians per mixing step (two steps a symbol for OQPSK) for a carrier offset in hertz.
    private func loopFrequency(hz: Double) -> Float {
        Float(2 * .pi * hz / (symbolRate * (offset ? 2 : 1)))
    }

    private var carrierHz: Double { Double(pllFrequency) * symbolRate * (offset ? 2 : 1) / (2 * .pi) }

    /// Acts on a coarse estimate: a clear line that is not a tone starts the loop there while it is searching, and
    /// moves it when it claims a lock well away from the line (the lock detector can be fooled by noise, before the
    /// satellite rises for instance, and would then never look again).
    private func steer(_ estimate: LRPTCarrierSearch.Estimate) {
        coarse = estimate
        guard estimate.strengthDB >= 9 && !estimate.isTone else { seeded = false; return }
        if locked {
            guard estimate.strengthDB >= 12 && abs(estimate.hz - carrierHz) > 150 else { return }
            locked = false
            pllError = 1000
        }
        pllFrequency = max(-frequencyLimit, min(frequencyLimit, loopFrequency(hz: estimate.hz)))
        seeded = true
    }

    private func push(_ i: Float, _ q: Float, into soft: inout [Int8]) {
        if search != nil, let estimate = search!.push(i, q) { steer(estimate) }
        memoryI[memoryIndex] = i
        memoryQ[memoryIndex] = q
        memoryIndex = (memoryIndex + 1) % taps
        for phase in 0..<interpolation {
            clockPhase += clockFrequency
            if offset {
                if clockPhase >= Float(dualState) * .pi {
                    let state = dualState
                    dualState = dualState % 2 + 1
                    let (filteredI, filteredQ) = filterOutput(phase)
                    let (fi, fq) = agc(filteredI, filteredQ)
                    if state == 1 {
                        inphase = mixI(fi, fq)
                    } else {
                        let quad = mixQ(fi, fq)
                        retime(quad)
                        updateCarrier(inphase, quad)
                        emit(inphase, quad, into: &soft)
                    }
                }
            } else if clockPhase >= 2 * .pi {
                let (fi, fq) = filterOutput(phase)
                let (ai, aq) = agc(fi, fq)
                let (mi, mq) = mix(ai, aq)
                retime(mq)
                updateCarrier(mi, mq)
                emit(mi, mq, into: &soft)
            }
        }
    }

    @inline(__always)
    private func mixI(_ i: Float, _ q: Float) -> Float {
        let sine = Self.fastSin(-pllPhase), cosine = Self.fastCos(-pllPhase)
        pllPhase += pllFrequency
        if pllPhase >= 2 * .pi { pllPhase -= 2 * .pi }
        return i * cosine - q * sine
    }

    @inline(__always)
    private func mixQ(_ i: Float, _ q: Float) -> Float {
        let sine = Self.fastSin(-pllPhase), cosine = Self.fastCos(-pllPhase)
        pllPhase += pllFrequency
        if pllPhase >= 2 * .pi { pllPhase -= 2 * .pi }
        return i * sine + q * cosine
    }

    private func emit(_ i: Float, _ q: Float, into soft: inout [Int8]) {
        soft.append(Int8(max(-127, min(127, i / 2))))
        soft.append(Int8(max(-127, min(127, q / 2))))
        record(i, q)
    }

    public var status: Status {
        let rate = Double(clockFrequency) * sampleRate * Double(interpolation) / (2 * .pi)
        // For QPSK points at (±A, ±A) plus noise: mean |x| ≈ A, mean x² = A² + σ².
        let signal = meanMagnitude * meanMagnitude
        let noise = max(1e-9, meanSquare - signal)
        return Status(carrierOffsetHz: carrierHz, locked: locked, symbolRate: rate, gain: gain,
                      snrDB: 10 * log10(max(1e-9, signal / noise)), coarseCarrierHz: coarse?.hz, coarseStrengthDB: coarse?.strengthDB)
    }
}
