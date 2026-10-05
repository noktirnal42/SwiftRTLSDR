// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

/// Continuous-phase FSK as UAT sends it: modulation index 0.6, so the phase moves ±0.6π per bit (±0.3π per sample at two
/// samples per bit). Optional frequency offset, noise and a fractional-sample timing shift.
struct UATModulator {
    var amplitude = 50.0
    var noise = 3.0
    var offsetHz = 0.0
    var timing = 0.0                    // 0 ..< 1 of a sample: where within each bit the samples fall
    var flippedBits: Set<Int> = []      // frame bits to invert (after the sync word), to test the error correction
    var seed: UInt64 = 1

    func bits(for frame: UATFrame) -> [Bool] {
        let sync = frame.kind == .downlink ? UAT.downlinkSync : UAT.uplinkSync
        let sent = UAT.encode(frame.payload, kind: frame.kind)
        var bits = (0..<36).map { sync & (1 << UInt64(35 - $0)) != 0 }
        for (index, byte) in sent.enumerated() {
            for bit in 0..<8 { bits.append(((byte >> UInt8(7 - bit)) & 1 == 1) != flippedBits.contains(index * 8 + bit)) }
        }
        return bits
    }

    /// `frames` placed at the given sample positions in `samples` samples of noise.
    func iq(_ frames: [(UATFrame, Int)], samples: Int) -> [UInt8] {
        var generator = Seeded(state: seed)
        var i = (0..<samples).map { _ in noise * generator.gaussian() }
        var q = (0..<samples).map { _ in noise * generator.gaussian() }
        let rate = Double(UAT.sampleRate)
        for (frame, start) in frames {
            let bits = bits(for: frame)
            var phase = Double.random(in: 0..<(2 * .pi), using: &generator)
            let count = bits.count * 2
            for n in 0..<count where start + n < samples {
                // The phase ramps linearly through each bit; sample n sits `timing` of a sample into its slot.
                let t = Double(n) + timing
                let bit = min(bits.count - 1, Int(t / 2))
                let step = (bits[bit] ? 1.0 : -1.0) * 0.3 * .pi
                phase += step * (n == 0 ? timing : 1)
                let carrier = phase + 2 * .pi * offsetHz * Double(n) / rate
                i[start + n] += amplitude * cos(carrier)
                q[start + n] += amplitude * sin(carrier)
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

struct UATDemodulatorTests {
    @Test func realFramesSurviveModulationAndDemodulation() throws {
        let frames = try sampleFrames()
        // A long uplink needs 8904 samples; leave room for the demodulator's look-ahead at the end.
        var placed: [(UATFrame, Int)] = []
        var position = 1_000
        for frame in frames.prefix(60) {
            placed.append((frame, position))
            position += (frame.kind == .uplink ? 9_000 : 1_000) + 137
        }
        var modulator = UATModulator()
        modulator.offsetHz = 20_000
        let iq = modulator.iq(placed, samples: position + 10_000)
        let found = UATDemodulator().process(iq)
        #expect(found.map(\.payload) == placed.map(\.0.payload))
        #expect(found.map(\.kind) == placed.map(\.0.kind))
        #expect(zip(found, placed).allSatisfy { abs(($0.sampleIndex ?? 0) - $1.1) <= 1 })
    }

    @Test func framesStraddlingBlockBoundariesAreFound() throws {
        let frames = Array(try sampleFrames().prefix(12))
        var placed: [(UATFrame, Int)] = []
        var position = 500
        for frame in frames { placed.append((frame, position)); position += (frame.kind == .uplink ? 9_000 : 1_000) + 311 }
        let iq = UATModulator().iq(placed, samples: position + 10_000)
        let demodulator = UATDemodulator()
        var found: [UATFrame] = []
        var generator = Seeded(state: 3)
        var offset = 0
        while offset < iq.count {
            let length = min(iq.count - offset, 2 * Int.random(in: 100...6_000, using: &generator))
            found += demodulator.process(Array(iq[offset..<offset + length]))
            offset += length
        }
        found += demodulator.process([UInt8](repeating: 128, count: 2 * 10_000))       // flush the look-ahead
        #expect(found.map(\.payload) == frames.map(\.payload))
    }

    @Test(arguments: [0.0, 0.25, 0.5, 0.75])
    func anyTimingWithinTheBitIsFine(timing: Double) throws {
        let frames = Array(try sampleFrames().prefix(6))
        var placed: [(UATFrame, Int)] = []
        var position = 700
        for frame in frames { placed.append((frame, position)); position += (frame.kind == .uplink ? 9_000 : 1_000) + 50 }
        var modulator = UATModulator()
        modulator.timing = timing
        let found = UATDemodulator().process(modulator.iq(placed, samples: position + 10_000))
        #expect(found.map(\.payload) == frames.map(\.payload))
    }

    @Test func damagedBitsAreRepairedAndCounted() throws {
        let downlink = try #require(try sampleFrames().first { $0.kind == .downlink && $0.payload.count == UAT.longPayloadBytes })
        var modulator = UATModulator()
        modulator.flippedBits = [3, 77, 150, 200, 301]                   // five bad bytes: within the 7 a long frame allows
        let found = UATDemodulator().process(modulator.iq([(downlink, 800)], samples: 12_000))
        #expect(found.count == 1 && found.first?.payload == downlink.payload && found.first?.correctedSymbols == 5)
        modulator.flippedBits = Set(stride(from: 5, to: 384, by: 40))     // ten bad bytes: beyond repair
        #expect(UATDemodulator().process(modulator.iq([(downlink, 800)], samples: 12_000)).isEmpty)
    }

    @Test func noiseAloneProducesNoFrames() {
        var modulator = UATModulator()
        modulator.noise = 20
        #expect(UATDemodulator().process(modulator.iq([], samples: 2_000_000)).isEmpty)
    }

    @Test func dump978TextRoundTrips() throws {
        for line in try resourceText("dump978-sample-data").split(separator: "\n").prefix(50) {
            let frame = try #require(UATFrame(dump978Line: line))
            #expect(frame.dump978Line == String(line))
        }
        #expect(UATFrame(dump978Line: "-00a6;") == nil, "wrong length")
        #expect(UATFrame(dump978Line: "*8D4840D6202CC371C32CE0576098;") == nil, "a Mode S line")
    }
}
