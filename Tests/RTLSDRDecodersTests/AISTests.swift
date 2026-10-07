// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

/// Writes AIS messages field by field (most significant bit first), for the tests.
final class AISBitWriter {
    var bits: [UInt8] = []

    @discardableResult
    func put(_ value: Int, _ width: Int) -> AISBitWriter {
        for k in (0..<width).reversed() { bits.append(UInt8(value >> k & 1)) }
        return self
    }

    @discardableResult
    func text(_ string: String, _ characters: Int) -> AISBitWriter {
        let padded = Array(string.uppercased().utf8.prefix(characters)) + [UInt8](repeating: 64, count: max(0, characters - string.utf8.count))
        for byte in padded { put(Int(byte >= 64 ? byte - 64 : byte), 6) }
        return self
    }

    func pad(to count: Int) { while bits.count < count { bits.append(0) } }
}

/// Frames and modulates AIS messages for the tests: a clock, flags, bit stuffing, the check sequence, NRZI and GMSK.
enum AISTransmitter {
    static func frame(_ message: [UInt8]) -> [UInt8] {
        var bits = message
        var bytes = [UInt8](repeating: 0, count: message.count / 8)
        for (k, bit) in message.enumerated() where bit == 1 { bytes[k >> 3] |= 1 << UInt8(k & 7) }
        // The frame check sequence is computed over the data alone: run the register and complement it.
        var register: UInt16 = 0xFFFF
        for byte in bytes {
            register ^= UInt16(byte)
            for _ in 0..<8 { register = register & 1 != 0 ? register >> 1 ^ 0x8408 : register >> 1 }
        }
        let check = register ^ 0xFFFF
        bits += (0..<16).map { UInt8(check >> UInt16($0) & 1) }
        var stuffed: [UInt8] = []
        var ones = 0
        for bit in bits {
            stuffed.append(bit)
            ones = bit == 1 ? ones + 1 : 0
            if ones == 5 { stuffed.append(0); ones = 0 }
        }
        let flag: [UInt8] = [0, 1, 1, 1, 1, 1, 1, 0]
        return (0..<24).map { UInt8($0 & 1) } + flag + stuffed + flag + [UInt8](repeating: 0, count: 8)
    }

    /// The line symbols (±1) of bits: NRZI, a 0 a change.
    static func line(_ bits: [UInt8]) -> [Double] {
        var level = 1.0
        return bits.map { bit in if bit == 0 { level = -level }; return level }
    }

