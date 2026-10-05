// SPDX-License-Identifier: GPL-2.0-or-later
//
// Pulse slicers (pulses → bits), ported from rtl_433's pulse_slicer.c (Tommy Vestermark; GPL-2.0-or-later, release
// 25.02): PCM (NRZ/RZ), PPM, PWM and the Manchester slicer with a hard-coded leading zero. Widths are converted to
// samples with the same single-precision arithmetic, so both slice alike. See PROVENANCE.md.

enum PulseSlicer {
    /// A protocol's timings in samples at the package's sample rate; nil when the rate is too low for them.
    private struct Samples {
        let short, long, reset, gap, sync, tolerance: Int

        init?(_ timing: ISMTiming, sampleRate: Int) {
            let perMicrosecond = Float(sampleRate) / 1.0e6
            func samples(_ width: Float) -> Int? {
                let value = Int(width * perMicrosecond)
                return width > 0 && value <= 0 ? nil : value         // rounded to zero: the rate is too low
            }
            guard let short = samples(timing.short), let long = samples(timing.long), let reset = samples(timing.reset),
                  let gap = samples(timing.gap), let sync = samples(timing.sync), let tolerance = samples(timing.tolerance)
            else { return nil }
            (self.short, self.long, self.reset, self.gap, self.sync, self.tolerance) = (short, long, reset, gap, sync, tolerance)
        }
    }

    /// Sees each bit buffer before its decoder does, with the decoder's result.
    typealias Observer = (_ bits: BitBuffer, _ result: Int) -> Void

    /// Runs `device` on the package with the slicer its modulation needs. Returns the number of messages decoded.
    static func run(_ device: some ISMDevice, on pulses: PulseTrain, into reports: inout [ISMReport], observer: Observer? = nil) -> Int {
        let decoder = Decoder(device: device, observer: observer)
        switch device.modulation {
        case .ookPCM, .fskPCM: return pcm(pulses, decoder, &reports)
        case .ookPPM: return ppm(pulses, decoder, &reports)
        case .ookPWM, .fskPWM: return pwm(pulses, decoder, &reports)
        case .ookManchesterZeroBit, .fskManchesterZeroBit: return manchesterZeroBit(pulses, decoder, &reports)
        }
    }

    /// A device and, for debugging, whoever wants to see its bits.
    struct Decoder<Device: ISMDevice> {
        let device: Device
        let observer: Observer?
        var timing: ISMTiming { device.timing }
    }

    private static func account(_ decoder: Decoder<some ISMDevice>, _ bits: inout BitBuffer, _ reports: inout [ISMReport]) -> Int {
        let before = decoder.observer != nil ? bits : nil
        let result = decoder.device.decode(&bits, into: &reports)
        if let before { decoder.observer?(before, result) }
        return result > 0 ? result : 0
    }

    // MARK: PCM

