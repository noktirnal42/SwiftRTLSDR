// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

/// Encodes pages the way ITU-R M.584 lays them out, for the tests.
struct POCSAGEncoder {
    struct Page {
        var address: Int
        var function: Int
        var text: String
        var numeric = false
    }

    static let numericCharacters = POCSAG.numericCharacters

    /// The 20-bit groups of a page's text (digits or seven-bit characters, least significant bit first), padded.
    static func groups(_ page: Page) -> [UInt32] {
        var bits: [UInt32] = []
        if page.numeric {
            for character in page.text { bits += (0..<4).map { UInt32(numericCharacters.firstIndex(of: character)! >> $0 & 1) } }
            while bits.count % 20 != 0 { bits += [0, 0, 1, 1] }            // spaces
        } else {
            for scalar in page.text.unicodeScalars { bits += (0..<7).map { scalar.value >> UInt32($0) & 1 } }
            while bits.count % 20 != 0 { bits.append(0) }
        }
        return stride(from: 0, to: bits.count, by: 20).map { start in bits[start..<(start + 20)].reduce(0) { $0 << 1 | $1 } }
    }

    /// The codewords of a transmission (without the preamble): batches of a synchronisation codeword and sixteen others,
    /// a page's address in the frame its low three bits name.
    static func codewords(_ pages: [Page], trailingIdleBatch: Bool = true) -> [UInt32] {
        var slots: [UInt32] = []
        for page in pages {
            while (slots.count / 2) % 8 != page.address & 7 || slots.count % 2 != 0 { slots.append(POCSAG.idleWord) }
            slots.append(POCSAG.addressWord(address: page.address, function: page.function))
            slots += groups(page).map { POCSAG.messageWord($0) }
        }
        while slots.count % 16 != 0 { slots.append(POCSAG.idleWord) }
        if trailingIdleBatch { slots += [UInt32](repeating: POCSAG.idleWord, count: 16) }
        var out: [UInt32] = []
        for start in stride(from: 0, to: slots.count, by: 16) { out.append(POCSAG.syncWord); out += slots[start..<(start + 16)] }
        return out
    }

    /// The bits as sent: 576 bits of preamble, then each codeword's 32 bits, most significant first.
    static func bits(_ words: [UInt32], preamble: Int = 576) -> [UInt8] {
        var out: [UInt8] = (0..<preamble).map { UInt8(($0 + 1) & 1) }
        for word in words { out += (0..<32).map { UInt8(word >> UInt32(31 - $0) & 1) } }
        return out
    }
}

struct POCSAGCodewordTests {
    @Test func theSynchronisationAndIdleCodewordsAreValidCodewords() {
        // The two constants come from the recommendation; they only check out if the BCH code and the parity are right.
        #expect(POCSAG.isValid(POCSAG.syncWord) && POCSAG.isValid(POCSAG.idleWord))
        #expect(POCSAG.codeword(data21: POCSAG.syncWord >> 11) == POCSAG.syncWord)
        #expect(POCSAG.codeword(data21: POCSAG.idleWord >> 11) == POCSAG.idleWord)
    }

    @Test func oneOrTwoWrongBitsAreMendedAndThreeAreRefused() {
        var generator = Seeded(state: 3)
        for _ in 0..<200 {
            let word = POCSAG.codeword(data21: UInt32.random(in: 0..<(1 << 21), using: &generator))
            #expect(POCSAG.correct(word)?.errors == 0)
            let positions = Array((0..<32).shuffled(using: &generator).prefix(3))
            let one = word ^ 1 << UInt32(positions[0])
            let two = one ^ 1 << UInt32(positions[1])
            let three = two ^ 1 << UInt32(positions[2])
            #expect(POCSAG.correct(one)?.word == word && POCSAG.correct(one)?.errors == 1)
            #expect(POCSAG.correct(two)?.word == word && POCSAG.correct(two)?.errors == 2)
            #expect(POCSAG.correct(three) == nil)
        }
    }

    @Test func anAddressIsSplitIntoItsFrameAndTheRest() {
        let word = POCSAG.addressWord(address: 1_234_567, function: 2)
        #expect(word >> 31 == 0 && word >> 13 & 0x3FFFF == UInt32(1_234_567 >> 3) && word >> 11 & 3 == 2)
        #expect(1_234_567 & 7 == 7)
    }
}

