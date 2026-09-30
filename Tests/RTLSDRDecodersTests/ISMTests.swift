// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

/// Renders OOK and FSK transmissions as u8 I/Q, with noise, a carrier offset and a random phase.
struct ISMModulator {
    var sampleRate = 250_000
    var amplitude = 60.0
    var noise = 3.0
    var carrierHz = 12_000.0
    var generator = Seeded(state: 433)

    /// (on, off) durations in microseconds, after `lead` microseconds of silence; `tail` of silence after.
    mutating func ook(_ pairs: [(on: Double, off: Double)], lead: Double = 20_000, tail: Double = 20_000) -> [UInt8] {
        var segments: [(Double, Bool)] = [(lead, false)]
        for pair in pairs { segments += [(pair.on, true), (pair.off, false)] }
        segments.append((tail, false))
        let phase0 = Double.random(in: 0..<(2 * .pi), using: &generator)
        var iq: [UInt8] = []
        var t = 0.0
        for (duration, on) in segments {
            let end = t + duration * 1e-6
            while Double(iq.count / 2) / Double(sampleRate) < end {
                let time = Double(iq.count / 2) / Double(sampleRate)
                let a = on ? amplitude : 0
                let phase = phase0 + 2 * .pi * carrierHz * time
                iq.append(sample(127.5 + a * cos(phase) + noise * generator.gaussian()))
                iq.append(sample(127.5 + a * sin(phase) + noise * generator.gaussian()))
            }
            t = end
        }
        return iq
    }

    /// NRZ bits, `bitMicroseconds` each: 1 on the upper frequency, 0 on the lower; silence around.
    mutating func fsk(_ bits: [Bool], bitMicroseconds: Double, deviationHz: Double = 40_000, lead: Double = 20_000, tail: Double = 20_000) -> [UInt8] {
        var iq: [UInt8] = []
        var phase = Double.random(in: 0..<(2 * .pi), using: &generator)
        func emit(_ seconds: Double, carrier: Bool, frequency: Double) {
            let count = Int((seconds * Double(sampleRate)).rounded())
            for _ in 0..<count {
                phase += 2 * .pi * frequency / Double(sampleRate)
                let a = carrier ? amplitude : 0
                iq.append(sample(127.5 + a * cos(phase) + noise * generator.gaussian()))
                iq.append(sample(127.5 + a * sin(phase) + noise * generator.gaussian()))
            }
        }
        emit(lead * 1e-6, carrier: false, frequency: 0)
        // The transmitter keys up on the low tone for a while before the data.
        emit(2_000e-6, carrier: true, frequency: carrierHz - deviationHz)
        for bit in bits { emit(bitMicroseconds * 1e-6, carrier: true, frequency: carrierHz + (bit ? deviationHz : -deviationHz)) }
        emit(tail * 1e-6, carrier: false, frequency: 0)
        return iq
    }

    private func sample(_ value: Double) -> UInt8 { UInt8(max(0, min(255, value.rounded()))) }
}

func bitsOf(_ bytes: [UInt8], count: Int? = nil) -> [Bool] {
    var bits: [Bool] = []
    for index in 0..<(count ?? bytes.count * 8) {
        let byte = bytes[index / 8]
        bits.append((byte >> UInt8(7 - index % 8)) & 1 == 1)
    }
    return bits
}

func decodeAll(_ receiver: ISMReceiver, _ iq: [UInt8]) -> [ISMEvent] {
    receiver.process(iq) + receiver.flush()
}

