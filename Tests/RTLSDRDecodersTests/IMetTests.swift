// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

/// Builds iMet packets (each with its checksum) from field values, following NOAA's protocol document.
struct IMetPacketBuilder {
    var number = 1234
    var pressure = 856.43, temperature = -12.34, humidity = 47.25, battery = 4.7
    var internalTemperature = 21.5, pressureSensorTemperature = 19.25, humiditySensorTemperature = -3.5
    var latitude: Float = 47.55123, longitude: Float = -122.30456
    var altitude = 1204
    var satellites = 9
    var hour = 10, minute = 20, second = 18
    var velocity: (Float, Float, Float) = (6.5, -2.25, 5.125)

    private func seal(_ bytes: [UInt8]) -> [UInt8] {
        let check = IMet.checksum(bytes)
        return bytes + [UInt8(check >> 8), UInt8(check & 0xff)]
    }

    private func little(_ value: Int, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
    private func littleFloat(_ value: Float) -> [UInt8] { little(Int(value.bitPattern), 4) }
    private func hundredths(_ value: Double) -> [UInt8] { little(Int((value * 100).rounded()), 2) }

    func ptu(extended: Bool = false) -> [UInt8] {
        var bytes: [UInt8] = [1, extended ? 4 : 1] + little(number, 2) + little(Int((pressure * 100).rounded()), 3) + hundredths(temperature)
            + hundredths(humidity) + [UInt8((battery * 10).rounded())]
        if extended { bytes += hundredths(internalTemperature) + hundredths(pressureSensorTemperature) + hundredths(humiditySensorTemperature) }
        return seal(bytes)
    }

    func gps(extended: Bool = false) -> [UInt8] {
        var bytes: [UInt8] = [1, extended ? 5 : 2] + littleFloat(latitude) + littleFloat(longitude) + little(altitude + 5000, 2) + [UInt8(satellites)]
        if extended { bytes += littleFloat(velocity.0) + littleFloat(velocity.1) + littleFloat(velocity.2) }
        bytes += [UInt8(hour), UInt8(minute), UInt8(second)]
        return seal(bytes)
    }

    func xdata(_ data: [UInt8]) -> [UInt8] { seal([1, 3, UInt8(data.count)] + data) }

    /// A second of telemetry: position, then the sonde's own readings.
    func frame(extended: Bool = false, extra: [[UInt8]] = []) -> [UInt8] {
        gps(extended: extended) + ptu(extended: extended) + extra.flatMap { xdata($0) }
    }
}

/// Renders frames as they sound: idle line, then each byte as an asynchronous character at `baud`, as continuous-phase
/// 1200 and 2200 Hz audio frequency shift keying, which frequency-modulates a carrier by ±`deviation`.
struct IMetModulator {
    var sampleRate = 48_000.0
    var baud = 1_200.0
    var deviation = 3_000.0
    var carrierHz = 0.0
    var noise = 0.0
    var generator = Seeded(state: 5)

    /// The line's bits: `idle` marks before each frame (and after the last), then the characters.
    func bits(_ frames: [[UInt8]], idle: Int = 1_000) -> [Int] {
        var out = [Int](repeating: 1, count: idle)
        for frame in frames {
            for byte in frame { out += [0] + (0..<8).map { Int(byte >> UInt8($0) & 1) } + [1] }
            out += [Int](repeating: 1, count: idle)
        }
        return out
    }

    /// FM audio: the modulating audio's deviation in hertz plus the carrier offset, one value per sample.
    mutating func audio(_ frames: [[UInt8]], idle: Int = 1_000) -> [Double] {
        let line = bits(frames, idle: idle)
        let count = Int(Double(line.count) * sampleRate / baud)
        var phase = 0.0
        return (0..<count).map { n in
            let bit = line[min(line.count - 1, Int(Double(n) * baud / sampleRate))]
            phase += 2 * .pi * (bit == 1 ? IMet.markHz : IMet.spaceHz) / sampleRate
            return carrierHz + deviation * sin(phase) + noise * generator.gaussian()
        }
    }

    /// u8 I/Q of the carrier frequency-modulated by that audio.
    mutating func iq(_ frames: [[UInt8]], idle: Int = 1_000, amplitude: Double = 50, noise: Double = 6) -> [UInt8] {
        let shift = audio(frames, idle: idle)
        var phase = Double.random(in: 0..<(2 * .pi), using: &generator)
        var out = [UInt8](repeating: 0, count: 2 * shift.count)
        for (n, f) in shift.enumerated() {
            phase += 2 * .pi * f / sampleRate
            out[2 * n] = UInt8(max(0, min(255, (127.5 + amplitude * cos(phase) + noise * generator.gaussian()).rounded())))
            out[2 * n + 1] = UInt8(max(0, min(255, (127.5 + amplitude * sin(phase) + noise * generator.gaussian()).rounded())))
        }
        return out
    }
}

struct IMetPacketTests {
    @Test func theChecksumIsCCITTFromTheSeedTheSondesUse() {
        // Bitwise CRC-16 (0x1021) started from 0x1D0F; "123456789" gives 0xE5CC from that seed (the AUG-CCITT check value).
        #expect(IMet.checksum(Array("123456789".utf8)) == 0xE5CC)
        #expect(IMet.checksum([UInt8]()) == 0x1D0F)
    }

