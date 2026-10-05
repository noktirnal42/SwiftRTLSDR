// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

/// ACARS as sent, for the tests: frame bits and MSK audio (offset QPSK with half-sine pulses on an 1800 Hz reference,
/// the pulse signs turning every second bit, written from the modulation's definition as Tools/acars-oracle.py has it).
enum ACARSTestSignal {
    static func bits(_ bytes: [UInt8]) -> [Bool] { bytes.flatMap { byte in (0..<8).map { byte >> UInt8($0) & 1 == 1 } } }

    /// MSK audio for `bits` at `rate` after `lead` seconds of silence, from a modem whose clock is `clockError` fast
    /// (tones and bit rate together, as one oscillator makes them).
    static func audio(_ bits: [Bool], rate: Double, clockError: Double = 0, lead: Double = 0.05) -> [Float] {
        let t = 1.0 / 2400, count = Int((Double(bits.count + 2) * t + 2 * lead) * rate)
        var out = [Float](repeating: 0, count: count)
        let start = Int(lead * rate)
        for n in start..<count {
            let u = Double(n - start) / rate * (1 + clockError)
            let k = Int(u / t)
            var re = 0.0, im = 0.0
            for j in [k - 1, k] where j >= 0 && j < bits.count {
                let offset = u - Double(j) * t
                guard offset >= 0, offset < 2 * t else { continue }
                let a = (bits[j] ? 1.0 : -1.0) * (j % 4 < 2 ? 1 : -1)
                let pulse = a * sin(Double.pi * offset / (2 * t))
                if j % 2 == 0 { re += pulse } else { im += pulse }
            }
            let phase = 2 * Double.pi * 1800 * u
            out[n] = Float(re * cos(phase) - im * sin(phase))
        }
        return out
    }

    static let uplink = ACARSFrameDecoder.frame(registration: "N123AB", acknowledgement: "A", label: "H1", blockID: "C",
                                                text: "POS N37 W122 /FL350")
    static let downlink = ACARSFrameDecoder.frame(mode: "E", registration: "G-ABCD", label: "Q0", blockID: "4",
                                                  messageNumber: "M12A", flightID: "BA0123", text: "")
}

struct ACARSFrameTests {
    private func decode(_ bits: [Bool]) -> [ACARSMessage] {
        let decoder = ACARSFrameDecoder()
        return bits.compactMap { decoder.push($0) }
    }

    @Test func anUplinkDecodes() throws {
        let message = try #require(decode(ACARSTestSignal.bits(ACARSTestSignal.uplink)).first)
        #expect(message.registration == "N123AB" && message.label == "H1" && message.blockID == "C" && message.mode == "2")
        #expect(message.acknowledgement == "A" && message.text == "POS N37 W122 /FL350" && !message.isDownlink)
        #expect(message.messageNumber == nil && message.flightID == nil && message.correctedBits == 0 && !message.moreBlocks)
    }

    @Test func aDownlinkCarriesItsMessageNumberAndFlight() throws {
        let message = try #require(decode(ACARSTestSignal.bits(ACARSTestSignal.downlink)).first)
        #expect(message.isDownlink && message.messageNumber == "M12A" && message.flightID == "BA0123" && message.text.isEmpty)
        #expect(message.acknowledgement == nil && message.mode == "E")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(message.json(extra: ["channel": 0]).utf8)) as? [String: Any])
        #expect(json["tail"] as? String == "G-ABCD" && json["flight"] as? String == "BA0123" && json["msgno"] as? String == "M12A")
        #expect(json["ack"] as? Bool == false && json["block_id"] as? String == "4" && json["error"] as? Int == 0)
    }

    @Test func aGeneralResponseAndMoreBlocks() throws {
        let squitter = ACARSFrameDecoder.frame(registration: "", label: "_\u{7f}", blockID: "A", text: "")
        #expect(try #require(decode(ACARSTestSignal.bits(squitter)).first).label == "_d")
        let first = ACARSFrameDecoder.frame(registration: "N1", label: "H1", blockID: "2", messageNumber: "D01A", flightID: "XX0001",
                                            text: String(repeating: "Z", count: 200), moreBlocks: true)
        let message = try #require(decode(ACARSTestSignal.bits(first)).first)
        #expect(message.moreBlocks && message.text.count == 200)
    }

    @Test func reversedPolarityIsFound() throws {
        let inverted = ACARSTestSignal.bits(ACARSTestSignal.uplink).map { !$0 }
        #expect(try #require(decode(inverted).first).registration == "N123AB")
    }