struct ISMOracleTests {
    /// Bit buffers from real recordings and what rtl_433 25.02 decodes from each (Tools/generate-ism-vectors.py).
    private func vectors() throws -> [(code: String, expected: [String])] {
        var result: [(code: String, expected: [String])] = []
        for line in try resourceText("ism-code-vectors").split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if result.last?.code != parts[0] { result.append((parts[0], [])) }
            if parts[1] != "-" { result[result.count - 1].expected.append(parts[1]) }
        }
        return result
    }

    @Test func decodersProduceRtl433sOutputForTheSameBits() throws {
        let rows = try vectors()
        #expect(rows.count > 100)
        var models = Set<String>()
        for row in rows {
            let ours = ISMReceiver.decode(code: row.code).map { $0.report.json() }
            #expect(ours == row.expected, "\(row.code)")
            for event in ISMReceiver.decode(code: row.code) { models.insert(event.report.model) }
        }
        #expect(models.count >= 35, "\(models.sorted())")
    }
}

struct ISMBuildingBlockTests {
    @Test func basebandConstantsAreRtl433s() {
        // rtl_433 derives these from butter(1, cutoff) in fixed point; compiled rtl_433 prints the same numbers.
        #expect(ISMBaseband(fmLowPass: 0.1).fmCoefficients == (11_903, 2_240))
        #expect(ISMBaseband(fmLowPass: 0.2).fmCoefficients == (8_348, 4_017))
        // π is 32767: 0, π/2, π, -π/2 (to the approximation's integer rounding).
        #expect(ISMBaseband.atan2(0, 100) == 0)
        #expect(ISMBaseband.atan2(100, 0) == 16_382)
        #expect(ISMBaseband.atan2(0, -100) == 32_766)
        #expect(ISMBaseband.atan2(-100, 0) == -16_382)
        #expect(ISMBaseband.atan2(0, 0) == 0)
    }

    @Test func checksumsMatchTheirStandardCheckValues() {
        let check = Array("123456789".utf8)
        #expect(BitUtil.crc8(check, polynomial: 0x07, initial: 0x00) == 0xf4)        // CRC-8/SMBUS
        #expect(BitUtil.crc8le(check, polynomial: 0x31, initial: 0x00) == 0xa1)      // CRC-8/MAXIM
        #expect(BitUtil.crc16(check, polynomial: 0x1021, initial: 0xffff) == 0x29b1) // CRC-16/CCITT-FALSE
        #expect(BitUtil.crc16(check, polynomial: 0x1021, initial: 0x0000) == 0x31c3) // CRC-16/XMODEM
        #expect(BitUtil.parity8(0b1011_0000) == 1 && BitUtil.parity8(0b1001_0000) == 0)
        #expect(BitUtil.reverse8(0b1000_0110) == 0b0110_0001)
    }

    @Test func bitBufferParsesAndReadsLikeRtl433() {
        var bits = BitBuffer(code: "{12}abc {4}f0/ff")
        #expect(bits.rowCount == 3)
        #expect(bits.bitsPerRow[0] == 12 && bits.bitsPerRow[1] == 4 && bits.bitsPerRow[2] == 8)
        #expect(bits.row(0)[0] == 0xab && bits.row(0)[1] == 0xc0)
        #expect(bits.row(1)[0] == 0xf0)
        #expect(bits.codes == ["{12}abc0", "{4}f0", "{8}ff"])
        #expect(BitBuffer(code: "{12}a\n").codes == ["{12}aa00"], "rtl_433 repeats the last digit for any other character")

        bits.invert()
        #expect(bits.row(0)[0] == 0x54 && bits.row(0)[1] == 0x30, "only the row's 12 bits are inverted")

        let row = BitBuffer(code: "{24}12345f")
        #expect(row.extractBytes(row: 0, from: 4, bits: 12) == [0x23, 0x40])
        #expect(row.search(row: 0, from: 0, pattern: [0x45], bits: 8) == 12)
        #expect(row.search(row: 0, from: 0, pattern: [0x99], bits: 8) == 24, "not found: the row length")

        var decoded = BitBuffer()
        let manchester = BitBuffer(code: "{16}6a5a")               // 01 10 10 10 01 01 10 10
        #expect(manchester.manchesterDecode(row: 0, from: 0, into: &decoded) == 16)
        #expect(decoded.bitsPerRow[0] == 8 && decoded.row(0)[0] == 0b1000_1100)

        let repeated = BitBuffer(code: "{8}aa{8}55{8}aa{8}aa")
        #expect(repeated.findRepeatedRow(minimumRepeats: 3, minimumBits: 8) == 0)
        #expect(repeated.findRepeatedRow(minimumRepeats: 4, minimumBits: 8) == nil)
    }