    @Test func gpsAndPtuFieldsComeOutAsSent() throws {
        let builder = IMetPacketBuilder()
        let frame = IMetFrame(bytes: builder.frame())
        #expect(frame.damaged == 0 && frame.packets.count == 2)
        let gps = try #require(frame.gps), ptu = try #require(frame.ptu)
        #expect(gps.latitude == Double(builder.latitude) && gps.longitude == Double(builder.longitude))
        #expect(gps.altitude == 1204 && gps.satellites == 9 && (gps.hour, gps.minute, gps.second) == (10, 20, 18))
        #expect(gps.velocity == nil)
        #expect(ptu.number == 1234 && ptu.pressure == 856.43 && ptu.temperature == -12.34 && ptu.humidity == 47.25)
        #expect(abs(ptu.batteryVolts - 4.7) < 1e-9)
        #expect(ptu.internalTemperature == nil)
    }

    @Test func extendedPacketsCarryVelocityAndSensorTemperatures() throws {
        let frame = IMetFrame(bytes: IMetPacketBuilder().frame(extended: true))
        #expect(frame.damaged == 0 && frame.packets.count == 2)
        let gps = try #require(frame.gps), ptu = try #require(frame.ptu)
        let velocity = try #require(gps.velocity)
        #expect(velocity.east == 6.5 && velocity.north == -2.25 && velocity.up == 5.125)
        #expect((gps.hour, gps.minute, gps.second) == (10, 20, 18))
        #expect(ptu.internalTemperature == 21.5 && ptu.pressureSensorTemperature == 19.25 && ptu.humiditySensorTemperature == -3.5)
    }

    @Test func aSouthernAndLowAndFreezingSondeKeepsItsSigns() throws {
        var builder = IMetPacketBuilder()
        builder.latitude = -33.8688; builder.longitude = 151.2093; builder.altitude = -30; builder.temperature = -64.5
        let frame = IMetFrame(bytes: builder.frame())
        #expect(try #require(frame.gps).latitude == Double(Float(-33.8688)) && frame.gps?.altitude == -30)
        #expect(frame.ptu?.temperature == -64.5)
    }

    @Test func aDamagedPacketEndsTheFrameAndKeepsTheOnesBefore() throws {
        var bytes = IMetPacketBuilder().frame()
        bytes[20] ^= 0x10                                      // inside the PTU packet (the GPS packet is 18 bytes)
        let frame = IMetFrame(bytes: bytes)
        #expect(frame.packets.count == 1 && frame.damaged == 1)
        #expect(frame.gps != nil && frame.ptu == nil)
        var first = IMetPacketBuilder().frame()
        first[5] ^= 1
        let none = IMetFrame(bytes: first)
        #expect(none.packets.isEmpty && none.damaged == 1)
    }

    @Test func aFrameCutOffInAPacketKeepsTheOnesBefore() {
        let bytes = IMetPacketBuilder().frame()
        let frame = IMetFrame(bytes: Array(bytes.dropLast(5)))
        #expect(frame.packets.count == 1 && frame.damaged == 1)
    }

    @Test func instrumentDataIsKeptAsHexAndAnOzonesondeIsRead() throws {
        // INST ID 1, daisy chain 0, cell current 2345 (2.345 uA), pump temperature 31.25 C, pump current 77 mA, 11.9 V.
        let ozone: [UInt8] = [0x01, 0x00, 0x09, 0x29, 0x0c, 0x35, 77, 119]
        let frame = IMetFrame(bytes: IMetPacketBuilder().frame(extra: [ozone, [0x10, 0x01, 0xAA]]))
        #expect(frame.packets.count == 4 && frame.damaged == 0)
        #expect(frame.xdata.map(\.hex) == ["010009290C354D77", "1001AA"])
        let reading = try #require(frame.xdata[0].ozonesonde)
        #expect(reading.cellCurrent == 2.345 && reading.pumpTemperature == 31.25 && reading.pumpCurrent == 77 && abs(reading.batteryVolts - 11.9) < 1e-9)
        #expect(frame.xdata[1].ozonesonde == nil && frame.xdata[1].instrument == 0x10)
        let report = try #require(IMetDecoder().report(frame))
        #expect(report.json()?.contains("\"aux\": \"010009290C354D77#1001AA\"") == true)
    }

