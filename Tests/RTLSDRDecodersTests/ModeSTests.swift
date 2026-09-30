// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

func bytes(hex: String) -> [UInt8] {
    var result: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        result.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return result
}

func resourceLines(_ name: String) throws -> [[String]] {
    guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Resources") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        .filter { !$0.hasPrefix("#") && !$0.isEmpty }
        .map { $0.split(separator: " ").map(String.init) }
}

/// Published examples (Junzi Sun, "The 1090 MHz Riddle"); expected values agree with pyModeS 3.6.0.
enum Riddle {
    static let identification = "8D4840D6202CC371C32CE0576098"
    static let evenPosition = "8D40621D58C382D690C8AC2863A7"
    static let oddPosition = "8D40621D58C386435CC412692AD6"
    static let groundVelocity = "8D485020994409940838175B284F"
    static let airVelocity = "8DA05F219B06B6AF189400CBC33F"
}

struct ModeSCRCTests {
    @Test(arguments: [Riddle.identification, Riddle.evenPosition, Riddle.oddPosition, Riddle.groundVelocity, Riddle.airVelocity])
    func publishedSquittersHaveAZeroSyndrome(hex: String) {
        #expect(ModeSCRC.syndrome(bytes(hex: hex)) == 0)
    }

    @Test func aSingleWrongBitIsRepairedButNeverAFormatBit() {
        let clean = bytes(hex: Riddle.identification)
        for bit in [5, 40, 87, 111] {
            var damaged = clean
            damaged[bit / 8] ^= 0x80 >> UInt8(bit % 8)
            #expect(ModeSCRC.correctSingleBit(&damaged) == bit)
            #expect(damaged == clean)
        }
        var formatHit = clean
        formatHit[0] ^= 0x10                                // bit 3, inside the downlink format
        #expect(ModeSCRC.correctSingleBit(&formatHit) == nil)
        var twoBits = clean
        twoBits[6] ^= 0x81
        #expect(ModeSCRC.correctSingleBit(&twoBits) == nil || twoBits != clean)
    }

    @Test func theSyndromeOfAnAddressParityReplyIsTheAddress() throws {
        for row in try resourceLines("modes-surveillance-vectors") {
            #expect(ModeSCRC.syndrome(bytes(hex: row[1])) == UInt32(row[4], radix: 16))
        }
    }
}

struct ModeSMessageTests {
    @Test func identification() throws {
        let message = ModeSMessage(bytes: bytes(hex: Riddle.identification))
        #expect(message.downlinkFormat == 17 && message.address == 0x4840D6)
        guard case let .extendedSquitter(.identification(id)) = message.content else { Issue.record("\(message.content)"); return }
        #expect(id.callsign == "KLM1023" && id.typeCode == 4 && id.category == 0)
    }

    @Test func airbornePosition() throws {
        let message = ModeSMessage(bytes: bytes(hex: Riddle.evenPosition))
        guard case let .extendedSquitter(.airbornePosition(position)) = message.content else { Issue.record("\(message.content)"); return }
        #expect(position.typeCode == 11 && position.altitudeFeet == 38000 && !position.altitudeIsGNSS)
        #expect(position.cpr == CPRPosition(isOdd: false, latitude: 93000, longitude: 51372))
        let odd = ModeSMessage(bytes: bytes(hex: Riddle.oddPosition))
        guard case let .extendedSquitter(.airbornePosition(oddPosition)) = odd.content else { Issue.record("\(odd.content)"); return }
        #expect(oddPosition.cpr == CPRPosition(isOdd: true, latitude: 74158, longitude: 50194))
    }

    @Test func groundVelocity() throws {
        let message = ModeSMessage(bytes: bytes(hex: Riddle.groundVelocity))
        guard case let .extendedSquitter(.velocity(velocity)) = message.content,
              case let .ground(speed, track) = velocity.kind else { Issue.record("\(message.content)"); return }
        #expect(velocity.subtype == 1)
        #expect(abs(speed - 159.20) < 0.01 && abs(track - 182.8803775528476) < 1e-9)
        #expect(velocity.verticalRateFPM == -832 && velocity.verticalRateIsGNSS && velocity.gnssMinusBaroFeet == 550)
    }