    @Test func rowsBeyondTheLimitReuseTheLastRow() {
        var bits = BitBuffer()
        for _ in 0..<60 {
            bits.addBit(1)
            bits.addRow()
        }
        #expect(bits.rowCount == BitBuffer.maximumRows)
    }

    @Test func fileNamesGiveFrequencyAndRate() {
        // As rtl_433 reads them (`tests/…/g001_868.3M_250k.cu8`).
        let named = ISMFileName.parse("tests/bresser/g001_868.3M_1000k.cu8")
        #expect(named.frequency == 868_300_000 && named.sampleRate == 1_000_000)
        let plain = ISMFileName.parse("gfile001.cu8")
        #expect(plain.frequency == nil && plain.sampleRate == nil)
        let spelled = ISMFileName.parse("rec_915MHz_2.4Msps.cu8")
        #expect(spelled.frequency == 915_000_000 && spelled.sampleRate == 2_400_000)
    }
}

struct ISMSignalTests {
    /// Nexus-TH: 36 bits PPM (500 µs pulses, 1000/2000 µs gaps, a 4000 µs sync gap), 12 repeats.
    @Test func nexusTransmissionDecodes() throws {
        // id 181, battery ok, channel 2, 21.3 °C, 55 %
        let bits = bitsOf([0xb5, 0x90, 0xd5, 0xf3, 0x70], count: 36)
        var pairs: [(on: Double, off: Double)] = []
        for _ in 0..<12 {
            pairs += bits.map { (500, $0 ? 2_000 : 1_000) }
            pairs.append((500, 4_000))
        }
        var modulator = ISMModulator()
        let events = decodeAll(ISMReceiver(), modulator.ook(pairs))
        let report = try #require(events.first?.report)
        #expect(events.count == 1)
        #expect(report.json() == #"{"model" : "Nexus-TH", "id" : 181, "channel" : 2, "battery_ok" : 1, "temperature_C" : 21.300, "humidity" : 55}"#)
    }

    /// LaCrosse TX141TH-Bv2: 4 sync pulses of 833/833 µs, then 40 bits PWM (1 = 417/208 µs, 0 = 208/417 µs).
    @Test func laCrosseTransmissionDecodes() throws {
        // id 0x5a, channel 0, 23.4 °C (234 + 500 = 734), 61 %, then the reflected LFSR digest.
        var bytes: [UInt8] = [0x5a, UInt8(734 >> 8), UInt8(734 & 0xff), 61]
        bytes.append(BitUtil.lfsrDigest8Reflect(bytes, generator: 0x31, key: 0xf4))
        let bits = bitsOf(bytes)
        var pairs: [(on: Double, off: Double)] = []
        for _ in 0..<12 {
            pairs += Array(repeating: (833, 833), count: 4)
            pairs += bits.map { $0 ? (417, 208) : (208, 417) }
        }
        pairs[pairs.count - 1].off = 30_000
        var modulator = ISMModulator()
        let events = decodeAll(ISMReceiver(), modulator.ook(pairs))
        let report = try #require(events.first?.report)
        #expect(report.model == "LaCrosse-TX141THBv2")
        #expect(report["id"] == .int(0x5a) && report["humidity"] == .int(61) && report["temperature_C"] == .float(Float(234) * 0.1))
    }

