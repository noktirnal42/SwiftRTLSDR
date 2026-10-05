// SPDX-License-Identifier: GPL-2.0-or-later
//
// OOK and FSK pulse detection, ported from rtl_433's pulse_detect.c, pulse_detect_fsk.c and pulse_data.c
// (Tommy Vestermark, Benjamin Larsson, Christian W. Zuckschwerdt; GPL-2.0-or-later, release 25.02).
// The state machines, estimators and limits are rtl_433's, so both find the same packages. See PROVENANCE.md.

/// A package of pulses: alternating "on" (carrier, or the higher FSK frequency) and "off" widths in samples.
public struct PulseTrain: Sendable {
    public static let maximumPulses = 1_200         // PD_MAX_PULSES: a longer package is cut here
    static let minimumPulses = 16                   // PD_MIN_PULSES: fewer FSK pulses than this is not a package
    static let minimumPulseSamples = 10             // PD_MIN_PULSE_SAMPLES
    static let minimumGapMilliseconds = 10          // PD_MIN_GAP_MS
    static let maximumGapMilliseconds = 100         // PD_MAX_GAP_MS
    static let maximumGapRatio = 10                 // PD_MAX_GAP_RATIO

    /// Number of pulse/gap pairs.
    public internal(set) var count = 0
    /// Pulse ("on") widths in samples; entries beyond `count` are scratch.
    public internal(set) var pulse = [Int](repeating: 0, count: maximumPulses)
    /// Gap ("off") widths in samples following each pulse.
    public internal(set) var gap = [Int](repeating: 0, count: maximumPulses)
    public internal(set) var sampleRate = 0
    /// Stream position (samples) of the first pulse.
    public internal(set) var offset = 0
    var fskF1Estimate = 0
    var fskF2Estimate = 0
    var ookLowEstimate = 0
    var ookHighEstimate = 0

    mutating func clear() {
        count = 0
        for index in pulse.indices { pulse[index] = 0; gap[index] = 0 }
        sampleRate = 0
        offset = 0
        fskF1Estimate = 0; fskF2Estimate = 0; ookLowEstimate = 0; ookHighEstimate = 0
    }

    /// Drops the older half to make room (rtl_433 does this for FSK packages that run past the limit).
    mutating func shift() {
        let half = Self.maximumPulses / 2
        for index in 0..<(Self.maximumPulses - half) {
            pulse[index] = pulse[index + half]
            gap[index] = gap[index + half]
        }
        count -= half
        offset += half
    }

    /// The pulses as (on, off) pairs.
    public var pairs: [(pulse: Int, gap: Int)] { (0..<count).map { (pulse[$0], gap[$0]) } }
}

/// Which FSK pulse detector to use; rtl_433 picks min/max above 800 MHz and classic below.
public enum FSKPulseDetector: Sendable {
    case classic
    case minMax

    public static func automatic(forFrequency hertz: Int) -> FSKPulseDetector { hertz > 800_000_000 ? .minMax : .classic }

    /// The discriminator low-pass cutoff that goes with it.
    var fmLowPass: Float { self == .classic ? 0.1 : 0.2 }
}

/// Finds packages in the envelope (OOK) and, during a package's first long pulse, in the frequency (FSK).
struct PulseDetector {
    enum Package { case ook, fsk }

    private enum OOKState { case idle, pulse, gapStart, gap }
    private enum FSKState { case initial, high, low, error }

    // Levels for amplitude (not magnitude) envelopes, full scale 16384, as rtl_433 sets them by default.
    static let minimumHighLevel = 1_000             // DB_TO_AMP(-12.1442)
    static let highLowRatio = 8                     // DB_TO_AMP_F(9)
    static let maximumHighLevel = 16_383            // DB_TO_AMP(0)
    static let highEstimateRatio = 64               // OOK_EST_HIGH_RATIO
    static let lowEstimateRatio = 1_024             // OOK_EST_LOW_RATIO

    let fskMode: FSKPulseDetector
    private var state = OOKState.idle
    private var pulseLength = 0
    private var maxPulse = 0
    private var dataCounter = 0
    private var leadInCounter = 0
    private var lowEstimate = 0
    private var highEstimate = 0

    // FSK sub-detector state (pulse_detect_fsk_t).
    private var fskPulseLength = 0
    private var fskState = FSKState.initial
    private var f1Estimate = 0
    private var f2Estimate = 0
    private var varianceMax = Int(Int16.min)
    private var varianceMin = Int(Int16.max)
    private var skipSamples = 40

    private(set) var ook = PulseTrain()
    private(set) var fsk = PulseTrain()

    init(fskMode: FSKPulseDetector) { self.fskMode = fskMode }

    private mutating func resetFSK() {
        fskPulseLength = 0
        fskState = .initial
        f1Estimate = 0
        f2Estimate = 0
        varianceMax = Int(Int16.min)
        varianceMin = Int(Int16.max)
        skipSamples = 40
    }

