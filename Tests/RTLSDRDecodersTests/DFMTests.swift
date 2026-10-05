// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

/// Builds DFM frames (as soft bits, +1 for a 1) from field values, with its own Hamming encoder and interleaver.
struct DFMFrameBuilder {
    static func hamming(_ nibble: Int) -> [Int] {
        let d0 = nibble >> 3 & 1, d1 = nibble >> 2 & 1, d2 = nibble >> 1 & 1, d3 = nibble & 1
        return [d0, d1, d2, d3, d1 ^ d2 ^ d3, d0 ^ d2 ^ d3, d0 ^ d1 ^ d3, d0 ^ d1 ^ d2]
    }

    /// A block of `count` nibbles of `value` (most significant first) as the interleaved codeword bits.
    static func block(_ value: UInt64, nibbles count: Int) -> [Int] {
        let words = (0..<count).map { hamming(Int(value >> UInt64(4 * (count - 1 - $0)) & 0xf)) }
        var bits: [Int] = []
        for j in 0..<8 { for i in 0..<count { bits.append(words[i][j]) } }
        return bits
    }

    /// A frame of a configuration channel (id, 24-bit value) and two data packets (48-bit payload, id).
    static func frame(channel: Int, value: Int, first: (id: Int, payload: UInt64), second: (id: Int, payload: UInt64)) -> [Float] {
        var bits = (0..<16).map { 0x45CF >> (15 - $0) & 1 }
        bits += block(UInt64(channel << 24 | value), nibbles: 7)
        bits += block(first.payload << 4 | UInt64(first.id), nibbles: 13)
        bits += block(second.payload << 4 | UInt64(second.id), nibbles: 13)
        return bits.map { $0 == 1 ? 1 : -1 }
    }

    /// 24-bit float for a value: the most fractional bits that fit the 20-bit mantissa.
    static func float24(_ value: Double) -> Int {
        var p = 0
        while p < 15 && value * Double(1 << (p + 1)) < Double((1 << 20) - 1) { p += 1 }
        return p << 20 | Int((value * Double(1 << p)).rounded())
    }
}

/// A simulated flight: a second of data is nine packets, two to a frame, with a configuration channel in every frame.
struct DFMFlight {
    enum Model { case dfm06, dfm09, dfm17ByNumber, dfm09P, dfm17P }
    var model = Model.dfm09
    var serial = 21_071_356
    /// Temperature at the start; falls 6.5 K a km.
    var temperature = 15.0
    var seconds = 12
    var counterOffset = 77
    /// Seconds whose time (minute field) is corrupted into a different valid value.
    var corruptTime: Set<Int> = []
    /// Frames to lose entirely (their blocks fail), by frame number.
    var lostFrames: Set<Int> = []

    // EPCOS B57540G0502, R/T table: temperature (C) and R/R25.
    static let table: [(Double, Double)] = [(-55, 51.991), (-50, 37.989), (-45, 28.07), (-40, 20.96), (-35, 15.809), (-30, 12.037),
        (-25, 9.2484), (-20, 7.1668), (-15, 5.5993), (-10, 4.4087), (-5, 3.4971), (0, 2.7936), (5, 2.2468), (10, 1.8187),
        (15, 1.4813), (20, 1.2136), (25, 1.0), (30, 0.82845), (35, 0.68991), (40, 0.57742)]

    static func ohms(at celsius: Double) -> Double {
        var k = 0
        while k < table.count - 2 && table[k + 1].0 < celsius { k += 1 }
        let (t0, r0) = table[k], (t1, r1) = table[k + 1]
        let f = (celsius - t0) / (t1 - t0)
        return exp(log(r0) * (1 - f) + log(r1) * f) * 5000
    }

