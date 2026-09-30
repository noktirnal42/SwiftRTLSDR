// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

/// Regression tests for findings from the review of the decoders.

/// A DF17 or DF18 airborne position squitter with the given CPR fix (type code 11, 38 000 ft), parity computed.
func positionSquitter(address: UInt32, cpr: CPRPosition, format: Int = 17, controlField: Int = 5) -> [UInt8] {
    var bits: [Bool] = []
    func put(_ value: Int, _ count: Int) { for bit in (0..<count).reversed() { bits.append((value >> bit) & 1 == 1) } }
    put(format, 5); put(controlField, 3); put(Int(address), 24)
    put(11, 5); put(0, 2); put(0, 1); put(0xC38, 12); put(0, 1); put(cpr.isOdd ? 1 : 0, 1); put(cpr.latitude, 17); put(cpr.longitude, 17)
    var message = [UInt8](repeating: 0, count: 14)
    for (index, bit) in bits.enumerated() where bit { message[index / 8] |= 0x80 >> UInt8(index % 8) }
    let parity = ModeSCRC.checksum(message.prefix(11))
    message[11] = UInt8(parity >> 16); message[12] = UInt8((parity >> 8) & 0xff); message[13] = UInt8(parity & 0xff)
    return message
}

struct ModeSRegressionTests {
    @Test func twoWrongBitsAreNeverRepairedIntoAnotherMessage() {
        // The Mode S parity code has a minimum distance of at least 4 for these lengths, so a two-bit error can never
        // look like a one-bit error.
        let clean = bytes(hex: Riddle.identification)
        var generator = Seeded(state: 21)
        for _ in 0..<2_000 {
            let first = Int.random(in: 0..<112, using: &generator)
            var second = Int.random(in: 0..<112, using: &generator)
            while second == first { second = Int.random(in: 0..<112, using: &generator) }
            var damaged = clean
            damaged[first / 8] ^= 0x80 >> UInt8(first % 8)
            damaged[second / 8] ^= 0x80 >> UInt8(second % 8)
            #expect(ModeSCRC.correctSingleBit(&damaged) == nil, "bits \(first) and \(second)")
        }
    }

    @Test func aMirroredFirstFixFromTheReceiverIsCorrectedByTheFirstPair() throws {
        // The receiver is about 380 NM north of the aircraft, beyond the ±180 NM that one fix can resolve: the even fix
        // alone resolves to a latitude 6° too far north. The odd fix completes a pair and puts it right.
        let tracker = AircraftTracker(receiverLocation: (58.5, 3.9))
        tracker.update(ModeSMessage(bytes: bytes(hex: Riddle.evenPosition)), at: 0)
        let provisional = try #require(tracker[0x40621D])
        #expect(provisional.positionIsProvisional && abs(provisional.latitude! - 58.2572) < 0.01)
        tracker.update(ModeSMessage(bytes: bytes(hex: Riddle.oddPosition)), at: 2)
        let confirmed = try #require(tracker[0x40621D])
        #expect(!confirmed.positionIsProvisional)
        #expect(abs(confirmed.latitude! - 52.26578017412606) < 1e-9 && abs(confirmed.longitude! - 3.938912527901786) < 1e-9)
    }

    @Test func aPairThatDoesNotResolveFallsBackToTheReceiver() throws {
        // From the CPR vectors: a pair that global decoding refuses (it straddles a zone boundary).
        let rows = try resourceLines("cpr-vectors").filter { $0[0] == "pair" && $0[6] == "nil" }
        let row = try #require(rows.first)
        let e = CPRPosition(isOdd: false, latitude: Int(row[1])!, longitude: Int(row[2])!)
        let o = CPRPosition(isOdd: true, latitude: Int(row[3])!, longitude: Int(row[4])!)
        #expect(CPR.global(even: e, odd: o, newestIsOdd: true) == nil)
        let reference = CPR.local(o, reference: (40, -100))
        let tracker = AircraftTracker(receiverLocation: reference)
        tracker.update(ModeSMessage(bytes: positionSquitter(address: 0xABCDEF, cpr: e)), at: 0)
        tracker.update(ModeSMessage(bytes: positionSquitter(address: 0xABCDEF, cpr: o)), at: 1)
        #expect(tracker[0xABCDEF]?.latitude != nil, "resolved against the receiver instead of giving up")
    }

    @Test func oddLengthBlocksKeepIAndQInStep() {
        let squitters = [Riddle.identification, Riddle.groundVelocity].map { bytes(hex: $0) }
        let iq = ModeSModulator().iq([(squitters[0], 1_000), (squitters[1], 3_000)], samples: 5_000)
        let demodulator = ModeSDemodulator()
        var frames: [ModeSFrame] = []
        var position = 0
        for length in [1_001, 777, 3, 2_345] + Array(repeating: 999, count: 10) where position < iq.count {
            let end = min(iq.count, position + length)
            frames += demodulator.process(Array(iq[position..<end]))
            position = end
        }
        if position < iq.count { frames += demodulator.process(Array(iq[position...])) }
        #expect(frames.map(\.message.bytes) == squitters)
    }

    @Test func flushReadsAFrameThatEndsAtTheEndOfTheRecording() throws {
        // A 56-bit all-call reply that starts 200 samples before the end: complete, but inside the look-ahead window.
        let head: UInt32 = 11 << 27 | 5 << 24 | 0x4840D6
        let body = [UInt8(head >> 24), UInt8((head >> 16) & 0xff), UInt8((head >> 8) & 0xff), UInt8(head & 0xff)]
        let parity = ModeSCRC.checksum(body)
        let reply = body + [UInt8(parity >> 16), UInt8((parity >> 8) & 0xff), UInt8(parity & 0xff)]
        let iq = ModeSModulator().iq([(reply, 1_800)], samples: 2_000)
        let demodulator = ModeSDemodulator()
        #expect(demodulator.process(iq).isEmpty)
        let flushed = demodulator.flush()
        #expect(flushed.count == 1 && flushed.first?.message.content == .allCall(capability: 5))
    }