    static func pcm(_ pulses: PulseTrain, _ device: Decoder<some ISMDevice>, _ reports: inout [ISMReport]) -> Int {
        guard let s = Samples(device.timing, sampleRate: pulses.sampleRate) else { return 0 }
        let perMicrosecond = Float(pulses.sampleRate) / 1.0e6
        var fShort: Float = device.timing.short > 0 ? 1 / (device.timing.short * perMicrosecond) : 0
        var fLong: Float = device.timing.long > 0 ? 1 / (device.timing.long * perMicrosecond) : 0

        var events = 0
        var bits = BitBuffer()
        let gapLimit = s.gap != 0 ? s.gap : s.reset
        let maximumZeros = gapLimit / s.long
        let tolerance = s.tolerance > 0 ? s.tolerance : s.long / 4
        let isRZ = s.short != s.long
        let count = pulses.count
        func within(_ value: Int, _ nominal: Int) -> Bool { value >= nominal - tolerance && value <= nominal + tolerance }

        // A run of bit-wide pulses (a preamble) tunes the bit period.
        var minimumCount = isRZ ? 4 : 12
        var preambleLength = 0
        if isRZ {
            var n = 0
            while n < count {
                var shortWidth = 0, longWidth = 0, run = 0
                while n < count && within(pulses.pulse[n], s.short) && within(pulses.pulse[n] + pulses.gap[n], s.long) {
                    shortWidth += pulses.pulse[n]
                    longWidth += pulses.pulse[n] + pulses.gap[n]
                    run += 1
                    n += 1
                }
                if run >= minimumCount {
                    fLong = Float(run) / Float(longWidth)
                    fShort = Float(run) / Float(shortWidth)
                    minimumCount = run
                    preambleLength = run
                }
                n += 1
            }
            if preambleLength == 0 {
                var shortWidth = 0, longWidth = 0, measured = 0
                for n in 0..<count where within(pulses.pulse[n], s.short) && within(pulses.pulse[n] + pulses.gap[n], s.long) {
                    shortWidth += pulses.pulse[n]
                    longWidth += pulses.pulse[n] + pulses.gap[n]
                    measured += 1
                }
                if measured > 8 {
                    fLong = Float(measured) / Float(longWidth)
                    fShort = Float(measured) / Float(shortWidth)
                }
            }
        } else {
            var n = 0
            while n < count {
                var width = 0, run = 0
                while n < count && Int(Double(Float(pulses.pulse[n]) * fShort) + 0.5) == 1
                        && Int(Double(Float(pulses.gap[n]) * fLong) + 0.5) == 1 {
                    width += pulses.pulse[n] + pulses.gap[n]
                    run += 2
                    n += 1
                }
                if run >= minimumCount {
                    fShort = Float(run) / Float(width)
                    fLong = fShort
                    minimumCount = run
                    preambleLength = run
                }
                n += 1
            }
            if preambleLength == 0 {
                var width = 0, measured = 0
                for n in 0..<count {
                    if within(pulses.pulse[n], s.short) { width += pulses.pulse[n]; measured += 1 }
                    if within(pulses.pulse[n], 2 * s.short) { width += pulses.pulse[n]; measured += 2 }
                    if within(pulses.gap[n], s.long) { width += pulses.gap[n]; measured += 1 }
                    if within(pulses.gap[n], 2 * s.long) { width += pulses.gap[n]; measured += 2 }
                }
                if measured > 20 {
                    fShort = Float(measured) / Float(width)
                    fLong = fShort
                }
            }
        }

        for n in 0..<count {
            let highs = Int(Float(pulses.pulse[n]) * fShort + 0.5)
            var lows = Int(Float(pulses.gap[n] + s.short - s.long) * fLong + 0.5)
            for _ in 0..<max(0, highs) { bits.addBit(1) }
            lows = min(lows, maximumZeros)
            for _ in 0..<max(0, lows) { bits.addBit(0) }

            if isRZ && abs(pulses.pulse[n] - s.short) > tolerance {
                bits.clear()                                    // an RZ pulse out of tolerance: corrupt
            } else if pulses.gap[n] > gapLimit && pulses.gap[n] <= s.reset {
                bits.addRow()
            }
            if (n == count - 1 || pulses.gap[n] > s.reset) && (bits.bitsPerRow[0] > 0 || bits.rowCount > 1) {
                events += account(device, &bits, &reports)
                bits.clear()
            }
        }
        return events
    }

    // MARK: PPM

    static func ppm(_ pulses: PulseTrain, _ device: Decoder<some ISMDevice>, _ reports: inout [ISMReport]) -> Int {
        guard let s = Samples(device.timing, sampleRate: pulses.sampleRate) else { return 0 }
        var events = 0
        var bits = BitBuffer()

        // Bounds are exclusive.
        let zeroLow, zeroHigh, oneLow, oneHigh: Int
        var syncLow = 0, syncHigh = 0
        if s.tolerance > 0 {
            zeroLow = s.short - s.tolerance; zeroHigh = s.short + s.tolerance
            oneLow = s.long - s.tolerance; oneHigh = s.long + s.tolerance
            if s.sync > 0 { syncLow = s.sync - s.tolerance; syncHigh = s.sync + s.tolerance }
        } else {
            zeroLow = 0
            zeroHigh = (s.short + s.long) / 2 + 1
            oneLow = zeroHigh - 1
            oneHigh = s.gap != 0 ? s.gap : s.reset
        }

        for n in 0..<pulses.count {
            let gap = pulses.gap[n]
            if gap > zeroLow && gap < zeroHigh {
                bits.addBit(0)
            } else if gap > oneLow && gap < oneHigh {
                bits.addBit(1)
            } else if gap > syncLow && gap < syncHigh {
                bits.addSync()
            } else if gap < s.reset {
                bits.addRow()
            }
            if (n == pulses.count - 1 || gap >= s.reset) && (bits.bitsPerRow[0] > 0 || bits.rowCount > 1) {
                events += account(device, &bits, &reports)
                bits.clear()
            }
        }
        return events
    }

