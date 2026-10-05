// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

/// VDL Mode 2 as sent, for the tests: D8PSK bursts with raised-cosine pulses (α 0.6), written from the modulation's
/// definition as Tools/vdl2-oracle.py has it.
enum VDL2TestSignal {
    /// Phase steps (in π/4): five ramp-up symbols, the synchronisation sequence, then `bits` three at a time.
    static func steps(_ bits: [UInt8]) -> [Int] {
        var inverse = [Int](repeating: 0, count: 8)
        for (step, value) in VDL2Burst.gray.enumerated() { inverse[Int(value)] = step }
        var out = [Int](repeating: 0, count: 5) + VDL2Burst.syncSteps
        for i in stride(from: 0, to: bits.count, by: 3) {
            let value = Int(bits[i]) << 2 | Int(bits[i + 1]) << 1 | Int(bits[i + 2])
            out.append(inverse[value])
        }
        return out
    }

    static func raisedCosine(_ t: Double, alpha: Double = 0.6) -> Double {
        let denominator = 1 - 4 * alpha * alpha * t * t
        let sinc = t == 0 ? 1 : sin(Double.pi * t) / (Double.pi * t)
        if abs(denominator) < 1e-9 { return Double.pi / 4 * sin(Double.pi / (2 * alpha)) / (Double.pi / (2 * alpha)) }
        return sinc * cos(Double.pi * alpha * t) / denominator
    }

    /// Complex baseband at `rate` for a burst of `frames`: pulses `amplitude` high, ramped up over the ramp-up symbols,
    /// the carrier `offsetHz` off, the transmitter's clock `clockError` fast; `lead` seconds of silence before.
    static func burst(_ frames: [[UInt8]], rate: Double, amplitude: Double = 1, offsetHz: Double = 0, clockError: Double = 0,
                      phase: Double = 0, lead: Double = 0.004) -> [(Double, Double)] {
        var cumulative = 0
        let symbols = steps(VDL2Burst.bits(frames: frames)).map { step -> (Double, Double) in
            cumulative = (cumulative + step) & 7
            return (cos(Double.pi / 4 * Double(cumulative)), sin(Double.pi / 4 * Double(cumulative)))
        }
        let period = 1 / (VDL2Burst.symbolRate * (1 + clockError))
        let start = lead + 4 * period
        let count = Int((start + Double(symbols.count + 6) * period + lead) * rate)
        var out = [(Double, Double)](repeating: (0, 0), count: count)
        for (k, s) in symbols.enumerated() {
            let centre = start + Double(k) * period
            let ramp = k < 5 ? 0.5 - 0.5 * cos(Double.pi * Double(k + 1) / 6) : 1
            let lo = max(0, Int((centre - 8 * period) * rate)), hi = min(count, Int((centre + 8 * period) * rate) + 1)
            for n in lo..<hi {
                let p = amplitude * ramp * raisedCosine((Double(n) / rate - centre) / period)
                out[n].0 += p * s.0
                out[n].1 += p * s.1
            }
        }
        for n in out.indices {
            let w = 2 * Double.pi * offsetHz * Double(n) / rate + phase
            let (c, s) = (cos(w), sin(w))
            out[n] = (out[n].0 * c - out[n].1 * s, out[n].0 * s + out[n].1 * c)
        }
        return out
    }

    static let groundStation = AVLCAddress(address: 0x10_A5C3, type: 4)
    static let aircraft = AVLCAddress(address: 0xA2_3721, type: 1)

    /// ACARS in an AVLC information frame: FF FF 01, then the block from the mode character to DEL.
    static func acars(downlink: Bool, text: String) -> [UInt8] {
        let block = Array(ACARSFrameDecoder.frame(mode: "2", registration: downlink ? "G-ABCD" : "N123AB", label: downlink ? "Q0" : "H1",
                                                  blockID: downlink ? "4" : "C", messageNumber: downlink ? "M12A" : nil,
                                                  flightID: downlink ? "BA0123" : nil, text: text).dropFirst(21))
        return AVLCFrame.build(destination: downlink ? groundStation : aircraft, source: downlink ? aircraft : groundStation,
                               control: 0x22 | (downlink ? 0x10 : 0), info: [0xFF, 0xFF, 0x01] + block)
    }