    @Test(arguments: [
        [(40, 2)],                          // one bit in a character
        [(30, 0), (52, 6)],                 // two characters
        [(29, 1), (36, 4), (41, 6)],        // three characters
        [(-3, 5)],                          // one bit of the CRC
        [(35, 1), (-2, 0)],                 // a character and the CRC
        [(44, 2), (44, 5)],                 // two in one character (its parity holds)
    ])
    func errorsAreRepaired(errors: [(Int, Int)]) throws {
        var frame = ACARSTestSignal.uplink
        for (byte, bit) in errors {
            let index = byte < 0 ? frame.count + byte : byte
            frame[index] ^= 1 << UInt8(bit)
        }
        let message = try #require(decode(ACARSTestSignal.bits(frame)).first)
        #expect(message.text == "POS N37 W122 /FL350" && message.correctedBits == errors.count)
    }

    @Test func tooMuchDamageIsRefused() {
        var frame = ACARSTestSignal.uplink
        for byte in [26, 30, 34, 38] { frame[byte] ^= 0x04 }        // four characters
        let decoder = ACARSFrameDecoder()
        #expect(ACARSTestSignal.bits(frame).compactMap { decoder.push($0) }.isEmpty)
        #expect(decoder.rejected == 1)
    }

    @Test func theCRCIsCCITTReflected() {
        #expect(ACARSFrameDecoder.crc(Array("123456789".utf8)) == 0x2189)                // CRC-16/KERMIT check value
    }
}

struct ACARSReceptionTests {
    @Test func theDemodulatorFollowsAModemClockErrorThroughNoise() {
        var generator = Seeded(state: 11)
        let bits = ACARSTestSignal.bits(ACARSTestSignal.uplink) + ACARSTestSignal.bits(ACARSTestSignal.downlink)
        // 0.2% (a modem's crystal is within 0.01%); the loop holds to about 0.25%.
        var audio = ACARSTestSignal.audio(bits, rate: 12_500, clockError: 0.002)
        for n in audio.indices { audio[n] = audio[n] * 1000 + Float(150 * generator.gaussian()) }   // about 13 dB
        let demodulator = ACARSDemodulator(sampleRate: 12_500)
        var messages: [ACARSMessage] = []
        stride(from: 0, to: audio.count, by: 1_001).forEach { messages += demodulator.process(audio: Array(audio[$0..<min(audio.count, $0 + 1_001)])) }
        #expect(messages.map(\.registration) == ["N123AB", "G-ABCD"])
    }

    @Test func twoChannelsFromOneCapture() throws {
        // Two AM transmitters 425 kHz apart, the capture centred between them at 2 MS/s.
        var generator = Seeded(state: 5)
        let rate = 2_000_000.0, center = 131_337_500.0, channels = [131_550_000.0, 131_125_000.0]
        let audio12 = ACARSTestSignal.audio(ACARSTestSignal.bits(ACARSTestSignal.uplink), rate: rate)
        let audio2 = ACARSTestSignal.audio(ACARSTestSignal.bits(ACARSTestSignal.downlink), rate: rate, lead: 0.12)
        let count = max(audio12.count, audio2.count)
        var iq = [UInt8](repeating: 0, count: 2 * count)
        for n in 0..<count {
            var i = 0.0, q = 0.0
            for (c, audio) in [audio12, audio2].enumerated() where n < audio.count {
                let envelope = 1 + 0.6 * Double(audio[n])
                let phase = 2 * Double.pi * (channels[c] - center) * Double(n) / rate + Double(c)
                i += envelope * cos(phase)
                q += envelope * sin(phase)
            }
            iq[2 * n] = UInt8(max(0, min(255, (127.5 + 25 * i + 4 * generator.gaussian()).rounded())))
            iq[2 * n + 1] = UInt8(max(0, min(255, (127.5 + 25 * q + 4 * generator.gaussian()).rounded())))
        }
        let receiver = ACARSReceiver(sampleRate: rate, centerHz: center, channels: channels)
        var receptions: [ACARSReceiver.Reception] = []
        stride(from: 0, to: iq.count, by: 262_143).forEach { receptions += receiver.process(iq: Array(iq[$0..<min(iq.count, $0 + 262_143)])) }
        let byChannel = Dictionary(grouping: receptions, by: \.channel).mapValues { $0.map(\.message.registration) }
        #expect(byChannel[0] == ["N123AB"] && byChannel[1] == ["G-ABCD"])
        #expect(receptions.allSatisfy { $0.levelDB > -20 && $0.levelDB < 0 })
    }
}
