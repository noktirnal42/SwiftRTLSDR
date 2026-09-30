// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

/// Builds standard RS41 frames (dewhitened, blocks with CRCs, parity) from field values.
struct RS41FrameBuilder {
    var frameNumber = 3172
    var serial = "L1830070"
    var battery: UInt8 = 27
    var calibrationIndex = 0
    var calibration = [UInt8](repeating: 0, count: 16)
    var measurements = [Int](repeating: 0, count: 12)
    var week = 1856
    var milliseconds = 43_166_000
    var position: (Double, Double, Double) = (4_000_000, 1_000_000, 4_800_000)     // ECEF metres
    var velocity: (Double, Double, Double) = (0, 0, 0)
    var satellites: UInt8 = 8

    /// WGS84 geodetic to ECEF (the forward formula), for placing a sonde.
    static func ecef(latitude: Double, longitude: Double, altitude: Double) -> (Double, Double, Double) {
        let a = 6_378_137.0, f = 1 / 298.257_223_563, e2 = f * (2 - f)
        let phi = latitude * .pi / 180, lambda = longitude * .pi / 180
        let n = a / (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        return ((n + altitude) * cos(phi) * cos(lambda), (n + altitude) * cos(phi) * sin(lambda), (n * (1 - e2) + altitude) * sin(phi))
    }

    func bytes() -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: RS41.standardFrameBytes)
        frame[0..<8] = [0x86, 0x35, 0xf4, 0x40, 0x93, 0xdf, 0x1a, 0x60]
        frame[56] = 0x0f
        func put16(_ value: Int, _ data: inout [UInt8], _ at: Int) { data[at] = UInt8(value & 0xff); data[at + 1] = UInt8(value >> 8 & 0xff) }
        func put32(_ value: Int, _ data: inout [UInt8], _ at: Int) { put16(value & 0xffff, &data, at); put16(value >> 16 & 0xffff, &data, at + 2) }
        func block(_ position: Int, _ id: UInt8, _ data: [UInt8]) {
            frame[position] = id
            frame[position + 1] = UInt8(data.count)
            frame[(position + 2)..<(position + 2 + data.count)] = data[...]
            let crc = RS41.crc16(data[...])
            frame[position + 2 + data.count] = UInt8(crc & 0xff)
            frame[position + 3 + data.count] = UInt8(crc >> 8)
        }
        var status = [UInt8](repeating: 0, count: 40)
        put16(frameNumber, &status, 0)
        for (index, character) in serial.utf8.prefix(8).enumerated() { status[2 + index] = character }
        status[10] = battery
        status[23] = UInt8(calibrationIndex)
        status[24..<40] = calibration[...]
        block(0x039, 0x79, status)
        var ptu = [UInt8](repeating: 0, count: 42)
        for (index, count) in measurements.enumerated() {
            ptu[3 * index] = UInt8(count & 0xff); ptu[3 * index + 1] = UInt8(count >> 8 & 0xff); ptu[3 * index + 2] = UInt8(count >> 16 & 0xff)
        }
        block(0x065, 0x7a, ptu)
        var time = [UInt8](repeating: 0, count: 30)
        put16(week, &time, 0)
        put32(milliseconds, &time, 2)
        block(0x093, 0x7c, time)
        block(0x0b5, 0x7d, [UInt8](repeating: 0x5a, count: 89))
        var fix = [UInt8](repeating: 0, count: 21)
        put32(Int(Int32((position.0 * 100).rounded())) & 0xffff_ffff, &fix, 0)
        put32(Int(Int32((position.1 * 100).rounded())) & 0xffff_ffff, &fix, 4)
        put32(Int(Int32((position.2 * 100).rounded())) & 0xffff_ffff, &fix, 8)
        put16(Int(Int16((velocity.0 * 100).rounded())) & 0xffff, &fix, 12)
        put16(Int(Int16((velocity.1 * 100).rounded())) & 0xffff, &fix, 14)
        put16(Int(Int16((velocity.2 * 100).rounded())) & 0xffff, &fix, 16)
        fix[18] = satellites
        block(0x112, 0x7b, fix)
        block(0x12b, 0x76, [UInt8](repeating: 0, count: 17))
        RS41.addParity(&frame)
        return frame
    }

    /// As sent: whitened.
    func raw() -> [UInt8] {
        var frame = bytes()
        RS41.dewhiten(&frame)
        return frame
    }
}