    @Test func jsonIsWhatImet1rsDftPrints() throws {
        let report = try #require(IMetDecoder().report(IMetFrame(bytes: IMetPacketBuilder().frame())))
        #expect(report.json(frequencyKHz: 403_000) == "{ \"type\": \"IMET\", \"frame\": 1234, \"id\": \"iMet\", \"datetime\": \"10:20:18Z\", "
            + "\"lat\": 47.55123, \"lon\": -122.30456, \"alt\": 1204, \"sats\": 9, \"temp\": -12.34, \"humidity\": 47.25, "
            + "\"pressure\": 856.43, \"batt\": 4.7, \"freq\": 403000, \"ref_datetime\": \"GPS\", \"ref_position\": \"MSL\" }")
    }

    /// The first frame of `Tools/imet-oracle.py --xdata`, which rs1729's imet1rs_dft accepts with all three checksums good
    /// and reads as 10:20:18, 47.551201, -122.304604, 1204 m, 9 satellites, packet 5000, 856.43 mb, -12.34 C, 47.25 %,
    /// 4.7 V and an ozonesonde at 2.345 uA, 31.25 C, 77 mA, 11.9 V.
    @Test func aFrameThatImet1rsDftAcceptsReadsTheSame() throws {
        let hex = "01026E343E42F59BF4C23C18090A1412CB15" + "010188138B4E012EFB75122FE653" + "010308010009290C354D77D30B"
        let characters = Array(hex)
        let bytes = stride(from: 0, to: characters.count, by: 2).map { UInt8(String(characters[$0...($0 + 1)]), radix: 16)! }
        let frame = IMetFrame(bytes: bytes)
        #expect(frame.packets.count == 3 && frame.damaged == 0)
        let report = try #require(IMetDecoder().report(frame))
        #expect(report.json() == "{ \"type\": \"IMET\", \"frame\": 5000, \"id\": \"iMet\", \"datetime\": \"10:20:18Z\", "
            + "\"lat\": 47.55120, \"lon\": -122.30460, \"alt\": 1204, \"sats\": 9, \"temp\": -12.34, \"humidity\": 47.25, "
            + "\"pressure\": 856.43, \"batt\": 4.7, \"aux\": \"010009290C354D77\", \"ref_datetime\": \"GPS\", \"ref_position\": \"MSL\" }")
        let ozone = try #require(frame.xdata.first?.ozonesonde)
        #expect(ozone.cellCurrent == 2.345 && ozone.pumpTemperature == 31.25 && ozone.pumpCurrent == 77)
    }

    @Test func aFrameWithoutAGoodPTUPacketGivesALineButNoJSON() throws {
        var bytes = IMetPacketBuilder().frame()
        bytes[25] ^= 0x40
        let report = try #require(IMetDecoder().report(IMetFrame(bytes: bytes)))
        #expect(!report.isComplete && report.json() == nil && report.frame == nil)
        #expect(report.line.hasPrefix("10:20:18  lat: 47.55123"))
    }

    @Test func aPositionOffTheGlobeGivesNoReport() {
        var builder = IMetPacketBuilder()
        builder.latitude = 91.5
        #expect(IMetDecoder().report(IMetFrame(bytes: builder.frame())) == nil)
        builder.latitude = .nan
        #expect(IMetDecoder().report(IMetFrame(bytes: builder.frame())) == nil)
    }
}

struct IMetReceiverTests {
    private func frames(_ count: Int) -> [[UInt8]] {
        (0..<count).map { index in
            var builder = IMetPacketBuilder()
            builder.number = 1234 + index
            builder.second = 18 + index
            builder.altitude = 1204 + 5 * index
            builder.latitude += Float(index) * 0.0004
            return builder.frame(extra: index % 2 == 0 ? [[0x01, 0x00, 0x09, 0x29, 0x0c, 0x35, 77, 119]] : [])
        }
    }

    private func run(_ receiver: IMetReceiver, iq: [UInt8]) throws -> [IMetEvent] {
        var events: [IMetEvent] = []
        var index = 0
        while index < iq.count {
            let end = min(iq.count, index + 96_000)
            events += try receiver.process(iq: Array(iq[index..<end]))
            index = end
        }
        return events
    }

    private func audio(_ values: [Double], receiver: IMetReceiver) throws -> [IMetEvent] {
        var events: [IMetEvent] = []
        var index = 0
        while index < values.count {
            let end = min(values.count, index + 4_800)
            events += try receiver.process(audio: values[index..<end].map { Float($0) })
            index = end
        }
        return events
    }