    /// The frequency deviation (hertz) of a burst, one value per sample: Gaussian-filtered (BT 0.4) symbols times 2.4 kHz.
    static func frequency(_ bits: [UInt8], sampleRate: Double, inverted: Bool = false) -> [Double] {
        let sps = sampleRate / AIS.baud
        let symbols = line(bits)
        let count = Int(Double(symbols.count) * sps)
        let nrz = (0..<count).map { symbols[min(symbols.count - 1, Int(Double($0) / sps))] * (inverted ? -1 : 1) }
        let sigma = log(2.0).squareRoot() / (2 * .pi * 0.4) * sps
        let half = Int(4 * sigma)
        var kernel = (-half...half).map { exp(-0.5 * Double($0 * $0) / (sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var out = [Double](repeating: 0, count: count)
        for n in 0..<count {
            var acc = 0.0
            for (index, weight) in kernel.enumerated() {
                let m = min(count - 1, max(0, n + index - half))
                acc += weight * nrz[m]
            }
            out[n] = 2_400 * acc
        }
        return out
    }
}

struct AISBitsTests {
    @Test func fieldsAreReadMostSignificantBitFirstAndSigned() {
        let writer = AISBitWriter()
        writer.put(5, 6).put(-3, 8).put(0x1FF, 9)
        let bits = AISBits(bits: writer.bits)
        #expect(bits.unsigned(0, 6) == 5 && bits.signed(6, 8) == -3 && bits.unsigned(14, 9) == 0x1FF && bits.unsigned(23, 4) == 0)
    }

    @Test func armourRoundTripsAndPadsWithFillBits() throws {
        var generator = Seeded(state: 4)
        for length in [1, 5, 6, 7, 168, 171, 424] {
            let bits = AISBits(bits: (0..<length).map { _ in UInt8.random(in: 0...1, using: &generator) })
            let (payload, fill) = bits.armoured
            #expect(fill == (6 - length % 6) % 6)
            #expect(try #require(AISBits(armoured: payload, fillBits: fill)) == bits)
        }
        #expect(AISBits(armoured: "!") == nil && AISBits(armoured: "X") == nil)
    }

    @Test func sixBitTextIsAtSignPaddedAndTrimmed() {
        let writer = AISBitWriter()
        writer.text("MT.MITCHELL", 20).text("A B", 5)
        let bits = AISBits(bits: writer.bits)
        #expect(bits.text(0, characters: 20) == "MT.MITCHELL" && bits.text(120, characters: 5) == "A B")
    }
}

struct AISMessageTests {
    /// A position report from gpsd's AIVDM documentation; pyais reads it as MMSI 367078250, status 8 (sailing), 0.5 kn,
    /// -71.059467 42.38415, course 213.0, heading 226, second 35.
    @Test func aPublishedPositionReportReadsAsPyaisReadsIt() throws {
        let bits = try #require(AISBits(armoured: "15N4cJ`005Jrek0H@9n`DW5608EP"))
        let message = try #require(AISMessage(bits))
        #expect(message.type == 1 && message.mmsi == 367_078_250 && message.navigationStatus == 8 && message.rateOfTurn == 0)
        #expect(message.speedKnots == 0.5 && message.courseDegrees == 213.0 && message.heading == 226 && message.second == 35)
        #expect(abs(message.longitude! - -71.059467) < 1e-6 && abs(message.latitude! - 42.38415) < 1e-6)
        let packet = AISPacket(bits: bits, message: message, channel: "B")
        #expect(packet.sentences() == ["!AIVDM,1,1,,B,15N4cJ`005Jrek0H@9n`DW5608EP,0*13"])
    }

    /// The two-part static report of the same page: "MT.MITCHELL".
    @Test func aPublishedVoyageReportInTwoSentences() throws {
        let first = "55P5TL01VIaAL@7WKO@mBplU@<PDhh000000001S;AJ::4A80?4i@E53", second = "1@0000000000000"
        let bits = try #require(AISBits(armoured: first + second, fillBits: 2))
        let message = try #require(AISMessage(bits))
        #expect(message.type == 5 && message.mmsi == 369_190_000 && message.imo == 6_710_932 && message.callsign == "WDA9674")
        #expect(message.name == "MT.MITCHELL" && message.shipType == 99 && message.destination == "SEATTLE")
        #expect(message.toBow == 90 && message.toStern == 90 && message.toPort == 10 && message.toStarboard == 10)
        #expect(message.draught == 6.0 && (message.etaMonth, message.etaDay, message.etaHour, message.etaMinute) == (1, 2, 8, 0))
        let packet = AISPacket(bits: bits, message: message, channel: "B")
        // Sent in 60-character pieces (the sentence is at most 82 characters); the pieces make the same payload.
        let sentences = packet.sentences(sequentialID: 3)
        #expect(sentences.count == 2 && sentences.allSatisfy { $0.count + 2 <= 82 })
        #expect(sentences[0].hasPrefix("!AIVDM,2,1,3,B,") && sentences[1].hasPrefix("!AIVDM,2,2,3,B,") && sentences[1].contains(",2*"))
        let payload = sentences.map { $0.split(separator: ",")[5] }.joined()
        #expect(payload == first + second)
        for sentence in sentences {                                  // the checksum is the XOR of what is between ! and *
            let body = sentence.dropFirst().prefix { $0 != "*" }
            #expect(String(format: "%02X", body.utf8.reduce(0) { $0 ^ $1 }) == sentence.suffix(2))
        }
    }

    @Test func classBStaticAndAidReportsCarryTheirFields() throws {
        let a = AISBitWriter()
        a.put(24, 6).put(0, 2).put(338_091_445, 30).put(0, 2).text("TIAKYCEHRE", 20); a.pad(to: 168)
        let b = AISBitWriter()
        b.put(24, 6).put(0, 2).put(338_091_445, 30).put(1, 2).put(37, 8).text("VEN", 3).put(5, 4).put(12345, 20).text("WDB1234", 7)
        b.put(12, 9).put(4, 9).put(2, 6).put(3, 6).put(0, 6)
        let aid = AISBitWriter()
        aid.put(21, 6).put(0, 2).put(993_123_456, 30).put(6, 5).text("BUOY 7", 20).put(1, 1).put(-4_350_000, 28).put(21_000_000, 27)
        aid.put(0, 9).put(0, 9).put(0, 6).put(0, 6).put(1, 4).put(30, 6); aid.pad(to: 272)
        let partA = try #require(AISMessage(AISBits(bits: a.bits))), partB = try #require(AISMessage(AISBits(bits: b.bits)))
        let buoy = try #require(AISMessage(AISBits(bits: aid.bits)))
        #expect(partA.part == 0 && partA.name == "TIAKYCEHRE")
        #expect(partB.part == 1 && partB.shipType == 37 && partB.callsign == "WDB1234" && partB.vendorID == "VEN" && partB.toBow == 12 && partB.toStarboard == 3)
        #expect(buoy.aidType == 6 && buoy.name == "BUOY 7" && abs(buoy.longitude! - -7.25) < 1e-9 && abs(buoy.latitude! - 35.0) < 1e-9 && buoy.second == 30)
    }

    @Test func unavailableValuesAreNil() throws {
        let w = AISBitWriter()
        w.put(1, 6).put(0, 2).put(123_456_789, 30).put(15, 4).put(-128, 8).put(1023, 10).put(0, 1).put(108_600_000, 28).put(54_600_000, 27)
        w.put(3600, 12).put(511, 9).put(60, 6); w.pad(to: 168)
        let message = try #require(AISMessage(AISBits(bits: w.bits)))
        #expect(message.longitude == nil && message.latitude == nil && message.speedKnots == nil && message.courseDegrees == nil)
        #expect(message.heading == nil && message.rateOfTurn == nil && message.line.contains("123456789"))
    }

    @Test func shortOrUnknownMessagesDoNotCrashOrInvent() {
        #expect(AISMessage(AISBits(bits: [UInt8](repeating: 0, count: 20))) == nil)
        let w = AISBitWriter()
        w.put(1, 6).put(0, 2).put(1, 30); w.pad(to: 100)
        #expect(AISMessage(AISBits(bits: w.bits)) == nil)                       // a type 1 is 168 bits
        let other = AISBitWriter()
        other.put(8, 6).put(0, 2).put(1, 30); other.pad(to: 56)
        #expect(AISMessage(AISBits(bits: other.bits))?.typeName == "Message type 8")
    }

    @Test func jsonCarriesTheFieldsThatArePresent() throws {
        let bits = try #require(AISBits(armoured: "15N4cJ`005Jrek0H@9n`DW5608EP"))
        let json = try #require(AISMessage(bits)).json(channel: "B", frequencyHz: 162_025_000.4)
        #expect(json.hasPrefix("{\"type\": 1, \"repeat\": 0, \"mmsi\": 367078250, \"status\": 8, \"rot\": 0, \"speed\": 0.5, \"accuracy\": false, "))
        #expect(json.contains("\"lon\": -71.059467, \"lat\": 42.384150") && json.hasSuffix("\"channel\": \"B\", \"freq\": 162.025}"))
    }
}

struct AISFrameTests {
    @Test func aFrameWithAGoodSequenceIsAcceptedAndOneWithABadBitIsNot() throws {
        let writer = AISBitWriter()
        writer.put(1, 6).put(0, 2).put(123, 30); writer.pad(to: 168)
        let on = AISTransmitter.frame(writer.bits)
        // Strip the clock, the flag and the closing flag and padding; destuffing is the receiver's job, so run the sync on it.
        let sync = AISFrameSync(sampleRate: 120_000)
        let clean = try #require(sync.process(AISTransmitter.frequency([UInt8](repeating: 0, count: 0) + on, sampleRate: 120_000).map { Float($0) }).first)
        #expect(clean.bits.bits == writer.bits)
        var damaged = on
        damaged[24 + 8 + 50] ^= 1
        let other = AISFrameSync(sampleRate: 120_000)
        #expect(other.process(AISTransmitter.frequency(damaged, sampleRate: 120_000).map { Float($0) }).isEmpty)
    }

    @Test func bitStuffingSurvivesRunsOfOnes() throws {
        let writer = AISBitWriter()
        writer.put(1, 6).put(0, 2).put(0x3FFF_FFFF, 30).put(0xFFFF, 16); writer.pad(to: 168)
        let sync = AISFrameSync(sampleRate: 120_000)
        let found = try #require(sync.process(AISTransmitter.frequency(AISTransmitter.frame(writer.bits), sampleRate: 120_000).map { Float($0) }).first)
        #expect(found.bits.bits == writer.bits)
    }
}

struct AISReceiverTests {
    private func messages() -> [[UInt8]] {
        let one = AISBitWriter()
        one.put(1, 6).put(0, 2).put(367_078_250, 30).put(8, 4).put(0, 8).put(5, 10).put(1, 1).put(-42_635_680, 28).put(25_430_490, 27)
        one.put(2130, 12).put(226, 9).put(35, 6).put(0, 2).put(0, 3).put(0, 1).put(34144, 19)
        let eighteen = AISBitWriter()
        eighteen.put(18, 6).put(0, 2).put(338_097_258, 30).put(0, 8).put(0, 10).put(1, 1).put(-73_070_000, 28).put(23_128_000, 27)
        eighteen.put(3000, 12).put(511, 9).put(59, 6); eighteen.pad(to: 168)
        let static5 = AISBitWriter()
        static5.put(5, 6).put(0, 2).put(369_190_000, 30).put(0, 2).put(6_710_932, 30).text("WDA9674", 7).text("MT.MITCHELL", 20).put(99, 8)
        static5.put(90, 9).put(90, 9).put(10, 6).put(10, 6).put(1, 4).put(1, 4).put(2, 5).put(8, 5).put(0, 6).put(60, 8).text("SEATTLE", 20)
        static5.pad(to: 424)
        return [one.bits, eighteen.bits, static5.bits]
    }

    /// Bursts one after the other on one channel (`offsetHz` from the middle of the capture), as u8 I/Q.
    private func capture(_ bursts: [(bits: [UInt8], offsetHz: Double)], sampleRate: Double = 240_000, inverted: Bool = false, noise: Double = 5, seed: UInt64 = 3) -> [UInt8] {
        var generator = Seeded(state: seed)
        var out: [UInt8] = []
        let gap = Int(0.02 * sampleRate)
        func silence(_ n: Int) { for _ in 0..<n { out += [UInt8(max(0, min(255, (127.5 + noise * generator.gaussian()).rounded()))), UInt8(max(0, min(255, (127.5 + noise * generator.gaussian()).rounded())))] } }
        silence(gap)
        for burst in bursts {
            let shift = AISTransmitter.frequency(AISTransmitter.frame(burst.bits), sampleRate: sampleRate, inverted: inverted)
            var phase = Double.random(in: 0..<(2 * .pi), using: &generator)
            for f in shift {
                phase += 2 * .pi * (burst.offsetHz + f) / sampleRate
                out.append(UInt8(max(0, min(255, (127.5 + 50 * cos(phase) + noise * generator.gaussian()).rounded()))))
                out.append(UInt8(max(0, min(255, (127.5 + 50 * sin(phase) + noise * generator.gaussian()).rounded()))))
            }
            silence(gap)
        }
        return out
    }

    private func run(_ receiver: AISReceiver, iq: [UInt8]) throws -> [AISEvent] {
        var events: [AISEvent] = []
        var index = 0
        while index < iq.count {
            let end = min(iq.count, index + 96_000)
            events += try receiver.process(iq: Array(iq[index..<end]))
            index = end
        }
        return events
    }

    private var both: [(offsetHz: Double, name: String?)] { [(AIS.channelA - 162e6, "A"), (AIS.channelB - 162e6, "B")] }

    @Test func burstsOnBothChannelsComeOutOnTheirOwn() throws {
        let sent = messages()
        let signal = capture([(sent[0], AIS.channelA - 162e6), (sent[1], AIS.channelB - 162e6), (sent[2], AIS.channelA - 162e6)])
        let events = try run(AISReceiver(sampleRate: 240_000, channels: both), iq: signal)
        #expect(events.map(\.packet.bits.bits) == sent)
        #expect(events.map { $0.packet.channel } == ["A", "B", "A"])
        #expect(events.compactMap { $0.packet.message?.mmsi } == [367_078_250, 338_097_258, 369_190_000])
        #expect(events[2].packet.message?.name == "MT.MITCHELL" && events[2].packet.sentences().count == 2)
    }

    @Test func aMistunedCarrierAndAnInvertedSignalAreRead() throws {
        let sent = messages()
        for (offset, inverted) in [(3_000.0, false), (-3_500.0, true)] {
            let signal = capture(sent.map { ($0, AIS.channelA - 162e6 + offset) }, inverted: inverted)
            let events = try run(AISReceiver(sampleRate: 240_000, channels: [(AIS.channelA - 162e6, "A")]), iq: signal)
            #expect(events.map(\.packet.bits.bits) == sent, "offset \(offset), inverted \(inverted)")
        }
    }

    @Test func aStrongNeighbourOnTheOtherChannelIsNotHeardTwice() throws {
        let sent = messages()
        let events = try run(AISReceiver(sampleRate: 240_000, channels: both), iq: capture([(sent[0], AIS.channelA - 162e6)], noise: 3))
        #expect(events.count == 1 && events[0].packet.channel == "A")
    }

    @Test func noiseAloneGivesNoFrames() throws {
        var generator = Seeded(state: 17)
        let noise = (0..<(2 * 240_000 * 8)).map { _ in UInt8(max(0, min(255, (127.5 + 12 * generator.gaussian()).rounded()))) }
        #expect(try run(AISReceiver(sampleRate: 240_000, channels: both), iq: noise).isEmpty)
    }

    @Test func audioInputFindsFramesAtAnyRate() throws {
        let sent = messages()
        for rate in [48_000.0, 96_000.0] {
            var audio: [Float] = [Float](repeating: 0, count: Int(0.02 * rate))
            for message in sent { audio += AISTransmitter.frequency(AISTransmitter.frame(message), sampleRate: rate).map { Float($0) } + [Float](repeating: 0, count: Int(0.02 * rate)) }
            let events = try AISReceiver(audioRate: rate).process(audio: audio)
            #expect(events.map(\.packet.bits.bits) == sent, "\(rate)")
        }
    }

    @Test func aReceiverMadeForAudioRefusesIQAndTheOtherWayAround() {
        #expect(throws: AISReceiver.Failure.self) { try AISReceiver(audioRate: 48_000).process(iq: [0, 0]) }
        #expect(throws: AISReceiver.Failure.self) { try AISReceiver(sampleRate: 240_000, channels: [(0, nil)]).process(audio: [0]) }
    }
}