    // MARK: PWM

    static func pwm(_ pulses: PulseTrain, _ device: Decoder<some ISMDevice>, _ reports: inout [ISMReport]) -> Int {
        guard let s = Samples(device.timing, sampleRate: pulses.sampleRate) else { return 0 }
        var events = 0
        var bits = BitBuffer()

        // Bounds are exclusive.
        var oneLow = 0, oneHigh = 0, zeroLow = 0, zeroHigh = 0, syncLow = 0, syncHigh = 0
        if s.tolerance > 0 {
            oneLow = s.short - s.tolerance; oneHigh = s.short + s.tolerance
            zeroLow = s.long - s.tolerance; zeroHigh = s.long + s.tolerance
            if s.sync > 0 { syncLow = s.sync - s.tolerance; syncHigh = s.sync + s.tolerance }
        } else if s.sync <= 0 {
            oneHigh = (s.short + s.long) / 2 + 1
            zeroLow = oneHigh - 1; zeroHigh = Int(Int32.max)
        } else if s.sync < s.short {
            syncHigh = (s.sync + s.short) / 2 + 1
            oneLow = syncHigh - 1; oneHigh = (s.short + s.long) / 2 + 1
            zeroLow = oneHigh - 1; zeroHigh = Int(Int32.max)
        } else if s.sync < s.long {
            oneHigh = (s.short + s.sync) / 2 + 1
            syncLow = oneHigh - 1; syncHigh = (s.sync + s.long) / 2 + 1
            zeroLow = syncHigh - 1; zeroHigh = Int(Int32.max)
        } else {
            oneHigh = (s.short + s.long) / 2 + 1
            zeroLow = oneHigh - 1; zeroHigh = (s.long + s.sync) / 2 + 1
            syncLow = zeroHigh - 1; syncHigh = Int(Int32.max)
        }

        for n in 0..<pulses.count {
            let pulse = pulses.pulse[n]
            if pulse > oneLow && pulse < oneHigh {
                bits.addBit(1)
            } else if pulse > zeroLow && pulse < zeroHigh {
                bits.addBit(0)
            } else if pulse > syncLow && pulse < syncHigh {
                bits.addSync()
            } else if pulse <= oneLow {
                // a spurious short pulse: ignored
            } else {
                bits.addRow()
            }

            if (n == pulses.count - 1 || pulses.gap[n] > s.reset) && bits.rowCount > 0 {
                events += account(device, &bits, &reports)
                bits.clear()
            } else if s.gap > 0 && pulses.gap[n] > s.gap && bits.rowCount > 0 && bits.bitsPerRow[bits.rowCount - 1] > 0 {
                bits.addRow()
            }
        }
        return events
    }

    // MARK: Manchester with a hard-coded zero

    static func manchesterZeroBit(_ pulses: PulseTrain, _ device: Decoder<some ISMDevice>, _ reports: inout [ISMReport]) -> Int {
        guard let s = Samples(device.timing, sampleRate: pulses.sampleRate) else { return 0 }
        var events = 0
        var sinceLast = 0
        var bits = BitBuffer()
        let halfAgain = Double(s.short) * 1.5

        bits.addBit(0)                                      // the first rising edge counts as a zero
        for n in 0..<pulses.count {
            let pulse = pulses.pulse[n], gap = pulses.gap[n]
            if s.tolerance > 0 && (pulse < s.short - s.tolerance || pulse > s.short * 2 + s.tolerance
                                   || gap < s.short - s.tolerance || gap > s.short * 2 + s.tolerance) {
                // Out of range: end the row. A long last pulse with this gap is a [1]10 transition.
                if Double(pulse) > halfAgain && pulse <= s.short * 2 + s.tolerance { bits.addBit(1) }
                bits.addRow()
                bits.addBit(0)
                sinceLast = 0
            } else if Double(pulse + sinceLast) > halfAgain {
                bits.addBit(1)                              // a falling edge on a bit boundary: 1
                sinceLast = 0
            } else {
                sinceLast += pulse
            }

            if (n == pulses.count - 1 || gap > s.reset) && bits.rowCount > 0 {
                events += account(device, &bits, &reports)
                bits.clear()
                bits.addBit(0)
                sinceLast = 0
            } else if Double(gap + sinceLast) > halfAgain {
                bits.addBit(0)                              // a rising edge on a bit boundary: 0
                sinceLast = 0
            } else {
                sinceLast += gap
            }
        }
        return events
    }
}