    @Test func airVelocity() throws {
        let message = ModeSMessage(bytes: bytes(hex: Riddle.airVelocity))
        guard case let .extendedSquitter(.velocity(velocity)) = message.content,
              case let .air(heading, airspeed, isTrue) = velocity.kind else { Issue.record("\(message.content)"); return }
        #expect(velocity.subtype == 3 && heading == 243.984375 && airspeed == 375 && isTrue)
        #expect(velocity.verticalRateFPM == -2304 && !velocity.verticalRateIsGNSS && velocity.gnssMinusBaroFeet == nil)
    }

    @Test func surveillanceAltitudesAndSquawksMatchAnIndependentDecoder() throws {
        let rows = try resourceLines("modes-surveillance-vectors")
        #expect(rows.count == 90)
        for row in rows {
            let message = ModeSMessage(bytes: bytes(hex: row[1]))
            #expect(message.address == 0x4840D6)
            switch (row[0], message.content) {
            case let ("alt", .altitude(feet)):
                #expect(feet == Int(row[3]), "code \(row[2])")
            case let ("id", .identity(squawk)):
                #expect(squawk == row[3], "code \(row[2])")
            default:
                Issue.record("unexpected \(message.content) for \(row)")
            }
        }
    }

    @Test func gillhamCodesAreAmongTheVectors() throws {
        // Q = 0 (bit 5 of the 13-bit code clear) means 100 ft Gillham coding: make sure those paths are covered.
        let gillham = try resourceLines("modes-surveillance-vectors").filter { $0[0] == "alt" && Int($0[2])! & 0x10 == 0 }
        #expect(gillham.count >= 30)
    }
}

struct CPRTests {
    @Test func longitudeZonesMatchAnIndependentDecoder() {
        let cases: [(Double, Int)] = [(0, 59), (10.4704713, 58), (10.4704712, 59), (45, 42), (52.2572, 36), (59.95, 30),
                                      (86.5, 3), (86.9, 2), (87, 2), (87.5, 1), (-33.9, 49), (-60.1, 29), (30, 51), (70.1, 20), (80, 10)]
        for (latitude, zones) in cases { #expect(CPR.longitudeZones(latitude) == zones, "latitude \(latitude)") }
    }

    @Test func thePublishedPairResolvesToThePublishedPosition() throws {
        let even = CPRPosition(isOdd: false, latitude: 93000, longitude: 51372)
        let odd = CPRPosition(isOdd: true, latitude: 74158, longitude: 50194)
        let position = try #require(CPR.global(even: even, odd: odd, newestIsOdd: false))
        #expect(abs(position.latitude - 52.2572021484375) < 1e-9 && abs(position.longitude - 3.91937255859375) < 1e-9)
        let local = CPR.local(even, reference: (52.258, 3.918))
        #expect(abs(local.latitude - 52.2572021484375) < 1e-9 && abs(local.longitude - 3.91937255859375) < 1e-9)
    }

    @Test func randomCasesMatchAnIndependentDecoder() throws {
        for row in try resourceLines("cpr-vectors") {
            switch row[0] {
            case "pair":
                let even = CPRPosition(isOdd: false, latitude: Int(row[1])!, longitude: Int(row[2])!)
                let odd = CPRPosition(isOdd: true, latitude: Int(row[3])!, longitude: Int(row[4])!)
                let result = CPR.global(even: even, odd: odd, newestIsOdd: row[5] == "1")
                if row[6] == "nil" {
                    #expect(result == nil, "\(row)")
                } else {
                    let position = try #require(result, "\(row)")
                    #expect(abs(position.latitude - Double(row[6])!) < 1e-6 && abs(position.longitude - Double(row[7])!) < 1e-6, "\(row)")
                }
            default:
                let fix = CPRPosition(isOdd: row[3] == "1", latitude: Int(row[1])!, longitude: Int(row[2])!)
                let position = CPR.local(fix, reference: (Double(row[4])!, Double(row[5])!))
                #expect(abs(position.latitude - Double(row[6])!) < 1e-6 && abs(position.longitude - Double(row[7])!) < 1e-6, "\(row)")
            }
        }
    }
}

/// Builds 2 MS/s u8 I/Q containing Mode S frames: four preamble pulses, then one pulse per bit in the first (1) or second
/// (0) half-microsecond. `offset` shifts every pulse by a fraction of a sample, splitting its energy between two samples.
struct ModeSModulator {
    var amplitude = 60.0                   // ADC codes
    var noise = 2.0                        // ADC codes, standard deviation
    var offset = 0.0                       // 0 ..< 0.5 of a sample
    var seed: UInt64 = 1