struct POCSAGDecoderTests {
    private func decode(_ pages: [POCSAGEncoder.Page], bits transform: ([UInt8]) -> [UInt8] = { $0 }, baud: Double = 1200) -> [POCSAGMessage] {
        POCSAGDecoder(baud: baud).process(bits: transform(POCSAGEncoder.bits(POCSAGEncoder.codewords(pages))))
    }

    @Test func alphanumericAndNumericPagesComeOutAsSent() {
        let pages = [
            POCSAGEncoder.Page(address: 1_234_567, function: 3, text: "Fire at 12 Main St, ALARM 4021"),
            POCSAGEncoder.Page(address: 55_126, function: 0, text: "6]3730-047 [87", numeric: true),
            POCSAGEncoder.Page(address: 8, function: 1, text: "Hi"),
        ]
        let found = decode(pages)
        #expect(found.map(\.address) == [1_234_567, 55_126, 8])
        #expect(found.map(\.function) == [3, 0, 1])
        #expect(found[0].text() == "Fire at 12 Main St, ALARM 4021")
        #expect(found[1].text().hasPrefix("6]3730-047 [87") && found[1].text(.standard).trimmingCharacters(in: .whitespaces) == "6]3730-047 [87")
        #expect(found[2].alpha == "Hi")
    }

    @Test func aPageThatRunsIntoTheNextBatchIsKeptWhole() {
        let long = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 4)
        let found = decode([POCSAGEncoder.Page(address: 7, function: 3, text: long), POCSAGEncoder.Page(address: 2, function: 3, text: "next")])
        #expect(found.map(\.address) == [7, 2])
        #expect(found[0].alpha == long)
        #expect(found[1].alpha == "next")
    }

    @Test func aTransmissionFlippedInPolarityIsRead() {
        let pages = [POCSAGEncoder.Page(address: 99_999, function: 3, text: "inverted")]
        let found = decode(pages) { $0.map { 1 - $0 } }
        #expect(found.map(\.alpha) == ["inverted"] && found.first?.inverted == true)
    }

    @Test func oneOrTwoBadBitsInACodewordAreMended() {
        // The address (frame 0) is slot 0 of the first batch, the text from slot 1: two bits wrong in slot 2, one in slot 4.
        let pages = [POCSAGEncoder.Page(address: 123_456, function: 3, text: "damaged but whole")]
        let found = decode(pages) { bits in
            var bits = bits
            let slot = { (n: Int) in 576 + 32 + 32 * n }
            for index in [slot(2) + 5, slot(2) + 9, slot(4) + 20] { bits[index] ^= 1 }
            return bits
        }
        #expect(found.map(\.alpha) == ["damaged but whole"])
        #expect(found.first?.correctedCodewords == 2)
    }

    @Test func aCodewordBeyondRepairLosesThePageUnlessPartialOnesAreWanted() {
        let pages = [POCSAGEncoder.Page(address: 777, function: 3, text: "some words that need three codewords of text")]
        let damage: ([UInt8]) -> [UInt8] = { bits in
            var bits = bits
            // Frame 1 (address 777 & 7 = 1): address at slot 2, message from slot 3; wreck slot 4.
            let start = 576 + 32 + 4 * 32
            for k in 0..<8 { bits[start + 3 * k] ^= 1 }
            return bits
        }
        #expect(decode(pages, bits: damage).isEmpty)
        let decoder = POCSAGDecoder(baud: 1200)
        decoder.reportsPartialPages = true
        let partial = decoder.process(bits: damage(POCSAGEncoder.bits(POCSAGEncoder.codewords(pages))))
        #expect(partial.count == 1 && partial[0].damagedCodewords == 1 && partial[0].address == 777)
    }

    @Test func noiseAndGarbageBitsGiveNoPages() {
        var generator = Seeded(state: 9)
        let decoder = POCSAGDecoder(baud: 1200)
        let bits = (0..<200_000).map { _ in UInt8.random(in: 0...1, using: &generator) }
        #expect(decoder.process(bits: bits).isEmpty)
    }

    @Test func textWithoutAnAddressIsIgnored() {
        var words = POCSAGEncoder.codewords([POCSAGEncoder.Page(address: 0, function: 3, text: "lost start")])
        words[1] = POCSAG.idleWord                       // the address codeword is gone
        #expect(POCSAGDecoder(baud: 1200).process(bits: POCSAGEncoder.bits(words)).isEmpty)
    }

    @Test func jsonAndLineText() {
        let page = POCSAGMessage(address: 1_234_567, function: 3, numeric: "123", alpha: "He said \"hi\"\n", correctedCodewords: 0,
                                 damagedCodewords: 0, baud: 1200, inverted: false)
        #expect(page.line.hasPrefix("POCSAG1200: Address: 1234567  Function: 3  Alpha: He said"))
        #expect(page.json() == "{\"demod_name\": \"POCSAG1200\", \"address\": 1234567, \"function\": 3, \"alpha\": \"He said \\\"hi\\\"\\n\", \"corrected\": 0, \"damaged\": 0}")
        #expect(page.text(.numeric) == "123" && page.text(.auto) == "He said \"hi\"\n")
    }
}