/// Renders RS41 frames as they sound: 4800 bit/s, least significant bit first, Gaussian-filtered (BT 0.5),
/// ±2.4 kHz deviation, one frame a second with random bits between; as instantaneous frequency (FM audio) or as u8 I/Q.
struct RS41Modulator {
    var sampleRate = 240_000.0
    var carrierHz = 4_000.0
    var noise = 6.0                                  // I/Q: per component, of an amplitude 50
    var generator = Seeded(state: 41)

    /// Instantaneous frequency in hertz, one value per sample (shaped at 48 kHz, then held for faster rates).
    mutating func frequency(_ frames: [[UInt8]]) -> [Double] {
        var bits: [Double] = (0..<1500).map { _ in Double.random(in: 0..<1, using: &generator) < 0.5 ? -1 : 1 }
        for frame in frames {
            for byte in frame { for k in 0..<8 { bits.append(byte >> UInt8(k) & 1 == 1 ? 1 : -1) } }
            for _ in 0..<(4800 - frame.count * 8) { bits.append(Double.random(in: 0..<1, using: &generator) < 0.5 ? -1 : 1) }
        }
        let hold = max(1, Int((sampleRate / 48_000).rounded()))
        let sps = sampleRate / Double(hold) / 4800
        let count = Int(Double(bits.count) * sps)
        let nrz = (0..<count).map { bits[min(bits.count - 1, Int(Double($0) / sps))] }
        let sigma = log(2).squareRoot() / (2 * .pi * 0.5) * sps
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
            out[n] = 2400 * acc
        }
        return hold == 1 ? out : out.flatMap { [Double](repeating: $0, count: hold) }
    }

    mutating func iq(_ frames: [[UInt8]]) -> [UInt8] {
        let deviation = frequency(frames)
        var phase = Double.random(in: 0..<(2 * .pi), using: &generator)
        var out = [UInt8](repeating: 0, count: 2 * deviation.count)
        for (n, f) in deviation.enumerated() {
            phase += 2 * .pi * (carrierHz + f) / sampleRate
            out[2 * n] = UInt8(max(0, min(255, (127.5 + 50 * cos(phase) + noise * generator.gaussian()).rounded())))
            out[2 * n + 1] = UInt8(max(0, min(255, (127.5 + 50 * sin(phase) + noise * generator.gaussian()).rounded())))
        }
        return out
    }
}

struct RS41CodingTests {
    @Test func whiteningIsTheSequenceItsRecurrenceMakes() {
        let mask = RS41.whitening
        for index in 24..<64 {
            #expect(mask[index] == mask[index - 16] ^ mask[index - 14] ^ mask[index - 12] ^ mask[index - 10], "byte \(index)")
        }
        var header = RS41.header
        RS41.dewhiten(&header)
        #expect(header == [0x86, 0x35, 0xf4, 0x40, 0x93, 0xdf, 0x1a, 0x60])
    }

    @Test func crcIsCCITTFalse() {
        #expect(RS41.crc16(Array("123456789".utf8)[...]) == 0x29b1)
    }

    /// Parity from reedsolo 1.7 (`RSCodec(24, 255, fcr=0, prim=0x11d)`) for a frame whose bytes from 56 on are
    /// (29·i + 7) mod 256, codewords laid out as the RS41 does.
    @Test func parityMatchesReedsolo() {
        var frame = [UInt8](repeating: 0, count: 320)
        for index in 56..<320 { frame[index] = UInt8((29 * index + 7) & 0xff) }
        RS41.addParity(&frame)
        #expect(Array(frame[8..<56]) == bytes(hex: "b8fe202d0fc292e169f9c6315cf4d4d2fd0604f7b267708942c8a544791075d5bc34903d5bbb924eb4929d13cf5a7deb"))
    }

