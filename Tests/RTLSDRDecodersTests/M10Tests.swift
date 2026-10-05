// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

/// Frames from Tools/m10-oracle.py (written from the format, independently of this package) that m10m20mod accepts with a
/// good checksum: the first frame of a flight at 47.5 °N, 8.25 °W, 1204.37 m, 12.0 °C, 3.00 V, 6.5 m/s east, 2.25 south,
/// 5.1 up, GPS time 2025-06-15 10:20:18 (UTC 10:20:00).
enum M10Vectors {
    static let m10 = "649f20000514fe3e03fc0237e7ca21c71c72fa2222220012609200000000091209430000000000000000000000000000000000000000000000000000000000d2a600000000c501000000000000000000000000000000000000000000002300b7395a288ad1"
    static let m10Plus = "64af000002d4cae0ff821d7001d675028aff1f01fe018e70024c61000000000000000000000000000000000000000000000000000000000000000000000000d2a600000000c501000000000000000000000000000000000000000000002300b7395a286dc1"
    static let m20 = "4520d007d206600901d675028aff1f0091625a118428000001fe094302d4cae0ff821d700000e800000000000000000000000000000000000000000000000000000000076b4f"
}

/// The report for a frame's bytes: the frame must parse and the report must exist.
func m10Report(_ bytes: [UInt8]) throws -> M10Report {
    let frame = try #require(M10Frame(bytes: bytes))
    return try #require(M10Decoder().report(frame))
}

/// Builds M10 frames (standard length, with a checksum) from field values.
struct M10FrameBuilder {
    var week = 2371
    var towMilliseconds = 37_218_250
    var latitude = 47.5, longitude = -8.25, altitude = 1204.37
    var east = 6.5, north = -2.25, up = 5.1
    var utcOffset = 18
    var satellites = 9
    var counter = 40
    var serial: [UInt8] = [0x23, 0x00, 0xb7, 0x39, 0x5a]
    var temperatureRange = 0
    var temperatureReading = 2000
    var batteryReading = 453
    /// Extra bytes before the checksum (the length byte grows with them).
    var extra = 0

    func bytes() -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: M10.m10Length + extra + 1)
        func put(_ value: Int, _ at: Int, _ count: Int, little: Bool = false) {
            for k in 0..<count {
                let shift = little ? 8 * k : 8 * (count - 1 - k)
                frame[at + k] = UInt8(truncatingIfNeeded: value >> shift)
            }
        }
        frame[0] = UInt8(M10.m10Length + extra)
        frame[1] = 0x9f
        frame[2] = 0x20
        put(Int((east * 200).rounded()), 0x04, 2)
        put(Int((north * 200).rounded()), 0x06, 2)
        put(Int((up * 200).rounded()), 0x08, 2)
        put(towMilliseconds, 0x0a, 4)
        let scale = Double(1 << 32) / 360
        put(Int((latitude * scale).rounded()), 0x0e, 4)
        put(Int((longitude * scale).rounded()), 0x12, 4)
        put(Int((altitude * 1000).rounded()), 0x16, 4)
        frame[0x1e] = UInt8(satellites)
        frame[0x1f] = UInt8(utcOffset)
        put(week, 0x20, 2)
        frame[0x3e] = UInt8(temperatureRange)
        put(temperatureReading + 0xa000, 0x3f, 2, little: true)
        put(batteryReading, 0x45, 2, little: true)
        for (k, byte) in serial.enumerated() { frame[0x5d + k] = byte }
        frame[0x62] = UInt8(counter)
        let length = M10.m10Length + extra
        for k in 0x63..<length { frame[k] = 0 }
        let check = M10.checksum(frame[0..<(length - 1)])
        frame[length - 1] = UInt8(check >> 8)
        frame[length] = UInt8(check & 0xff)
        return frame
    }
}

/// Renders M10 frames as they sound: a header and then differentially and Manchester coded bits at `baud` symbols a
/// second, Gaussian-filtered (BT 1.5), ±4.32 kHz around an unmodulated carrier kept up between frames, with noise.
struct M10Modulator {
    var sampleRate = 96_000.0
    var carrierHz = 3_000.0
    var deviation = 4_320.0
    var baud = 9_600.0
    var inverted = false
    var noise = 6.0
    var generator = Seeded(state: 21)