    /// An EV1527 remote: 24 bits and a stop bit, PWM (short 464 µs, long 1404 µs), repeated with long gaps.
    @Test func remoteButtonDecodes() throws {
        let code: [UInt8] = [0x9c, 0x31, 0x28]                       // id 0x9c31, command 0x28
        let bits = bitsOf(code) + [false]                            // the stop bit is a short pulse (inverted: 1)
        var pairs: [(on: Double, off: Double)] = []
        for _ in 0..<5 {
            pairs += bits.map { $0 ? (1_404, 464) : (464, 1_404) }
            pairs[pairs.count - 1].off = 14_000
        }
        var modulator = ISMModulator()
        let events = decodeAll(ISMReceiver(), modulator.ook(pairs))
        let report = try #require(events.first?.report)
        #expect(events.count == 5)
        #expect(report.json() == #"{"model" : "Generic-Remote", "id" : 39985, "cmd" : 40, "tristate" : "XZ10010Z0XX0"}"#)
    }

    /// Bresser 6-in-1: FSK, 124 µs bits, `aa aa aa 2d d4` then 18 bytes with an LFSR-16 digest and an add checksum.
    @Test func bresserTransmissionDecodes() throws {
        // Sensor type 1 at start-up, channel 0, calm (wind bytes are sent inverted), 330°, 21.5 °C, battery good, 47 %.
        var payload: [UInt8] = [0, 0, 0x12, 0x34, 0x56, 0x78, 0x18, 0xff, 0xff, 0xff, 0x33, 0x08,
                                0x21, 0x52, 0x47, 0xff, 0xf0, 0]
        payload[17] = UInt8(truncatingIfNeeded: 0xff - BitUtil.addBytes(payload[2..<17]))
        let digest = BitUtil.lfsrDigest16(payload[2..<17], generator: 0x8810, key: 0x5412)
        payload[0] = UInt8(digest >> 8); payload[1] = UInt8(digest & 0xff)
        let bits = bitsOf([0xaa, 0xaa, 0xaa, 0x2d, 0xd4] + payload + [0x00])
        var modulator = ISMModulator()
        let events = decodeAll(ISMReceiver(frequency: 868_300_000, fskDetector: .classic), modulator.fsk(bits, bitMicroseconds: 124))
        let report = try #require(events.first?.report)
        #expect(events.first?.isFSK == true)
        #expect(report.json() == #"{"model" : "Bresser-6in1", "id" : 305419896, "channel" : 0, "battery_ok" : 1, "temperature_C" : 21.500, "humidity" : 47, "sensor_type" : 1, "wind_max_m_s" : 0.000, "wind_avg_m_s" : 0.000, "wind_dir_deg" : 330, "uv" : 0.000, "startup" : 1, "flags" : 0, "mic" : "CRC"}"#)
    }

    @Test func oddLengthBlocksAndTheMinMaxDetectorWork() throws {
        var bytes: [UInt8] = [0x5a, UInt8(734 >> 8), UInt8(734 & 0xff), 61]
        bytes.append(BitUtil.lfsrDigest8Reflect(bytes, generator: 0x31, key: 0xf4))
        var pairs: [(on: Double, off: Double)] = []
        for _ in 0..<12 {
            pairs += Array(repeating: (833, 833), count: 4)
            pairs += bitsOf(bytes).map { $0 ? (417, 208) : (208, 417) }
        }
        var modulator = ISMModulator()
        let iq = modulator.ook(pairs)
        let receiver = ISMReceiver(frequency: 915_000_000)            // min/max FSK detector; OOK is unaffected
        #expect(receiver.fskDetector == .minMax)
        var events: [ISMEvent] = []
        var offset = 0
        var generator = Seeded(state: 5)
        while offset < iq.count {
            let end = min(iq.count, offset + Int.random(in: 1...40_001, using: &generator))
            events += receiver.process(Array(iq[offset..<end]))
            offset = end
        }
        events += receiver.flush()
        #expect(events.map(\.report.model) == ["LaCrosse-TX141THBv2"])
    }

    @Test func silenceAndNoiseDecodeNothing() {
        var modulator = ISMModulator()
        modulator.noise = 8
        let receiver = ISMReceiver()
        let events = decodeAll(receiver, modulator.ook([], lead: 1_000_000, tail: 1_000_000))
        #expect(events.isEmpty)
    }
}