    /// Runs over the block from where the last call stopped. Returns when a package is complete (read it from `ook`
    /// or `fsk`; call again to continue with the rest of the block) or with nil when the block is used up.
    /// `blockStart` is the stream position of `envelope[0]`.
    mutating func next(envelope: UnsafeBufferPointer<Int16>, fm: UnsafeBufferPointer<Int16>, sampleRate: Int, blockStart: Int) -> Package? {
        let samplesPerMillisecond = sampleRate / 1_000
        highEstimate = max(highEstimate, Self.minimumHighLevel)
        let length = envelope.count
        var endOnSpurious = false

        while dataCounter < length {
            let am = Int(envelope[dataCounter])
            let threshold = Int(Int16(truncatingIfNeeded: (lowEstimate + highEstimate) / 2))
            let hysteresis = Int(Int16(truncatingIfNeeded: threshold / 8))

            switch state {
            case .idle:
                if am > threshold + hysteresis && leadInCounter > Self.lowEstimateRatio {
                    ook.clear()
                    fsk.clear()
                    ook.sampleRate = sampleRate
                    fsk.sampleRate = sampleRate
                    ook.offset = blockStart + dataCounter
                    fsk.offset = blockStart + dataCounter
                    pulseLength = 0
                    maxPulse = 0
                    resetFSK()
                    state = .pulse
                } else {
                    // Track the noise floor; the high level defaults to a fixed ratio above it.
                    let delta = am - lowEstimate
                    lowEstimate += delta / Self.lowEstimateRatio
                    lowEstimate += delta > 0 ? 1 : -1
                    highEstimate = Self.highLowRatio * lowEstimate
                    highEstimate = max(highEstimate, Self.minimumHighLevel)
                    highEstimate = min(highEstimate, Self.maximumHighLevel)
                    if leadInCounter <= Self.lowEstimateRatio { leadInCounter += 1 }
                }

            case .pulse:
                pulseLength += 1
                if am < threshold - hysteresis {
                    if pulseLength < PulseTrain.minimumPulseSamples {
                        if ook.count <= 1 {
                            state = .idle
                        } else {
                            endOnSpurious = true
                            state = .gap
                        }
                    } else {
                        ook.pulse[ook.count] = pulseLength
                        maxPulse = max(pulseLength, maxPulse)
                        pulseLength = 0
                        state = .gapStart
                    }
                } else {
                    highEstimate += am / Self.highEstimateRatio - highEstimate / Self.highEstimateRatio
                    highEstimate = max(highEstimate, Self.minimumHighLevel)
                    highEstimate = min(highEstimate, Self.maximumHighLevel)
                    ook.fskF1Estimate += Int(fm[dataCounter]) / Self.highEstimateRatio - ook.fskF1Estimate / Self.highEstimateRatio
                }
                if ook.count == 0 { detectFSK(Int(fm[dataCounter])) }

            case .gapStart:
                pulseLength += 1
                if am > threshold + hysteresis {
                    // A spurious short gap: the pulse goes on.
                    pulseLength += ook.pulse[ook.count]
                    state = .pulse
                } else if pulseLength >= PulseTrain.minimumPulseSamples {
                    state = .gap
                    if fsk.count > PulseTrain.minimumPulses {
                        if fskMode == .classic { wrapUpFSK() }
                        fsk.fskF1Estimate = f1Estimate
                        fsk.fskF2Estimate = f2Estimate
                        fsk.ookLowEstimate = lowEstimate
                        fsk.ookHighEstimate = highEstimate
                        state = .idle
                        return .fsk                     // this sample is looked at again on the next call
                    }
                }
                if ook.count == 0 { detectFSK(Int(fm[dataCounter])) }

            case .gap:
                pulseLength += 1
                if am > threshold + hysteresis {
                    ook.gap[ook.count] = pulseLength
                    ook.count += 1
                    if ook.count >= PulseTrain.maximumPulses {
                        state = .idle
                        ook.ookLowEstimate = lowEstimate
                        ook.ookHighEstimate = highEstimate
                        return .ook
                    }
                    pulseLength = 0
                    state = .pulse
                }
                if endOnSpurious
                    || (pulseLength > PulseTrain.maximumGapRatio * maxPulse && pulseLength > PulseTrain.minimumGapMilliseconds * samplesPerMillisecond)
                    || pulseLength > PulseTrain.maximumGapMilliseconds * samplesPerMillisecond {
                    ook.gap[ook.count] = pulseLength
                    ook.count += 1
                    state = .idle
                    ook.ookLowEstimate = lowEstimate
                    ook.ookHighEstimate = highEstimate
                    return .ook
                }
            }
            dataCounter += 1
        }
        dataCounter = 0
        return nil
    }

    private mutating func detectFSK(_ sample: Int) {
        switch fskMode {
        case .classic: detectFSKClassic(sample)
        case .minMax: detectFSKMinMax(sample)
        }
    }