    static func randomFrame(_ generator: inout Seeded, length: Int) -> [UInt8] {
        AVLCFrame.build(destination: aircraft, source: groundStation, control: 0x00,
                        info: (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
}

struct VDL2BurstTests {
    @Test func theHeaderCodeRepairsOneBit() throws {
        // A repaired header may not claim more than 0x1FFF bits (longer ones are taken for false starts).
        let longest = VDL2Burst.header(length: 0x3FFF)
        #expect(VDL2Burst.length(header: longest)?.bits == 0x3FFF && VDL2Burst.length(header: longest ^ 1 << 9) == nil)
        for length in [1, 175, 0x1234 & 0x1FFF, 0x1FFF] {
            let word = VDL2Burst.header(length: length)
            #expect(VDL2Burst.length(header: word).map { [$0.bits] } == [length])
            for bit in 0..<22 {
                let repaired = try #require(VDL2Burst.length(header: word ^ 1 << UInt32(bit)))
                #expect(repaired.bits == length && repaired.corrected)
            }
            // The reserved bits are zero by definition, whatever arrives.
            #expect(VDL2Burst.length(header: word | 0x1C0_0000).map { [$0.bits] } == [length])
        }
    }

    @Test func reliabilityLetsTheHeaderLoseTwoBits() throws {
        let word = VDL2Burst.header(length: 851)
        let damaged = word ^ 1 << 14 ^ 1 << 3                    // header bits 10 and 21
        var reliability = [Float](repeating: 1, count: 25)
        reliability[10] = 0.05
        reliability[21] = 0.1
        let repaired = try #require(VDL2Burst.length(header: damaged, reliability: reliability))
        #expect(repaired.bits == 851 && repaired.corrected)
        #expect(VDL2Burst.length(header: damaged)?.bits != 851)
    }

    @Test func theScramblerIsMaximalLength() {
        // x^15 + x + 1 is primitive: the sequence repeats after 2^15 − 1 bits and after none of its divisors.
        var scrambler = VDL2Burst.Scrambler()
        let sequence = (0..<(2 * 32_767)).map { _ in scrambler.next() }
        #expect(Array(sequence[0..<32_767]) == Array(sequence[32_767...]))
        for period in [7 * 31, 7 * 151, 31 * 151] {
            #expect(Array(sequence[0..<period]) != Array(sequence[period..<(2 * period)]))
        }
    }

    @Test func theLayoutFollowsTheBlockRules() {
        #expect(VDL2Burst.Layout(bits: 8 * 2).checkOctets == 0)               // under 3 octets: no check octets
        #expect(VDL2Burst.Layout(bits: 8 * 30).lastChecks == 2)
        #expect(VDL2Burst.Layout(bits: 8 * 67).lastChecks == 4)
        #expect(VDL2Burst.Layout(bits: 8 * 68).lastChecks == 6)
        let long = VDL2Burst.Layout(bits: 8 * 500 - 3)                       // 249 + 249 + 2
        #expect(long.blocks == 3 && long.lastBlock == 2 && long.checkOctets == 12)
    }

    @Test(arguments: [0, 20, 60, 120, 300, 700])
    func burstsGoAndComeBack(length: Int) throws {
        var generator = Seeded(state: UInt64(length + 1))
        let frames = [VDL2TestSignal.randomFrame(&generator, length: length), VDL2TestSignal.acars(downlink: true, text: "")]
        let decoder = VDL2BurstDecoder()
        var result: VDL2BurstDecoder.Result = .more
        for step in VDL2TestSignal.steps(VDL2Burst.bits(frames: frames)).dropFirst(21) {
            result = decoder.push(step: step)
            if case .more = result { continue }
            break
        }
        guard case .frames(let decoded, let corrected, let headerCorrected, _) = result else { Issue.record("no frames"); return }
        #expect(decoded == frames && corrected == 0 && !headerCorrected)
    }

    @Test func reedSolomonRepairsAndKnowsItsLimits() throws {
        var generator = Seeded(state: 3)
        let layout = VDL2Burst.Layout(bits: 8 * 600)                         // 249 + 249 + 102
        let data = (0..<layout.dataOctets).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let sent = VDL2Burst.interleave(data, layout: layout)
        // Octet i of the stream is in block i % 3 (while all three blocks still have data octets).
        func damage(_ indices: [Int]) -> [UInt8] {
            var octets = sent
            for i in indices { octets[i] ^= 0x5A }
            return octets
        }
        let three = [3, 30, 300]                                             // block 0, three octets
        #expect(VDL2Burst.deinterleave(damage(three), layout: layout).map { [$0.corrected] } == [3])
        #expect(VDL2Burst.deinterleave(damage(three), layout: layout)?.data == data)
        // Four are beyond the code alone (here it even settles on a wrong codeword, as it does about one time in six).
        let four = [0, 3, 30, 300]
        #expect(VDL2Burst.deinterleave(damage(four), layout: layout)?.data != data)
        // Told which octets are doubtful, the second, bold pass brings them back (erasures cost half what errors do).
        var reliability = [Float](repeating: 1, count: sent.count)
        for i in four { reliability[i] = 0.01 }
        #expect(VDL2Burst.deinterleave(damage(four), reliability: reliability, bold: true, layout: layout)?.data == data)
        let five = four + [600]
        for i in five { reliability[i] = 0.01 }
        #expect(VDL2Burst.deinterleave(damage(five), reliability: reliability, bold: true, layout: layout)?.data == data)
        // The short last block (102 octets, all six check octets) and one with four.
        #expect(VDL2Burst.deinterleave(damage([2, 5, 8]), layout: layout)?.data == data)
        let shorter = VDL2Burst.Layout(bits: 8 * 40)
        let small = Array(data.prefix(40))
        var octets = VDL2Burst.interleave(small, layout: shorter)
        octets[7] ^= 1
        octets[39] ^= 0x80
        #expect(shorter.lastChecks == 4 && VDL2Burst.deinterleave(octets, layout: shorter)?.data == small)
    }

    @Test func erasuresAndErrorsTogether() throws {
        let code = ReedSolomon(length: 255, parityCount: 6)
        var generator = Seeded(state: 9)
        let data = (0..<249).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let word = data + code.parity(for: data)
        for (erased, wrong) in [([10, 20, 30, 40, 50, 60], [Int]()), ([1, 2, 3, 4], [200]), ([250, 251], [5, 77])] {
            var received = word
            for i in erased + wrong { received[i] ^= 0xC3 }
            #expect(code.correct(&received, erasures: erased) == erased.count + wrong.count)
            #expect(received == word)
        }
        var received = word
        for i in [1, 2, 3, 4, 200] { received[i] ^= 0xC3 }
        #expect(code.correct(&received, erasures: [1, 2, 3, 4], maximumErrors: 0) == nil)
    }
}

struct AVLCTests {
    @Test func addressesCarryTypeAndStatus() {
        // dumpvdl2's test recording: these four octets are aircraft A23721 with the A/G bit set.
        let address = AVLCAddress(octets: [0xB2, 0x10, 0x76, 0x84])
        #expect(address.address == 0xA2_3721 && address.type == 1 && address.status && address.typeName == "Aircraft")
        #expect(address.octets() == [0xB2, 0x10, 0x76, 0x84])
        #expect(AVLCAddress(address: 0xFF_FFFF, type: 7, status: true).octets() == [0xFE, 0xFE, 0xFE, 0xFE])
    }

    @Test func acarsRidesInAnInformationFrame() throws {
        let frame = try #require(AVLCFrame(bytes: VDL2TestSignal.acars(downlink: true, text: "POS N51 W001")))
        #expect(frame.source == VDL2TestSignal.aircraft && frame.destination == VDL2TestSignal.groundStation)
        #expect(frame.kind == .information(send: 1, receive: 1, poll: true))
        let acars = try #require(frame.acars)
        #expect(acars.registration == "G-ABCD" && acars.flightID == "BA0123" && acars.messageNumber == "M12A")
        #expect(acars.label == "Q0" && acars.text == "POS N51 W001" && frame.acarsCRCValid)
        let json = frame.jsonObject()
        #expect((json["acars"] as? [String: Any])?["flight"] as? String == "BA0123" && json["frame_type"] as? String == "I")
        #expect((json["src"] as? [String: String])?["addr"] == "A23721")
        var damaged = VDL2TestSignal.acars(downlink: true, text: "POS N51 W001")
        damaged[20] ^= 4
        #expect(AVLCFrame(bytes: damaged) == nil)
    }

    @Test func aGroundStationAnnouncesItself() throws {
        let gs = VDL2TestSignal.groundStation
        let frequency: [UInt8] = [0x2E, 0x71] + gs.octets()                 // 136.975 MHz, VDL Mode 2
        let parameters: [UInt8] = [0x81, 1, 2] + [0xC1, 8] + Array("EGLLEGKK".utf8) + [0xC0, 6] + frequency
        let info: [UInt8] = [0x82, 0xF0, 0, UInt8(parameters.count)] + parameters
        let bytes = AVLCFrame.build(destination: AVLCAddress(address: 0xFF_FFFF, type: 7, status: true), source: gs,
                                    control: 0xAF, info: info)
        let frame = try #require(AVLCFrame(bytes: bytes))
        let xid = try #require(frame.xid)
        #expect(frame.typeName == "XID" && xid.name == "GSIF" && xid.airportCoverage == "EGLLEGKK")
        #expect(xid.frequencies == [VDL2XID.Frequency(megahertz: 136.975, groundStation: gs)])
    }

    @Test func anAircraftAsksForALinkAndSaysWhereItIs() throws {
        // 51.5° N, 0.5° W, FL370: latitude 515 and longitude −5 tenths in 12-bit fields.
        let lat = 515, lon = (-5) & 0xFFF
        let location: [UInt8] = [UInt8(lat >> 4), UInt8((lat & 0xF) << 4 | lon >> 8), UInt8(lon & 0xFF), 37]
        let parameters: [UInt8] = [0x01, 1, 0x00] + [0x83, 4] + Array("KJFK".utf8) + [0x84, 4] + location
        let info: [UInt8] = [0x82, 0xF0, 0, UInt8(parameters.count)] + parameters
        let bytes = AVLCFrame.build(destination: VDL2TestSignal.groundStation, source: VDL2TestSignal.aircraft, control: 0xBF, info: info)
        let xid = try #require(AVLCFrame(bytes: bytes)?.xid)
        #expect(xid.name == "XID_CMD_LE" && xid.destinationAirport == "KJFK")
        #expect(xid.latitude == 51.5 && xid.longitude == -0.5 && xid.altitudeFeet == 37_000)
    }

    @Test func supervisoryAndUnnumberedFrames() throws {
        let rr = try #require(AVLCFrame(bytes: AVLCFrame.build(destination: VDL2TestSignal.aircraft, source: VDL2TestSignal.groundStation, control: 0x01 | 5 << 5)))
        #expect(rr.typeName == "RR" && rr.kind == .supervisory(function: 0, receive: 5, pollFinal: false))
        let ua = try #require(AVLCFrame(bytes: AVLCFrame.build(destination: VDL2TestSignal.aircraft, source: VDL2TestSignal.groundStation, control: 0x73)))
        #expect(ua.typeName == "UA" && ua.kind == .unnumbered(function: 0x18, pollFinal: true))
    }
}

struct VDL2ReceptionTests {
    @Test func theDemodulatorFindsBurstsThroughNoiseAndAnOffset() {
        var generator = Seeded(state: 17)
        let first = [VDL2TestSignal.acars(downlink: false, text: "CLEARED TO LAND RWY 27R"), VDL2TestSignal.randomFrame(&generator, length: 150)]
        let second = [VDL2TestSignal.acars(downlink: true, text: String(repeating: "X", count: 180))]
        // 2.5 kHz off, the clock 40 ppm fast, about 14 dB Eb/N0.
        let signal = VDL2TestSignal.burst(first, rate: 42_000, amplitude: 0.3, offsetHz: 2_500, clockError: 40e-6, phase: 1)
            + VDL2TestSignal.burst(second, rate: 42_000, amplitude: 0.3, offsetHz: 2_500, clockError: 40e-6, phase: 2)
        var samples: [Float] = []
        for (i, q) in signal {
            samples.append(Float(i + 0.045 * generator.gaussian()))
            samples.append(Float(q + 0.045 * generator.gaussian()))
        }
        let demodulator = VDL2Demodulator()
        var bursts: [VDL2Demodulator.Burst] = []
        stride(from: 0, to: samples.count, by: 1_994).forEach { bursts += demodulator.process(Array(samples[$0..<min(samples.count, $0 + 1_994)])) }
        #expect(bursts.map(\.frames) == [first, second])
        #expect(bursts.allSatisfy { abs($0.frequencyOffsetHz - 2_500) < 20 })
    }

    @Test func twoChannelsFromOneCapture() throws {
        var generator = Seeded(state: 23)
        let rate = 1_050_000.0, center = 136_887_500.0, channels = [136_975_000.0, 136_875_000.0]
        let a = VDL2TestSignal.burst([VDL2TestSignal.acars(downlink: false, text: "QNH 1013")], rate: rate, amplitude: 40,
                                     offsetHz: channels[0] - center)
        let b = VDL2TestSignal.burst([VDL2TestSignal.acars(downlink: true, text: "")], rate: rate, amplitude: 40,
                                     offsetHz: channels[1] - center, phase: 1, lead: 0.006)
        let count = max(a.count, b.count)
        var iq = [UInt8](repeating: 0, count: 2 * count)
        for n in 0..<count {
            let i = (n < a.count ? a[n].0 : 0) + (n < b.count ? b[n].0 : 0)
            let q = (n < a.count ? a[n].1 : 0) + (n < b.count ? b[n].1 : 0)
            iq[2 * n] = UInt8(max(0, min(255, (127.5 + i + 3 * generator.gaussian()).rounded())))
            iq[2 * n + 1] = UInt8(max(0, min(255, (127.5 + q + 3 * generator.gaussian()).rounded())))
        }
        let receiver = VDL2Receiver(sampleRate: rate, centerHz: center, channels: channels)
        var receptions: [VDL2Receiver.Reception] = []
        stride(from: 0, to: iq.count, by: 131_071).forEach { receptions += receiver.process(iq: Array(iq[$0..<min(iq.count, $0 + 131_071)])) }
        let byChannel = Dictionary(grouping: receptions, by: \.channel).mapValues { $0.compactMap { $0.frame.acars?.registration } }
        #expect(byChannel[0] == ["N123AB"] && byChannel[1] == ["G-ABCD"])
        #expect(receiver.badFrames == 0)
    }

    @Test func noiseAloneGivesNothing() {
        var generator = Seeded(state: 29)
        let samples = (0..<(2 * 84_000)).map { _ in Float(0.05 * generator.gaussian()) }
        #expect(VDL2Demodulator().process(samples).isEmpty)
    }
}