    @Test func reportsComeFromFMAudio() throws {
        var modulator = IMetModulator(noise: 300)
        let events = try audio(modulator.audio(frames(5)), receiver: IMetReceiver(audioRate: 48_000))
        #expect(events.compactMap { $0.report?.frame } == [1234, 1235, 1236, 1237, 1238])
        #expect(events.compactMap { $0.report?.gps.second } == [18, 19, 20, 21, 22])
        #expect(events.compactMap { $0.report?.gps.altitude } == [1204, 1209, 1214, 1219, 1224])
        #expect(events.map { $0.report?.aux.count } == [1, 0, 1, 0, 1])
    }

    @Test func aDiscriminatorsDCOffsetDoesNotMatter() throws {
        var modulator = IMetModulator(carrierHz: 3_500, noise: 200)
        let events = try audio(modulator.audio(frames(3)), receiver: IMetReceiver(audioRate: 48_000))
        #expect(events.compactMap { $0.report?.frame } == [1234, 1235, 1236])
    }

    @Test func otherAudioRatesWork() throws {
        for rate in [44_100.0, 22_050.0, 96_000.0] {
            var modulator = IMetModulator(sampleRate: rate, noise: 200)
            let events = try audio(modulator.audio(frames(3)), receiver: IMetReceiver(audioRate: rate))
            #expect(events.compactMap { $0.report?.frame } == [1234, 1235, 1236], "\(rate)")
        }
    }

    /// The sonde's clock is not the receiver's: a frame a thousand bits long must survive a 0.5 % baud error.
    @Test func aBaudRateOffByHalfAPercentIsFollowed() throws {
        for factor in [0.995, 1.005] {
            var modulator = IMetModulator(baud: 1_200 * factor, noise: 200)
            let events = try audio(modulator.audio(frames(3)), receiver: IMetReceiver(audioRate: 48_000))
            #expect(events.compactMap { $0.report?.frame } == [1234, 1235, 1236], "factor \(factor)")
        }
    }

    @Test func reportsComeFromIQAtAnOffsetCarrier() throws {
        var modulator = IMetModulator(sampleRate: 240_000)
        let events = try run(IMetReceiver(sampleRate: 240_000, offsetHz: 3_000, channelCutoffHz: 5_000), iq: modulator.iq(frames(6)))
        #expect(events.compactMap { $0.report?.frame }.suffix(5) == [1235, 1236, 1237, 1238, 1239], "\(events.compactMap { $0.report?.frame })")
    }

    @Test func aCarrierFarFromCentreIsFoundAndHeld() throws {
        var modulator = IMetModulator(sampleRate: 240_000)
        let signal = modulator.iq(frames(10))
        // The oscillator is told the sonde is 9 kHz away from where it is (so the carrier search has to find it).
        let receiver = IMetReceiver(sampleRate: 240_000, offsetHz: -6_000, channelCutoffHz: 5_000)
        let events = try run(receiver, iq: signal)
        #expect(events.count >= 6, "\(events.count)")
        #expect(abs(receiver.listeningOffsetHz) < 1_500, "\(receiver.listeningOffsetHz)")
    }

    @Test func noiseAloneGivesNoReports() throws {
        var generator = Seeded(state: 77)
        let noise = (0..<(2 * 240_000 * 10)).map { _ in UInt8(max(0, min(255, (127.5 + 12 * generator.gaussian()).rounded()))) }
        #expect(try run(IMetReceiver(sampleRate: 240_000, offsetHz: 3_000), iq: noise).isEmpty)
        var rng = Seeded(state: 78)
        let hiss = (0..<(48_000 * 20)).map { _ in Float(1_500 * rng.gaussian()) }
        #expect(try IMetReceiver(audioRate: 48_000).process(audio: hiss).isEmpty)
    }

    @Test func aFrameDamagedInFlightIsDroppedAndTheNextOneStillComes() throws {
        var sent = frames(4)
        sent[1][3] ^= 0x01                   // the second frame's GPS packet, so that nothing in it can be trusted
        var modulator = IMetModulator(noise: 200)
        let events = try audio(modulator.audio(sent), receiver: IMetReceiver(audioRate: 48_000))
        #expect(events.compactMap { $0.report?.frame } == [1234, 1236, 1237])
    }

    @Test func aReceiverMadeForAudioRefusesIQAndTheOtherWayAround() {
        #expect(throws: IMetReceiver.Failure.self) { try IMetReceiver(audioRate: 48_000).process(iq: [0, 0]) }
        #expect(throws: IMetReceiver.Failure.self) { try IMetReceiver(sampleRate: 240_000).process(audio: [0]) }
    }
}