    var referenceOhms: Double { model == .dfm06 ? 10e3 : 20e3 }
    var feedbackOhms: Double { model == .dfm17ByNumber || model == .dfm17P ? 332e3 : 220e3 }
    var serialChannel: Int {
        switch model {
        case .dfm06: return 6
        case .dfm09, .dfm17ByNumber: return 0xa
        case .dfm09P: return 0xc
        case .dfm17P: return 0xd
        }
    }
    var isPressureLayout: Bool { model == .dfm09P || model == .dfm17P }

    /// Where the sonde is, second by second.
    func position(_ s: Int) -> (lat: Double, lon: Double, alt: Double) { (48.12346 + 0.00002 * Double(s), 11.56789 + 0.0001 * Double(s), 512.34 + 5.2 * Double(s)) }

    func configurationCycle(second s: Int) -> [(channel: Int, value: Int)] {
        let altitude = position(s).alt
        let celsius = temperature - 0.0065 * (altitude - 512.34)
        let gain = isPressureLayout ? 0.5 : 3.0
        let f = gain * (Self.ohms(at: celsius) + referenceOhms), f1 = gain * referenceOhms, f2 = gain * feedbackOhms
        func f24(_ v: Double) -> Int { DFMFrameBuilder.float24(v) }
        var channels: [(Int, Int)]
        if isPressureLayout {
            channels = [(0, f24(250_000)), (1, f24(f)), (2, f24(1000)), (3, f24(2000)), (4, f24(3000)), (5, f24(f1)), (6, f24(f2)),
                        (7, 2900 << 4), (8, 30_310 << 4)]
        } else if model == .dfm06 {
            channels = [(0, f24(f)), (1, f24(1000)), (2, f24(2000)), (3, f24(f1)), (4, f24(f2)), (5, 0xa00000)]
        } else {
            channels = [(0, f24(f)), (1, f24(1000)), (2, f24(2000)), (3, f24(f1)), (4, f24(f2)), (5, 2900 << 4), (6, 30_310 << 4),
                        (7, 12_345 << 4), (8, f24(777))]
        }
        if model == .dfm06 {
            channels.append((6, serial & 0xffffff))
        } else {
            channels.append((serialChannel, 0xc << 20 | (serial >> 16 & 0xffff) << 4 | 0))
            channels.append((serialChannel, 0xc << 20 | (serial & 0xffff) << 4 | 1))
        }
        return channels
    }

    /// The nine packets of second `s`.
    func packets(second s: Int) -> [(id: Int, payload: UInt64)] {
        let (lat, lon, alt) = position(s)
        let seconds = 20 + s                                                  // 10:20:20 plus s, within the minute
        var minute = 20
        if corruptTime.contains(s) { minute = 21 }
        func u(_ v: Int, _ bits: Int) -> UInt64 { UInt64(bitPattern: Int64(v)) & ((1 << UInt64(bits)) - 1) }
        let prn: UInt64 = 0b1010_0100_0001_0010_0100_0010_0101
        let counter = (gpsSeconds(second: s) - counterOffset) & 0xff
        return [
            (0, 0x1234 << 32 | 2 << 24 | UInt64(counter) << 16 | 0x0101),
            (1, prn << 16 | u(seconds % 60 * 1000, 16)),
            (2, u(Int((lat * 1e7).rounded()), 32) << 16 | u(808, 16)),
            (3, u(Int((lon * 1e7).rounded()), 32) << 16 | u(6820, 16)),
            (4, u(Int((alt * 100).rounded()), 32) << 16 | u(520, 16)),
            (5, u(4800, 16) << 32 | 0x2345_6789),
            (6, 0x0123_4567_89ab),
            (7, 0xba98_7654_3210),
            (8, u(2025, 12) << 36 | 6 << 32 | 15 << 27 | 10 << 22 | u(minute, 6) << 16 | 9 << 8),
        ]
    }

    /// GPS seconds of second `s` of the flight (2025-06-15 10:20:20 UTC plus s, leap seconds not applied).
    func gpsSeconds(second s: Int) -> Int { 1_434_018_000 + 20 + s }