    // MARK: FSK, classic: track two frequency estimates and switch when the signal is nearer the other one.

    private static let defaultFMDelta = 6_000
    private static let slowEstimator = 64
    private static let fastEstimator = 16

    private mutating func detectFSKClassic(_ fmN: Int) {
        let f1Delta = abs(fmN - f1Estimate)
        let f2Delta = abs(fmN - f2Estimate)
        fskPulseLength += 1

        switch fskState {
        case .initial:
            if fskPulseLength < PulseTrain.minimumPulseSamples {
                f1Estimate = f1Estimate / 2 + fmN / 2
            } else if f1Delta > Self.defaultFMDelta / 2 {
                if fmN > f1Estimate {
                    // The first frequency was the low one: it was a gap.
                    fskState = .high
                    f2Estimate = f1Estimate
                    f1Estimate = fmN
                    fsk.pulse[0] = 0
                    fsk.gap[0] = fskPulseLength
                    fsk.count += 1
                    fskPulseLength = 0
                } else {
                    fskState = .low
                    f2Estimate = fmN
                    fsk.pulse[0] = fskPulseLength
                    fskPulseLength = 0
                }
            } else {
                f1Estimate += fmN / Self.fastEstimator - f1Estimate / Self.fastEstimator
            }

        case .high:
            if f1Delta > f2Delta {
                fskState = .low
                if fskPulseLength >= PulseTrain.minimumPulseSamples {
                    fsk.pulse[fsk.count] = fskPulseLength
                    fskPulseLength = 0
                } else if fsk.count > 0 {
                    // Too short: undo the last gap and carry on as if this pulse never was.
                    fskPulseLength += fsk.gap[fsk.count - 1]
                    fsk.count -= 1
                    if fsk.count == 0 && fsk.pulse[0] == 0 {
                        f1Estimate = f2Estimate
                        fskState = .initial
                    }
                }
            } else if fmN > f1Estimate {
                f1Estimate += fmN / Self.fastEstimator - f1Estimate / Self.fastEstimator
            } else {
                f1Estimate += fmN / Self.slowEstimator - f1Estimate / Self.slowEstimator
            }

        case .low:
            if f2Delta > f1Delta {
                fskState = .high
                if fskPulseLength >= PulseTrain.minimumPulseSamples {
                    fsk.gap[fsk.count] = fskPulseLength
                    fsk.count += 1
                    fskPulseLength = 0
                    if fsk.count >= PulseTrain.maximumPulses { fsk.shift() }
                } else {
                    fskPulseLength += fsk.pulse[fsk.count]
                    if fsk.count == 0 { fskState = .initial }
                }
            } else if fmN < f2Estimate {
                f2Estimate += fmN / Self.fastEstimator - f2Estimate / Self.fastEstimator
            } else {
                f2Estimate += fmN / Self.slowEstimator - f2Estimate / Self.slowEstimator
            }

        case .error:
            break
        }
    }

    /// Stores the last pulse or gap at the end of a classic FSK package.
    private mutating func wrapUpFSK() {
        guard fsk.count < PulseTrain.maximumPulses else { return }
        fskPulseLength += 1
        if fskState == .high {
            fsk.pulse[fsk.count] = fskPulseLength
            fsk.gap[fsk.count] = 0
        } else {
            fsk.gap[fsk.count] = fskPulseLength
        }
        fsk.count += 1
    }

    // MARK: FSK, min/max: slice at the middle of slowly decaying minimum and maximum trackers.

    private mutating func detectFSKMinMax(_ fmN: Int) {
        if skipSamples == 0 {
            varianceMax = max(fmN, varianceMax)
            varianceMin = min(fmN, varianceMin)
            let middle = Int(Int16(truncatingIfNeeded: (varianceMax + varianceMin) / 2))
            if fmN > middle { varianceMax = Int(Int16(truncatingIfNeeded: varianceMax - 10)) }
            if fmN < middle { varianceMin = Int(Int16(truncatingIfNeeded: varianceMin + 10)) }

            fskPulseLength += 1
            switch fskState {
            case .initial:
                fskState = fmN > middle ? .high : .low
            case .high:
                if fmN < middle {
                    fskState = .low
                    fsk.pulse[fsk.count] = fskPulseLength
                    fskPulseLength = 0
                }
                f2Estimate += fmN / Self.slowEstimator - f2Estimate / Self.slowEstimator
            case .low:
                if fmN > middle {
                    fskState = .high
                    fsk.gap[fsk.count] = fskPulseLength
                    fsk.count += 1
                    fskPulseLength = 0
                    if fsk.count >= PulseTrain.maximumPulses { fsk.shift() }
                }
                f1Estimate += fmN / Self.slowEstimator - f1Estimate / Self.slowEstimator
            case .error:
                break
            }
        }
        if skipSamples > 0 { skipSamples -= 1 }
    }
}