    @Test func twelveErrorsInEachCodewordAreRepaired() {
        var generator = Seeded(state: 12)
        let clean = RS41FrameBuilder().bytes()
        var damaged = clean
        for codeword in 0..<2 {
            for index in Array(0..<132).shuffled(using: &generator).prefix(12) {
                damaged[56 + 2 * index + codeword] ^= UInt8.random(in: 1...255, using: &generator)
            }
        }
        #expect(RS41.correct(&damaged) == 24)
        #expect(damaged == clean)
    }

    @Test func blockHeadersAndPaddingGiveASecondChance() {
        // 14 errors in one codeword are too many, unless some fall on bytes known in advance. Odd offsets from byte 56
        // are the second codeword: five block IDs and five padding bytes, and four bytes nobody can know.
        var raw = RS41FrameBuilder().raw()
        let known = [0x039, 0x065, 0x093, 0x0b5, 0x12b, 0x12d, 0x12f, 0x131, 0x133, 0x135]
        let others = [0x03d, 0x041, 0x045, 0x069]
        for position in known + others { raw[position] ^= 0xa5 }
        let frame = RS41Frame(raw: raw)
        #expect(frame.corrected == others.count)
        #expect(frame.frameNumber == 3172)
    }
}

struct RS41DecoderTests {
    @Test func fieldsComeOutAsPutIn() throws {
        var builder = RS41FrameBuilder()
        builder.position = RS41FrameBuilder.ecef(latitude: 46.01891, longitude: 16.34725, altitude: 14_035.75)
        // 10 m/s towards the north-east and 5 m/s up, as ECEF.
        let phi = 46.01891 * Double.pi / 180, lambda = 16.34725 * Double.pi / 180
        let (east, north, up) = (7.0710678, 7.0710678, 5.0)
        builder.velocity = (-sin(lambda) * east - sin(phi) * cos(lambda) * north + cos(phi) * cos(lambda) * up,
                            cos(lambda) * east - sin(phi) * sin(lambda) * north + cos(phi) * sin(lambda) * up,
                            cos(phi) * north + sin(phi) * up)
        let frame = RS41Frame(raw: builder.raw())
        #expect(frame.corrected == 0)
        #expect(frame.frameNumber == 3172 && frame.serial == "L1830070" && frame.batteryVolts == 2.7)
        let report = try #require(RS41Decoder().report(frame))
        #expect(abs(report.latitude - 46.01891) < 1e-6 && abs(report.longitude - 16.34725) < 1e-6)
        #expect(abs(report.altitude - 14_035.75) < 0.02)                  // positions are sent to the centimetre
        #expect(abs(report.horizontalSpeed - 10) < 0.02 && abs(report.heading - 45) < 0.2 && abs(report.verticalSpeed - 5) < 0.02)
        // Sunday 2 August 2015, 11:59:26 GPS time: what rs41mod prints for this week and time of week.
        #expect(report.isoTime == "2015-08-02T11:59:26.000Z")
        #expect(report.json().hasPrefix("{ \"type\": \"RS41\", \"frame\": 3172, \"id\": \"L1830070\", \"datetime\": \"2015-08-02T11:59:26.000Z\", \"lat\": 46.01891, \"lon\": 16.34725,"))
    }