    @Test func onlyCleanICAOFramesConfirmAnAddress() throws {
        let rows = try resourceLines("modes-surveillance-vectors")
        let altitudeReply = bytes(hex: rows[0][1])                       // DF4 from 4840D6
        // A clean DF18 with CF 2 (fine TIS-B) carries a track address: it must not confirm 4840D6.
        let tisb = positionSquitter(address: 0x4840D6, cpr: CPRPosition(isOdd: false, latitude: 93000, longitude: 51372), format: 18, controlField: 2)
        let frames = ModeSDemodulator().process(ModeSModulator().iq([(tisb, 500), (altitudeReply, 1_500)], samples: 3_000))
        #expect(frames.count == 1 && frames.first?.message.downlinkFormat == 18)
        // CF 0 carries an ICAO address: then the reply is accepted.
        let adsb = positionSquitter(address: 0x4840D6, cpr: CPRPosition(isOdd: false, latitude: 93000, longitude: 51372), format: 18, controlField: 0)
        #expect(ModeSDemodulator().process(ModeSModulator().iq([(adsb, 500), (altitudeReply, 1_500)], samples: 3_000)).count == 2)
    }

    @Test func df18WithAnAnonymousAddressStillDecodesItsPayload() {
        let message = ModeSMessage(bytes: positionSquitter(address: 0x123456, cpr: CPRPosition(isOdd: true, latitude: 1, longitude: 2),
                                                           format: 18, controlField: 1))
        guard case .extendedSquitter(.airbornePosition(let position)) = message.content else { Issue.record("\(message.content)"); return }
        #expect(position.cpr == CPRPosition(isOdd: true, latitude: 1, longitude: 2))
    }
}

struct UATRegressionTests {
    @Test func productTimesWithSecondsAboveThirtyOneKeepThem() throws {
        // Time option 3 (month, day, hours, minutes, seconds): 9/30 12:34:45, product 413.
        var bits: [Bool] = []
        func put(_ value: Int, _ count: Int) { for bit in (0..<count).reversed() { bits.append((value >> bit) & 1 == 1) } }
        put(0, 3); put(413, 11); put(0, 1)                                 // A G P flags, product id, S flag
        put(3, 2)                                                          // time option 3
        put(9, 4); put(30, 5); put(12, 5); put(34, 6); put(45, 6)          // month, day, hours, minutes, seconds
        while bits.count % 8 != 0 { bits.append(false) }
        var data = [UInt8](repeating: 0, count: bits.count / 8)
        for (index, bit) in bits.enumerated() where bit { data[index / 8] |= 0x80 >> UInt8(index % 8) }
        let product = try #require(FISBProduct(data + [0x00]))
        #expect(product.productID == 413 && product.month == 9 && product.day == 30)
        #expect(product.hours == 12 && product.minutes == 34 && product.seconds == 45)
    }

    @Test func emptyBlocksAboveSixtyNorthStayOnTheirRingAndAreDistinct() throws {
        // Header block 405004 (ring 900, the first above 60°N), bitmap: every block after it for 3 bytes.
        let payload: [UInt8] = [0x06, 0x2e, 0x0c, 0xf3, 0xff, 0xff]        // 405004 = 0x62E0C, L = 3
        let product = try #require(FISBProduct([0x00, 0xfc, 0x00, 0x00] + payload))
        let blocks = NEXRADBlock.blocks(in: product)
        #expect(!blocks.isEmpty)
        #expect(Set(blocks.map(\.westArcminutes)).count == blocks.count, "no block twice")
        #expect(blocks.allSatisfy { $0.northArcminutes == 3604 && $0.widthArcminutes == 96 && $0.westArcminutes % 96 == 0 })
    }

    @Test func repeatedBlocksReplaceRatherThanAccumulate() throws {
        var composite = NEXRADComposite(product: .regional, hours: 4, minutes: 10)
        for frame in try sampleFrames() where frame.kind == .uplink {
            for product in (UATUplinkMessage(payload: frame.payload).informationFrames ?? []).compactMap(\.fisb) {
                for block in NEXRADBlock.blocks(in: product) { _ = composite.add(block) }
            }
        }
        #expect(composite.blockCount == 360, "720 blocks received, each position broadcast twice")
    }

    @Test func oddLengthBlocksAndFlushWork() throws {
        let frames = Array(try sampleFrames().prefix(4))
        var placed: [(UATFrame, Int)] = []
        var position = 500
        for frame in frames { placed.append((frame, position)); position += (frame.kind == .uplink ? 9_000 : 1_000) + 99 }
        // No trailing room: the last frame ends 50 samples before the recording does.
        let iq = UATModulator().iq(placed, samples: position - 99 + 50)
        let demodulator = UATDemodulator()
        var found: [UATFrame] = []
        var offset = 0
        var generator = Seeded(state: 8)
        while offset < iq.count {
            let end = min(iq.count, offset + Int.random(in: 1...9_999, using: &generator))       // odd and even lengths
            found += demodulator.process(Array(iq[offset..<end]))
            offset = end
        }
        found += demodulator.flush()
        #expect(found.map(\.payload) == frames.map(\.payload))
    }
}