    func iq(_ frames: [(message: [UInt8], at: Int)], samples: Int) -> [UInt8] {
        var generator = Seeded(state: seed)
        var i = (0..<samples).map { _ in noise * generator.gaussian() }
        var q = (0..<samples).map { _ in noise * generator.gaussian() }
        for (message, start) in frames {
            let phase = Double.random(in: 0..<(2 * .pi), using: &generator)
            var pulses = [0, 2, 7, 9]
            for bit in 0..<(message.count * 8) {
                let one = (message[bit / 8] >> UInt8(7 - bit % 8)) & 1 == 1
                pulses.append(16 + 2 * bit + (one ? 0 : 1))
            }
            for pulse in pulses {
                let first = start + pulse
                for (index, weight) in [(first, 1 - offset), (first + 1, offset)] where weight > 0 && index < samples {
                    i[index] += amplitude * weight * cos(phase)
                    q[index] += amplitude * weight * sin(phase)
                }
            }
        }
        var bytes = [UInt8](repeating: 0, count: 2 * samples)
        for n in 0..<samples {
            bytes[2 * n] = UInt8(min(255, max(0, (127.5 + i[n]).rounded())))
            bytes[2 * n + 1] = UInt8(min(255, max(0, (127.5 + q[n]).rounded())))
        }
        return bytes
    }
}

struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
    mutating func gaussian() -> Double {
        let u1 = max(Double.leastNonzeroMagnitude, Double.random(in: 0..<1, using: &self))
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * Double.random(in: 0..<1, using: &self))
    }
}

struct ModeSDemodulatorTests {
    let squitters = [Riddle.identification, Riddle.evenPosition, Riddle.oddPosition, Riddle.groundVelocity, Riddle.airVelocity].map { bytes(hex: $0) }

    @Test(arguments: [0.0, 0.3])
    func squittersInTheStreamAreFoundWithTheirPositions(offset: Double) {
        var modulator = ModeSModulator()
        modulator.offset = offset
        let starts = [1_000, 3_000, 5_517, 8_000, 12_345]
        let iq = modulator.iq(Array(zip(squitters, starts)).map { ($0.0, $0.1) }, samples: 20_000)
        let frames = ModeSDemodulator().process(iq)
        #expect(frames.map(\.message.bytes) == squitters)
        #expect(frames.map(\.sampleIndex) == starts)
        // The level is read from the preamble pulses, so a pulse split across samples reads lower by its split.
        let expected = 20 * log10(60 * (1 - offset) / 127.5)
        #expect(frames.allSatisfy { $0.correctedBit == nil && abs($0.signalDBFS - expected) < 1 })
    }

    @Test func framesStraddlingBlockBoundariesAreFound() {
        let starts = [100, 2_000, 4_100, 6_000, 8_050]
        let iq = ModeSModulator().iq(Array(zip(squitters, starts)).map { ($0.0, $0.1) }, samples: 10_000)
        let demodulator = ModeSDemodulator()
        var frames: [ModeSFrame] = []
        var generator = Seeded(state: 5)
        var position = 0
        while position < iq.count {
            let length = min(iq.count - position, 2 * Int.random(in: 1...400, using: &generator))
            frames += demodulator.process(Array(iq[position..<position + length]))
            position += length
        }
        #expect(frames.map(\.message.bytes) == squitters)
        #expect(frames.map(\.sampleIndex) == starts)
    }