    @Test func calibrationPiecesGiveTemperatureModelFrequencyAndCountdown() throws {
        // A calibration table with reference resistors of 750 and 1100 Ω, the sensor quadratic and corrections.
        var table = [UInt8](repeating: 0, count: 51 * 16)
        func put(_ value: Float, _ offset: Int) {
            let bits = value.bitPattern
            for k in 0..<4 { table[offset + k] = UInt8(bits >> UInt32(8 * k) & 0xff) }
        }
        put(750, 61); put(1100, 65)
        put(-243.911, 77); put(0.187654, 81); put(8.2e-6, 85)
        put(1.0, 89); put(0.5, 93); put(0.01, 97)
        table[2] = 0x80; table[3] = 75                                   // 400 MHz + 75 × 40 kHz + 20 kHz
        table[0x21 * 16 + 8..<0x21 * 16 + 16] = Array("RS41-SGP".utf8)[...]
        table[0x32 * 16] = 0x10; table[0x32 * 16 + 1] = 0x0e              // 3600 s
        // Counts linear in resistance: 100 per ohm, 20 Ω of offset; the sensor reads 1000 Ω.
        let counts = [100 * (1000 + 20), 100 * (750 + 20), 100 * (1100 + 20)] + [Int](repeating: 0, count: 9)
        let decoder = RS41Decoder()
        var reports: [RS41Report] = []
        for piece in 0..<51 {
            var builder = RS41FrameBuilder()
            builder.frameNumber = 100 + piece
            builder.calibrationIndex = piece
            builder.calibration = Array(table[(piece * 16)..<(piece * 16 + 16)])
            builder.measurements = counts
            reports.append(try #require(decoder.report(RS41Frame(raw: builder.raw()))))
        }
        #expect(reports[5].temperature == nil && reports[6].temperature != nil)
        let quadratic: Double = -243.911 + 0.187654 * 1000 + 8.2e-6 * 1_000_000
        let expected = (quadratic + 0.5) * 1.01
        #expect(abs(try #require(reports[50].temperature) - expected) < 0.01)
        #expect(reports[0].frequencyKHz == 403_020)
        #expect(reports[0x21].subtype == "RS41" && reports[0x22].subtype == "RS41-SGP")
        #expect(reports[0x31].countdown == 0xffff && reports[0x32].countdown == 3600)
        #expect(reports[50].calibrationPieces == 51)
    }
}

struct RS41ReceiverTests {
    private func frames(_ count: Int) -> [[UInt8]] {
        (0..<count).map { index in
            var builder = RS41FrameBuilder()
            builder.frameNumber = 5000 + index
            builder.milliseconds = 43_166_000 + 1000 * index
            return builder.raw()
        }
    }

    /// The sonde 4 kHz from where the receiver starts listening: the carrier search finds it within the first second.
    @Test func framesAreReceivedFromIQ() {
        var modulator = RS41Modulator()
        let iq = modulator.iq(frames(5))
        let receiver = RS41Receiver(sampleRate: 240_000)
        var events: [RS41Event] = []
        var index = 0
        while index < iq.count {
            let end = min(iq.count, index + 96_000)
            events += receiver.process(iq: Array(iq[index..<end]))
            index = end
        }
        let numbers = events.compactMap { $0.report?.frame }
        #expect(numbers.suffix(4) == [5001, 5002, 5003, 5004], "\(numbers)")
        #expect(events.filter { $0.report != nil }.allSatisfy { $0.frame.corrected == 0 })
        #expect(abs(receiver.listeningOffsetHz - 4_000) < 150)
    }

    /// FM audio from another receiver, with the opposite polarity (as many sound cards give it).
    @Test func framesAreReceivedFromAudio() {
        var modulator = RS41Modulator(sampleRate: 48_000)
        var generator = Seeded(state: 7)
        let audio = modulator.frequency(frames(3)).map { Float(-0.01 * $0 + 3 * generator.gaussian()) }
        let receiver = RS41Receiver(audioRate: 48_000)
        let numbers = receiver.process(audio: audio).compactMap { $0.report?.frame }
        #expect(numbers == [5000, 5001, 5002])
    }

    @Test func noiseAloneGivesNoReports() {
        var generator = Seeded(state: 99)
        let iq = (0..<(2 * 240_000 * 3)).map { _ in UInt8(max(0, min(255, (127.5 + 20 * generator.gaussian()).rounded()))) }
        #expect(RS41Receiver(sampleRate: 240_000).process(iq: iq).allSatisfy { $0.report == nil })
    }
}