    /// The frames of the flight, as soft bits (+1/-1): packets 2 to a frame, one configuration channel each.
    func frames() -> [[Float]] {
        var stream: [(id: Int, payload: UInt64)] = []
        for s in 0..<(seconds + 1) { stream += packets(second: s) }
        var cycle: [(channel: Int, value: Int)] = []
        var out: [[Float]] = []
        for number in 0..<(stream.count / 2) {
            if cycle.isEmpty { cycle = configurationCycle(second: min(seconds, number * 2 / 9)) }
            let channel = cycle.removeFirst()
            var frame = DFMFrameBuilder.frame(channel: channel.channel, value: channel.value, first: stream[2 * number], second: stream[2 * number + 1])
            if lostFrames.contains(number) { for k in 16..<DFM.frameBits { frame[k] = (k * 7 + number) % 5 < 2 ? -1 : 1 } }
            out.append(frame)
        }
        return out
    }
}

/// Renders frames as they sound: 2500 Manchester symbols a second, Gaussian-filtered (BT 0.7), ±2.4 kHz, with random
/// bits before and after; as instantaneous frequency (FM audio) or as u8 I/Q.
struct DFMModulator {
    var sampleRate = 48_000.0
    var carrierHz = 4_000.0
    var deviation = 2_400.0
    var inverted = false
    var noise = 6.0
    var generator = Seeded(state: 9)

    mutating func frequency(_ frames: [[Float]]) -> [Double] {
        func manchester(_ bit: Bool) -> [Double] { bit ? [-1, 1] : [1, -1] }
        var symbols: [Double] = []
        for _ in 0..<460 { symbols += manchester(Double.random(in: 0..<1, using: &generator) < 0.5) }
        for frame in frames { for bit in frame { symbols += manchester(bit > 0) } }
        for _ in 0..<460 { symbols += manchester(Double.random(in: 0..<1, using: &generator) < 0.5) }
        if inverted { symbols = symbols.map { -$0 } }
        let hold = max(1, Int((sampleRate / 48_000).rounded()))
        let sps = sampleRate / Double(hold) / DFM.symbolRate
        let count = Int(Double(symbols.count) * sps)
        let nrz = (0..<count).map { symbols[min(symbols.count - 1, Int(Double($0) / sps))] }
        let sigma = log(2).squareRoot() / (2 * .pi * 0.7) * sps
        let half = Int(4 * sigma)
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
        return hold == 1 ? out : out.flatMap { [Double](repeating: $0, count: hold) }
    }