/// FM audio and I/Q of a transmission, made from a modulator written for the tests.
struct POCSAGModulator {
    var baud = 1200.0
    var sampleRate = 48_000.0
    var deviation = 4_500.0
    var carrierHz = 0.0
    var noise = 0.0
    var inverted = false
    var generator = Seeded(state: 11)

    /// The audio in hertz: ±deviation, a 1 the lower frequency, smoothed over 0.6 of a bit, with the carrier offset on top.
    mutating func audio(_ bits: [UInt8], silence: Double = 0.2) -> [Double] {
        let lead = Int(silence * sampleRate)
        let sps = sampleRate / baud
        let count = Int(Double(bits.count) * sps)
        var shape = (0..<count).map { n -> Double in
            let bit = bits[min(bits.count - 1, Int(Double(n) / sps))]
            return (bit == 1 ? -1.0 : 1.0) * (inverted ? -1 : 1)
        }
        let width = max(1, Int(0.6 * sps)) | 1
        let kernel = (0..<width).map { 0.5 - 0.5 * cos(2 * .pi * (Double($0) + 0.5) / Double(width)) }
        let total = kernel.reduce(0, +)
        var smooth = [Double](repeating: 0, count: count)
        for n in 0..<count {
            var acc = 0.0
            for (k, w) in kernel.enumerated() {
                let m = n + k - width / 2
                if m >= 0 && m < count { acc += w * shape[m] }
            }
            smooth[n] = acc / total
        }
        shape = smooth
        let quiet = [Double](repeating: 0, count: lead)
        return quiet + shape.map { carrierHz + deviation * $0 + noise * generator.gaussian() } + quiet
    }

    mutating func iq(_ bits: [UInt8], silence: Double = 0.2, amplitude: Double = 50, noise: Double = 6) -> [UInt8] {
        let frequency = audio(bits, silence: silence)
        var phase = Double.random(in: 0..<(2 * .pi), using: &generator)
        var out = [UInt8](repeating: 0, count: 2 * frequency.count)
        let lead = Int(silence * sampleRate)
        for (n, f) in frequency.enumerated() {
            phase += 2 * .pi * f / sampleRate
            let on = n >= lead && n < frequency.count - lead
            let level = on ? amplitude : 0
            out[2 * n] = UInt8(max(0, min(255, (127.5 + level * cos(phase) + noise * generator.gaussian()).rounded())))
            out[2 * n + 1] = UInt8(max(0, min(255, (127.5 + level * sin(phase) + noise * generator.gaussian()).rounded())))
        }
        return out
    }
}

struct POCSAGReceiverTests {
    private let pages = [
        POCSAGEncoder.Page(address: 1_234_567, function: 3, text: "Fire at 12 Main St, ALARM 4021"),
        POCSAGEncoder.Page(address: 55_126, function: 0, text: "6]3730-047 [87", numeric: true),
        POCSAGEncoder.Page(address: 1_000_001, function: 2, text: "Second alphanumeric page, a little longer than the first"),
    ]

    private var bits: [UInt8] { POCSAGEncoder.bits(POCSAGEncoder.codewords(pages)) }

    private func run(_ receiver: POCSAGReceiver, audio: [Float], block: Int = 4_800) throws -> [POCSAGEvent] {
        var events: [POCSAGEvent] = []
        var index = 0
        while index < audio.count {
            let end = min(audio.count, index + block)
            events += try receiver.process(audio: Array(audio[index..<end]))
            index = end
        }
        return events
    }