    @Test func addressParityRepliesNeedAConfirmedAddress() throws {
        let rows = try resourceLines("modes-surveillance-vectors")
        let altitudeReply = bytes(hex: rows[0][1])                     // DF4 from 4840D6
        let unknownFirst = ModeSModulator().iq([(altitudeReply, 500)], samples: 2_000)
        #expect(ModeSDemodulator().process(unknownFirst).isEmpty, "4840D6 has not been confirmed")

        // Confirmed by the identification squitter from the same aircraft, the reply is accepted.
        let confirmedFirst = ModeSModulator().iq([(squitters[0], 500), (altitudeReply, 1_500)], samples: 3_000)
        let frames = ModeSDemodulator().process(confirmedFirst)
        #expect(frames.count == 2)
        #expect(frames.last?.message.content == .altitude(250) && frames.last?.message.address == 0x4840D6)
    }

    @Test func aDamagedSquitterIsRepairedOnlyForAKnownAircraft() {
        var damaged = squitters[0]
        damaged[8] ^= 0x04
        let alone = ModeSModulator().iq([(damaged, 500)], samples: 2_000)
        #expect(ModeSDemodulator().process(alone).isEmpty)
        let afterClean = ModeSModulator().iq([(squitters[0], 500), (damaged, 1_500)], samples: 3_000)
        let frames = ModeSDemodulator().process(afterClean)
        #expect(frames.count == 2 && frames[1].message.bytes == squitters[0] && frames[1].correctedBit == 69)
    }

    @Test func noiseAloneProducesNoFrames() {
        var modulator = ModeSModulator()
        modulator.noise = 8
        let demodulator = ModeSDemodulator()
        var total = 0
        for seed in 1...4 {
            modulator.seed = UInt64(seed)
            total += demodulator.process(modulator.iq([], samples: 1_000_000)).count
        }
        #expect(total == 0, "8 s of noise")
    }

    @Test func weakSignalsDecodeUntilTheyDrownInNoise() {
        // Amplitude 12 codes over noise of 2 (about 15 dB) should still decode everything; the pulses have to stand
        // out from the gaps for the preamble test to pass at all.
        var modulator = ModeSModulator()
        modulator.amplitude = 12
        let starts = [1_000, 3_000, 5_000, 7_000, 9_000]
        let frames = ModeSDemodulator().process(modulator.iq(Array(zip(squitters, starts)).map { ($0.0, $0.1) }, samples: 11_000))
        #expect(frames.count == 5)
    }
}

struct AircraftTrackerTests {
    private func message(_ hex: String) -> ModeSMessage { ModeSMessage(bytes: bytes(hex: hex)) }

    @Test func anEvenOddPairGivesAPositionAndTheRestFillsIn() throws {
        let tracker = AircraftTracker()
        tracker.update(message(Riddle.oddPosition), at: 0)
        #expect(tracker[0x40621D]?.latitude == nil, "one fix is not enough without a reference")
        tracker.update(message(Riddle.evenPosition), at: 2)
        let aircraft = try #require(tracker[0x40621D])
        #expect(abs(aircraft.latitude! - 52.2572021484375) < 1e-9 && abs(aircraft.longitude! - 3.91937255859375) < 1e-9)
        #expect(aircraft.altitudeFeet == 38000 && aircraft.messages == 2)
    }

    @Test func fixesTooFarApartInTimeDoNotPair() {
        let tracker = AircraftTracker()
        tracker.update(message(Riddle.oddPosition), at: 0)
        tracker.update(message(Riddle.evenPosition), at: 30)
        #expect(tracker[0x40621D]?.latitude == nil)
    }

    @Test func aReceiverLocationResolvesTheFirstFixAlone() {
        let tracker = AircraftTracker(receiverLocation: (52.258, 3.918))
        tracker.update(message(Riddle.evenPosition), at: 0)
        #expect(abs((tracker[0x40621D]?.latitude ?? 0) - 52.2572021484375) < 1e-9)
    }

    @Test func callsignSpeedAndTrackArrive() {
        let tracker = AircraftTracker()
        tracker.update(message(Riddle.identification), at: 0)
        tracker.update(message(Riddle.groundVelocity), at: 1)
        #expect(tracker[0x4840D6]?.callsign == "KLM1023")
        #expect(abs((tracker[0x485020]?.groundSpeedKnots ?? 0) - 159.2) < 0.01 && tracker[0x485020]?.verticalRateFPM == -832)
        tracker.expire(olderThan: 60, now: 100)
        #expect(tracker.aircraft.isEmpty)
    }
}