    mutating func frequency(_ frames: [[UInt8]], leadSeconds: Double = 0.3) -> [Double] {
        var symbols = [Double](repeating: 0, count: Int(leadSeconds * baud))
        for frame in frames {
            var one = M10.headerSymbols
            var previous = 0
            for byte in frame {
                for k in 0..<8 {
                    let bit = previous ^ Int(byte >> UInt8(7 - k) & 1) ^ 1
                    one += bit == 1 ? [-1, 1] : [1, -1]
                    previous = bit
                }
            }
            one += [Double](repeating: 0, count: Int(baud.rounded()) - one.count)
            symbols += one
        }
        if inverted { symbols = symbols.map { -$0 } }
        let sps = sampleRate / baud
        let count = Int(Double(symbols.count) * sps)
        let nrz = (0..<count).map { symbols[min(symbols.count - 1, Int(Double($0) / sps))] }
        let sigma = log(2).squareRoot() / (2 * .pi * 1.5) * sps
        let half = max(1, Int(4 * sigma))
        var kernel = (-half...half).map { exp(-0.5 * Double($0 * $0) / (sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var out = [Double](repeating: 0, count: count)
        for n in 0..<count {
            var acc = 0.0
            for (index, weight) in kernel.enumerated() {
                let m = n + index - half
                if m >= 0 && m < count { acc += weight * nrz[m] }
            }
            out[n] = deviation * acc
        }
        return out
    }

    mutating func iq(_ frames: [[UInt8]]) -> [UInt8] {
        let shift = frequency(frames)
        var phase = Double.random(in: 0..<(2 * .pi), using: &generator)
        var out = [UInt8](repeating: 0, count: 2 * shift.count)
        for (n, f) in shift.enumerated() {
            phase += 2 * .pi * (carrierHz + f) / sampleRate
            out[2 * n] = UInt8(max(0, min(255, (127.5 + 50 * cos(phase) + noise * generator.gaussian()).rounded())))
            out[2 * n + 1] = UInt8(max(0, min(255, (127.5 + 50 * sin(phase) + noise * generator.gaussian()).rounded())))
        }
        return out
    }
}

struct M10FrameTests {
    @Test func checksumMatchesTheVectorsThatM10m20modAccepts() throws {
        for (name, hex) in [("M10", M10Vectors.m10), ("M10+", M10Vectors.m10Plus), ("M20", M10Vectors.m20)] {
            let frame = try #require(M10Frame(bytes: bytes(hex: hex)), "\(name)")
            #expect(frame.isValid, "\(name): \(String(frame.computedChecksum, radix: 16)) against \(String(frame.storedChecksum, radix: 16))")
        }
    }

    @Test func aDamagedFrameIsNotValidAndGivesNoReport() throws {
        var damaged = bytes(hex: M10Vectors.m10)
        damaged[0x0f] ^= 0x04
        let frame = try #require(M10Frame(bytes: damaged))
        #expect(!frame.isValid && M10Decoder().report(frame) == nil)
        #expect(M10Frame(bytes: Array(bytes(hex: M10Vectors.m10).prefix(60))) == nil, "shorter than its length byte says")
    }

    @Test func theChecksumIsLinear() {
        // c(a xor b) = c(a) xor c(b) for equal lengths, from the zero state: the property that makes it a matrix.
        var generator = Seeded(state: 4)
        for _ in 0..<20 {
            let a = (0..<40).map { _ in UInt8.random(in: 0...255, using: &generator) }
            let b = (0..<40).map { _ in UInt8.random(in: 0...255, using: &generator) }
            let x = zip(a, b).map { $0 ^ $1 }
            #expect(M10.checksum(x[...]) == M10.checksum(a[...]) ^ M10.checksum(b[...]))
        }
    }
}

struct M10DecoderTests {
    private func report(_ hex: String) throws -> M10Report {
        try m10Report(bytes(hex: hex))
    }

    @Test func fieldsComeOutAsSentFromEachModel() throws {
        for (name, hex) in [("M10", M10Vectors.m10), ("M10+", M10Vectors.m10Plus), ("M20", M10Vectors.m20)] {
            let r = try report(hex)
            #expect(abs(r.latitude - 47.5) < 1e-5 && abs(r.longitude + 8.25) < 1e-5, "\(name)")
            #expect(abs(r.altitude - 1204.37) < 0.006, "\(name)")
            #expect(abs(r.horizontalSpeed - 6.87841) < 1e-4 && abs(r.heading - 109.09349) < 1e-3 && abs(r.verticalSpeed - 5.1) < 1e-9, "\(name)")
            #expect(abs(r.batteryVolts - 3.0) < 0.011, "\(name)")
            #expect(abs(try #require(r.temperature, "\(name)") - 12.0) < 0.05, "\(name)")
        }
    }

    @Test func m10TimesAreUTCAndTheOthersGPS() throws {
        let m10 = try report(M10Vectors.m10)
        #expect(m10.isoTime == "2025-06-15T10:20:00.250Z" && m10.gpsSeconds == 1_434_018_018 && m10.leapSeconds == 18)
        #expect(m10.referenceTime == "UTC" && m10.satellites == 9 && m10.counter == 40)
        let m20 = try report(M10Vectors.m20)
        #expect(m20.isoTime == "2025-06-15T10:20:18.000Z" && m20.gpsSeconds == 1_434_018_018 && m20.referenceTime == "GPS")
        let plus = try report(M10Vectors.m10Plus)
        #expect(plus.isoTime == "2025-06-15T10:20:00.000Z" && plus.referenceTime == "UTC")
    }

    @Test func utcCanBeTheDayBefore() throws {
        // GPS time 10 s into the week less 18 s of offset is the previous Saturday, 23:59:52.
        var builder = M10FrameBuilder()
        builder.towMilliseconds = 10_000
        let r = try m10Report(builder.bytes())
        #expect(r.isoTime == "2025-06-14T23:59:52.000Z", "\(r.isoTime)")
        #expect(r.gpsSeconds == 2371 * 604_800 + 10)
    }

    @Test func serialsAndIdentifiersAreFormattedLikeTheReference() throws {
        let m10 = try report(M10Vectors.m10)
        #expect(m10.serial == "B07-3-26713" && m10.rawSerial == "2300B7395A" && m10.aprsID == "MEB735A39")
        let m20 = try report(M10Vectors.m20)
        #expect(m20.serial == "707-3-10260" && m20.rawSerial == "5A1184" && m20.aprsID == nil)
    }

    @Test func jsonIsWhatM10m20modPrints() throws {
        let line = try report(M10Vectors.m10).json()
        #expect(line == "{ \"type\": \"M10\", \"frame\": 1434018018, \"id\": \"M10-B07-3-26713\", \"datetime\": \"2025-06-15T10:20:00.250Z\", \"lat\": 47.50000, \"lon\": -8.25000, \"alt\": 1204.37000, \"vel_h\": 6.87841, \"heading\": 109.09349, \"vel_v\": 5.10000, \"sats\": 9, \"aprsid\": \"MEB735A39\", \"batt\": 3.00, \"temp\": 12.0, \"rawid\": \"M10_2300B7395A\", \"subtype\": \"0x9F\", \"ref_datetime\": \"UTC\", \"ref_position\": \"GPS\", \"gpsutc_leapsec\": 18 }")
        let m20 = try report(M10Vectors.m20).json(frequencyKHz: 403_000)
        #expect(m20.hasPrefix("{ \"type\": \"M20\", \"frame\": 1434018018, \"id\": \"M20-707-3-10260\", \"datetime\": \"2025-06-15T10:20:18.000Z\""))
        #expect(m20.hasSuffix("\"rawid\": \"M20_5A1184\", \"subtype\": \"0x20\", \"freq\": 403000, \"ref_datetime\": \"GPS\", \"ref_position\": \"GPS\" }"))
    }

    /// The thermistor's resistance from a 12-bit reading of the divider in a range: the series resistor of the range (12.1 kΩ;
    /// 36.5 kΩ with 330 kΩ across the sensor; 475 kΩ with 2 MΩ) over (Vcc - Vout) / Vout less its parallel part.
    private func thermistorOhms(range: Int, reading: Int) -> Double {
        let series: [Double] = [12_100, 36_500, 475_000]
        let parallel: [Double] = [Double.infinity, 330_000, 2_000_000]
        let x: Double = (4095.0 - Double(reading)) / Double(reading)
        return series[range] / (x - series[range] / parallel[range])
    }

    /// Temperature from the datasheet table of resistance (kΩ) against temperature, interpolated between its points.
    private func temperature(ohms: Double) -> Double? {
        let table: [(Double, Double)] = [(-50, 204.0), (-45, 150.7), (-40, 112.6), (-35, 84.9), (-30, 64.65), (-25, 49.66), (-20, 38.48),
                                         (-15, 30.06), (-10, 23.67), (-5, 18.78), (0, 15.0), (5, 12.06), (10, 9.765), (15, 7.955),
                                         (20, 6.515), (25, 5.37), (30, 4.448), (35, 3.704), (40, 3.1)]
        let kilohms = ohms / 1000
        for k in 0..<(table.count - 1) where kilohms <= table[k].1 && kilohms >= table[k + 1].1 {
            let fraction = (log(kilohms) - log(table[k].1)) / (log(table[k + 1].1) - log(table[k].1))
            return table[k].0 + fraction * 5
        }
        return nil
    }

    @Test func temperatureFollowsTheDividerInEachRange() throws {
        let cases: [(Int, Int)] = [(0, 2000), (1, 2500), (2, 1500)]
        for (range, reading) in cases {
            var builder = M10FrameBuilder()
            builder.temperatureRange = range
            builder.temperatureReading = reading
            let r = try m10Report(builder.bytes())
            let ohms = thermistorOhms(range: range, reading: reading)
            if let expected = temperature(ohms: ohms) {
                let measured = try #require(r.temperature)
                #expect(abs(measured - expected) < 0.1, "range \(range): \(measured) against \(expected)")
            } else {
                // Beyond the table (a thermistor of more than 200 kΩ): the fit carries on a little way.
                #expect(r.temperature.map { $0 < -50 || $0 > 40 } ?? true, "range \(range): outside the table")
            }
        }
    }

    @Test func extraBytesMoveTheChecksumNotTheFields() throws {
        var builder = M10FrameBuilder()
        builder.extra = 0x12
        let frame = try #require(M10Frame(bytes: builder.bytes()))
        #expect(frame.length == 0x76 && frame.isValid)
        let r = try #require(M10Decoder().report(frame))
        #expect(abs(r.latitude - 47.5) < 1e-5 && r.counter == 40)
    }

    @Test func westernLongitudesAndLowAltitudesKeepTheirSigns() throws {
        var builder = M10FrameBuilder()
        builder.latitude = -33.8688
        builder.longitude = -151.2093
        builder.altitude = -12.5
        let r = try m10Report(builder.bytes())
        #expect(abs(r.latitude + 33.8688) < 1e-5 && abs(r.longitude + 151.2093) < 1e-5 && abs(r.altitude + 12.5) < 0.001)
    }
}

struct M10ReceiverTests {
    private func frames(_ count: Int) -> [[UInt8]] {
        (0..<count).map { index in
            var builder = M10FrameBuilder()
            builder.towMilliseconds = 37_218_250 + 1000 * index
            builder.counter = 40 + index
            builder.altitude = 1204.37 + 5.1 * Double(index)
            return builder.bytes()
        }
    }

    private func run(_ receiver: M10Receiver, iq: [UInt8]) -> [M10Event] {
        var events: [M10Event] = []
        var index = 0
        while index < iq.count {
            let end = min(iq.count, index + 96_000)
            events += receiver.process(iq: Array(iq[index..<end]))
            index = end
        }
        return events
    }

    /// FM audio from another receiver, of either polarity (the differential coding does not care).
    @Test func reportsComeFromAudioOfEitherPolarity() {
        for inverted in [false, true] {
            var modulator = M10Modulator(carrierHz: 0, inverted: inverted)
            var generator = Seeded(state: 8)
            let audio = modulator.frequency(frames(4)).map { Float($0 + 700 * generator.gaussian()) }
            let events = M10Receiver(audioRate: 96_000).process(audio: audio)
            #expect(events.compactMap { $0.report?.counter } == [40, 41, 42, 43], "inverted \(inverted)")
        }
    }

    @Test func reportsComeFromIQAtAnOffsetCarrier() {
        var modulator = M10Modulator(sampleRate: 192_000, carrierHz: 5_000)
        let receiver = M10Receiver(sampleRate: 192_000)
        let events = run(receiver, iq: modulator.iq(frames(5)))
        let counters = events.compactMap { $0.report?.counter }
        #expect(counters.suffix(4) == [41, 42, 43, 44], "\(counters)")
        #expect(abs(receiver.listeningOffsetHz - 5_000) < 300, "\(receiver.listeningOffsetHz)")
    }

    /// Regression: the carrier search once applied its correction to a listening frequency that had already moved, and
    /// averaged spectra of samples mixed at two frequencies, so that a carrier 8 kHz off was found and then lost again
    /// (the listening frequency wandered to −11.7, −6.8 and −7.2 kHz before settling).
    @Test func aCarrierFarFromCentreIsFoundOnceAndHeld() {
        var modulator = M10Modulator(sampleRate: 192_000, carrierHz: -8_000)
        let iq = modulator.iq(frames(5))
        let receiver = M10Receiver(sampleRate: 192_000)
        var counters: [Int] = []
        var offsets: [Double] = []
        var index = 0
        while index < iq.count {
            let end = min(iq.count, index + 131_072)
            counters += receiver.process(iq: Array(iq[index..<end])).compactMap { $0.report?.counter }
            offsets.append(receiver.listeningOffsetHz)
            index = end
        }
        #expect(counters.suffix(4) == [41, 42, 43, 44], "\(counters)")
        #expect(offsets.allSatisfy { abs($0 + 8_000) < 300 }, "listening offsets \(offsets)")
    }

    /// A frame decoded while the carrier is far off the listening frequency reports a biased mean (the filter clips a
    /// tone): the listening frequency must not follow it.
    @Test func aBiasedMeanFromAMistunedFrameDoesNotMoveTheListeningFrequency() {
        var modulator = M10Modulator(sampleRate: 192_000, carrierHz: -8_000)
        let iq = modulator.iq(frames(3))
        let receiver = M10Receiver(sampleRate: 192_000)
        // Half a second in one block: the first frame (heard 8 kHz off) and the first carrier search, which finds −8 kHz.
        let events = receiver.process(iq: Array(iq.prefix(192_000)))
        #expect(abs(receiver.listeningOffsetHz + 8_000) < 300, "\(receiver.listeningOffsetHz), frames \(events.count)")
    }

    /// Some M10s send 9616 symbols a second: a clock fixed at 9600 would walk off the data within the frame.
    @Test func theSymbolRateIsFoundWhatEverItIs() {
        for baud in [9_600.0, 9_616.0, 9_590.0, 9_625.0] {
            var modulator = M10Modulator(carrierHz: 0, baud: baud)
            let audio = modulator.frequency(frames(3)).map { Float($0) }
            let events = M10Receiver(audioRate: 96_000).process(audio: audio)
            #expect(events.compactMap { $0.report?.counter } == [40, 41, 42], "\(baud)")
            #expect(events.allSatisfy { abs($0.symbolRate - baud) < 12 }, "\(baud): \(events.map(\.symbolRate))")
        }
    }

    @Test func discriminatorAndToneDetectorBothWorkAtGoodSignalLevels() {
        for useTones in [true, false] {
            var modulator = M10Modulator(sampleRate: 192_000, carrierHz: 1_500)
            let receiver = M10Receiver(sampleRate: 192_000, offsetHz: 1_500, useTones: useTones)
            let counters = run(receiver, iq: modulator.iq(frames(4))).compactMap { $0.report?.counter }
            #expect(counters == [40, 41, 42, 43], "tones \(useTones): \(counters)")
        }
    }

    @Test func noiseAloneGivesNoReports() {
        var generator = Seeded(state: 77)
        let iq = (0..<(2 * 192_000 * 5)).map { _ in UInt8(max(0, min(255, (127.5 + 20 * generator.gaussian()).rounded()))) }
        #expect(M10Receiver(sampleRate: 192_000).process(iq: iq).allSatisfy { $0.report == nil })
        var audio = [Float](repeating: 0, count: 96_000 * 5)
        for k in audio.indices { audio[k] = Float(3000 * generator.gaussian()) }
        #expect(M10Receiver(audioRate: 96_000).process(audio: audio).allSatisfy { $0.report == nil })
    }

    @Test func aFrameDamagedInFlightIsDroppedAndTheNextOneStillComes() {
        var modulator = M10Modulator(carrierHz: 0)
        var audio = modulator.frequency(frames(3)).map { Float($0) }
        var generator = Seeded(state: 2)
        // Wreck the middle of the second frame (0.3 s of lead, then a frame a second, each about 0.17 s long).
        for k in 128_000..<(128_000 + 9_000) { audio[k] = Float(5000 * generator.gaussian()) }
        let counters = M10Receiver(audioRate: 96_000).process(audio: audio).compactMap { $0.report?.counter }
        #expect(counters == [40, 42], "\(counters)")
    }
}