    private func run(_ receiver: POCSAGReceiver, iq: [UInt8]) throws -> [POCSAGEvent] {
        var events: [POCSAGEvent] = []
        var index = 0
        while index < iq.count {
            let end = min(iq.count, index + 96_000)
            events += try receiver.process(iq: Array(iq[index..<end]))
            index = end
        }
        return events
    }

    @Test func eachBitRateIsFoundFromAudio() throws {
        for baud in POCSAG.baudRates {
            for rate in [22_050.0, 48_000.0] {
                var modulator = POCSAGModulator(baud: baud, sampleRate: rate, noise: 400)
                let events = try run(POCSAGReceiver(audioRate: rate), audio: modulator.audio(bits).map { Float($0) })
                #expect(events.map(\.message.address) == [1_234_567, 55_126, 1_000_001], "\(baud) bit/s at \(rate)")
                #expect(events.allSatisfy { $0.message.baud == baud })
                #expect(events.first?.message.alpha == "Fire at 12 Main St, ALARM 4021")
            }
        }
    }

    @Test func aBitRateOffByAThirdOfAPercentIsFollowed() throws {
        for factor in [0.9967, 1.0033] {
            var modulator = POCSAGModulator(baud: 1200 * factor, sampleRate: 48_000, noise: 300)
            let events = try run(POCSAGReceiver(audioRate: 48_000, bauds: [1200]), audio: modulator.audio(bits).map { Float($0) })
            #expect(events.count == 3, "factor \(factor): \(events.count)")
        }
    }

    @Test func aCarrierOffsetIsTakenOffAndPolarityDoesNotMatter() throws {
        for (offset, inverted) in [(2_500.0, false), (-3_000.0, true)] {
            var modulator = POCSAGModulator(carrierHz: offset, noise: 300, inverted: inverted)
            let events = try run(POCSAGReceiver(audioRate: 48_000, bauds: [1200]), audio: modulator.audio(bits).map { Float($0) })
            #expect(events.count == 3, "offset \(offset)")
        }
    }

    @Test func iqAtAnOffsetCarrierGivesTheSamePages() throws {
        var modulator = POCSAGModulator(baud: 1200, sampleRate: 240_000, carrierHz: 3_000)
        let receiver = POCSAGReceiver(sampleRate: 240_000, offsetHz: 3_000)
        let events = try run(receiver, iq: modulator.iq(bits))
        #expect(events.map(\.message.address) == [1_234_567, 55_126, 1_000_001])
    }

    @Test func aMistunedReceiverIsBroughtInByTheFirstPage() throws {
        // Listening 2 kHz off the carrier; the first page that comes through retunes the receiver.
        var modulator = POCSAGModulator(baud: 1200, sampleRate: 240_000, carrierHz: 5_000)
        let receiver = POCSAGReceiver(sampleRate: 240_000, offsetHz: 3_000)
        let events = try run(receiver, iq: modulator.iq(bits + bits))
        #expect(events.count >= 4, "\(events.count)")
        #expect(abs(receiver.listeningOffsetHz - 5_000) < 600, "\(receiver.listeningOffsetHz)")
    }

    @Test func noiseAloneGivesNoPages() throws {
        var generator = Seeded(state: 21)
        let hiss = (0..<(48_000 * 30)).map { _ in Float(3_000 * generator.gaussian()) }
        #expect(try run(POCSAGReceiver(audioRate: 48_000), audio: hiss).isEmpty)
        let noise = (0..<(2 * 240_000 * 10)).map { _ in UInt8(max(0, min(255, (127.5 + 12 * generator.gaussian()).rounded()))) }
        #expect(try run(POCSAGReceiver(sampleRate: 240_000, offsetHz: 3_000), iq: noise).isEmpty)
    }

    @Test func aReceiverMadeForAudioRefusesIQAndTheOtherWayAround() {
        #expect(throws: POCSAGReceiver.Failure.self) { try POCSAGReceiver(audioRate: 48_000).process(iq: [0, 0]) }
        #expect(throws: POCSAGReceiver.Failure.self) { try POCSAGReceiver(sampleRate: 240_000).process(audio: [0]) }
    }
}