    mutating func iq(_ frames: [[Float]]) -> [UInt8] {
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

struct DFMCodeTests {
    @Test func everySingleBitErrorIsMended() {
        for nibble in 0..<16 {
            let word = DFM.encode(nibble: nibble)
            #expect(DFM.syndrome(word) == 0)
            for bit in 0..<8 {
                let damaged = word ^ (UInt8(1) << UInt8(bit))
                let position = 7 - bit
                #expect(DFM.errorSyndromes.firstIndex(of: DFM.syndrome(damaged)) == position, "nibble \(nibble) bit \(bit)")
            }
        }
    }

    @Test func everyDoubleBitErrorIsNoticedNotMistakenForOne() {
        for nibble in 0..<16 {
            let word = DFM.encode(nibble: nibble)
            for a in 0..<8 {
                for b in (a + 1)..<8 {
                    let syndrome = DFM.syndrome(word ^ (UInt8(1) << UInt8(a)) ^ (UInt8(1) << UInt8(b)))
                    #expect(syndrome != 0 && !DFM.errorSyndromes.contains(syndrome), "nibble \(nibble) bits \(a) \(b)")
                }
            }
        }
    }

    @Test func framesRoundTripThroughTheInterleaver() {
        let frame = DFMFrameBuilder.frame(channel: 0xa, value: 0xc12345, first: (3, 0x1234_5678_9abc), second: (8, 0x0fed_cba9_8765))
        let decoded = DFMFrame(soft: frame)
        #expect(decoded.headerErrors == 0 && decoded.intactBlocks == 3)
        #expect(decoded.config.nibbles == [0xa, 0xc, 1, 2, 3, 4, 5])
        #expect(decoded.data[0].nibbles == [1, 2, 3, 4, 5, 6, 7, 8, 9, 0xa, 0xb, 0xc, 3])
        #expect(decoded.data[1].nibbles == [0, 0xf, 0xe, 0xd, 0xc, 0xb, 0xa, 9, 8, 7, 6, 5, 8])
    }

    @Test func oneBadBitPerCodewordIsRepairedAndCounted() {
        var frame = DFMFrameBuilder.frame(channel: 5, value: 0x123456, first: (0, 0xaaaa_5555_aaaa), second: (1, 0x1111_2222_3333))
        // Bit j of codeword i sits at 16 + 7 j + i in the configuration block: damage one bit of each codeword.
        for i in 0..<7 { frame[16 + 7 * (i % 8) + i].negate() }
        let decoded = DFMFrame(soft: frame)
        #expect(decoded.config.corrected == 7 && decoded.config.failed == 0)
        #expect(decoded.config.nibbles == [5, 1, 2, 3, 4, 5, 6])
    }

    @Test func twoBadBitsFailUnlessSoftDecisionsPickTheRightNeighbour() {
        var frame = DFMFrameBuilder.frame(channel: 5, value: 0x123456, first: (0, 0xaaaa_5555_aaaa), second: (1, 0x1111_2222_3333))
        // Two bits of the first configuration codeword (bits 0 and 1 of codeword 0), both only weakly wrong.
        frame[16] = frame[16] > 0 ? -0.3 : 0.3
        frame[16 + 7] = frame[16 + 7] > 0 ? -0.05 : 0.05
        let plain = DFMFrame(soft: frame)
        #expect(plain.config.failed == 1 && plain.config.nibbles[0] != 5)
        let repaired = DFMFrame(soft: frame, repairTwoBitErrors: true)
        #expect(repaired.config.failed == 0)
        #expect(repaired.config.nibbles == [5, 1, 2, 3, 4, 5, 6])
    }
}

struct DFMDecoderTests {
    private func reports(_ flight: DFMFlight, from start: Int = 0) -> [DFMReport] {
        let decoder = DFMDecoder()
        var out: [DFMReport] = []
        for (number, soft) in flight.frames().enumerated() where number >= start {
            if let report = decoder.ingest(DFMFrame(soft: soft), frameCount: Double(number)) { out.append(report) }
        }
        return out
    }

    @Test func gpsTimeOfADate() {
        #expect(DFMDecoder.daysSince1980(year: 1980, month: 1, day: 6) == 0)
        #expect(DFMDecoder.daysSince1980(year: 2025, month: 6, day: 15) * 86_400 + 10 * 3600 + 20 * 60 == 1_434_018_000)
        #expect(DFMDecoder.daysSince1980(year: 2024, month: 3, day: 1) - DFMDecoder.daysSince1980(year: 2024, month: 2, day: 28) == 2)
    }

    @Test func fieldsComeOutAsPutIn() throws {
        let all = reports(DFMFlight())
        let report = try #require(all.last)
        let expected = DFMFlight().position(11)
        #expect(abs(report.latitude - expected.lat) < 1e-7 && abs(report.longitude - expected.lon) < 1e-7)
        #expect(abs(report.altitude - expected.alt) < 0.006)
        #expect(report.horizontalSpeed == 8.08 && report.heading == 68.2 && report.verticalSpeed == 5.2)
        #expect(report.satellites == 9 && report.positionMode == 2 && report.geoidHeight == 48)
        #expect(report.gpsSeconds == 1_434_018_031 && report.isoTime == "2025-06-15T10:20:31.000Z")
        #expect(report.frameCounter == (1_434_018_031 - 77) & 0xff)
        #expect(report.json().hasPrefix("{ \"type\": \"DFM\", \"frame\": 1434018031, \"id\": \"DFM-21071356\", \"datetime\": \"2025-06-15T10:20:31.000Z\", \"lat\": "))
        #expect(report.json().contains("\"subtype\": \"0xA:DFM09\"") && report.json().hasSuffix("\"ref_datetime\": \"UTC\", \"ref_position\": \"GPS\", \"diff_GPS_MSL\": -48.00 }"))
        #expect(all.count >= 11, "one report a second once the packets have come round")
    }

    @Test func serialModelBatteryAndTemperatureOfEachFamily() throws {
        let cases: [(DFMFlight.Model, Int, String, String?)] = [
            (.dfm09, 21_071_356, "DFM09", "21071356"), (.dfm17ByNumber, 23_038_743, "DFM17", "23038743"),
            (.dfm09P, 20_123_456, "DFM09P", "20123456"), (.dfm17P, 24_000_001, "DFM17P", "24000001"),
            (.dfm06, 0x123456, "DFM06", "123456"),
        ]
        for (model, serial, name, text) in cases {
            var flight = DFMFlight()
            flight.model = model
            flight.serial = serial
            flight.seconds = 30
            let report = try #require(reports(flight).last, "\(name)")
            #expect(report.serial == text, "\(name)")
            #expect(report.model == name, "\(name)")
            let expected = flight.temperature - 0.0065 * (flight.position(29).alt - 512.34)
            // The channel with the temperature is up to 2.5 s old, which is 0.1 K of climb.
            #expect(abs(try #require(report.temperature, "\(name)") - expected) < 0.2, "\(name): \(String(describing: report.temperature)) against \(expected)")
            if model != .dfm06 { #expect(report.batteryVolts == 2.9, "\(name)") }
        }
    }

    @Test func temperatureFollowsTheThermistorCurve() throws {
        // One value per 10 K over the datasheet's range: the fitted curve stays within 0.1 K of the table.
        for celsius in stride(from: -50.0, through: 35.0, by: 10.0) {
            var flight = DFMFlight()
            flight.temperature = celsius
            flight.seconds = 30
            let report = try #require(reports(flight).last)
            let expected = celsius - 0.0065 * (flight.position(29).alt - 512.34)
            #expect(abs(try #require(report.temperature) - expected) < 0.2, "\(celsius): \(String(describing: report.temperature))")
        }
    }

    @Test func aWrongTimeIsNotReportedBecauseTheCounterDisagrees() {
        var flight = DFMFlight()
        flight.corruptTime = [6]
        let all = reports(flight)
        #expect(!all.contains { $0.gpsSeconds == flight.gpsSeconds(second: 6) + 60 })      // not the time the corruption says
        #expect(!all.contains { $0.gpsSeconds == flight.gpsSeconds(second: 6) })
        #expect(all.contains { $0.gpsSeconds == flight.gpsSeconds(second: 7) }, "reports go on after it")
    }

    @Test func aSecondWithAMissingPacketGivesNoReport() {
        var flight = DFMFlight()
        flight.lostFrames = [10, 11]                    // packets 20 to 23: 2, 3, 4 and 5 of the third second
        let all = reports(flight)
        #expect(all.count == 11)
        #expect(!all.contains { $0.gpsSeconds == flight.gpsSeconds(second: 2) })
        #expect(all.allSatisfy { abs($0.latitude - flight.position($0.gpsSeconds - 1_434_018_020).lat) < 1e-7 })
    }
}

struct DFMReceiverTests {
    private func flight(seconds: Int = 12) -> [[Float]] {
        var flight = DFMFlight()
        flight.seconds = seconds
        return flight.frames()
    }

    private func run(_ receiver: DFMReceiver, iq: [UInt8]) -> [DFMEvent] {
        var events: [DFMEvent] = []
        var index = 0
        while index < iq.count {
            let end = min(iq.count, index + 96_000)
            events += receiver.process(iq: Array(iq[index..<end]))
            index = end
        }
        return events
    }

    /// FM audio from another receiver, with the opposite polarity, and noise.
    @Test func reportsComeFromAudioOfEitherPolarity() {
        for inverted in [false, true] {
            var modulator = DFMModulator(sampleRate: 48_000, carrierHz: 0, inverted: inverted)
            var generator = Seeded(state: 5)
            let audio = modulator.frequency(flight()).map { Float($0 + 600 * generator.gaussian()) }
            let events = DFMReceiver(audioRate: 48_000).process(audio: audio)
            let seconds = events.compactMap { $0.report?.gpsSeconds }
            #expect(seconds.count >= 10 && seconds.last == 1_434_018_031, "inverted \(inverted): \(seconds)")
            #expect(events.allSatisfy { $0.inverted == inverted })
        }
    }

    /// The sonde 4 kHz from where the receiver starts listening: the carrier search finds it within the first second.
    @Test func reportsComeFromIQAtAnOffsetCarrier() {
        var modulator = DFMModulator(sampleRate: 96_000, carrierHz: 4_000)
        let receiver = DFMReceiver(sampleRate: 96_000)
        let events = run(receiver, iq: modulator.iq(flight()))
        let reports = events.compactMap(\.report)
        #expect(reports.count >= 9 && reports.last?.gpsSeconds == 1_434_018_031, "\(reports.map(\.gpsSeconds))")
        #expect(reports.allSatisfy { $0.serial == nil || $0.serial == "21071356" })
        #expect(abs(receiver.listeningOffsetHz - 4_000) < 200, "\(receiver.listeningOffsetHz)")
        #expect(events.contains { abs(($0.frequencyOffsetHz ?? 0) - 4_000) < 200 })
    }

    @Test func discriminatorAndToneDetectorBothWorkAtGoodSignalLevels() {
        for useTones in [true, false] {
            var modulator = DFMModulator(sampleRate: 96_000, carrierHz: 1_500)
            let receiver = DFMReceiver(sampleRate: 96_000, offsetHz: 1_500, useTones: useTones)
            let reports = run(receiver, iq: modulator.iq(flight())).compactMap(\.report)
            #expect(reports.count >= 10 && reports.last?.gpsSeconds == 1_434_018_031, "tones \(useTones): \(reports.count)")
        }
    }

    @Test func noiseAloneGivesNoReports() {
        var generator = Seeded(state: 99)
        let iq = (0..<(2 * 96_000 * 6)).map { _ in UInt8(max(0, min(255, (127.5 + 20 * generator.gaussian()).rounded()))) }
        #expect(DFMReceiver(sampleRate: 96_000).process(iq: iq).allSatisfy { $0.report == nil })
        var audio = [Float](repeating: 0, count: 48_000 * 6)
        for k in audio.indices { audio[k] = Float(2000 * generator.gaussian()) }
        #expect(DFMReceiver(audioRate: 48_000).process(audio: audio).allSatisfy { $0.report == nil })
    }

    @Test func aGapInTheSignalIsSurvived() {
        var modulator = DFMModulator(sampleRate: 48_000, carrierHz: 0)
        var audio = modulator.frequency(flight(seconds: 14)).map { Float($0) }
        // Two seconds of nothing but noise in the middle.
        var generator = Seeded(state: 3)
        for k in 96_000..<192_000 { audio[k] = Float(1500 * generator.gaussian()) }
        let seconds = DFMReceiver(audioRate: 48_000).process(audio: audio).compactMap { $0.report?.gpsSeconds }
        #expect(seconds.first.map { $0 < 1_434_018_025 } == true && seconds.last == 1_434_018_033, "\(seconds)")
        #expect(seconds.count >= 9 && seconds.count <= 13)
    }
}
