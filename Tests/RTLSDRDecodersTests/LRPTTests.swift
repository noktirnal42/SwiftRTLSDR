// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

/// LRPT as transmitted, for the tests: frames, channel bits, soft symbols and u8 I/Q.
enum LRPTTestSignal {
    /// `count` valid transfer frames (marker, VCDU header with counters from `counter`, random data, parity).
    static func frames(count: Int, counter: Int = 5_000, generator: inout Seeded) -> [[UInt8]] {
        (0..<count).map { index in
            var cadu = [UInt8](repeating: 0, count: LRPT.caduBytes)
            cadu[0...3] = [0x1a, 0xcf, 0xfc, 0x1d]
            let c = counter + index
            cadu[4...9] = [0x40, 0x05, UInt8(c >> 16 & 0xff), UInt8(c >> 8 & 0xff), UInt8(c & 0xff), 0]
            for position in 10..<(4 + 892) { cadu[position] = UInt8.random(in: 0...255, using: &generator) }
            LRPT.addParity(&cadu)
            return cadu
        }
    }

    /// The channel bits in transmission order: each frame randomised after its marker, the whole stream NRZ-M coded
    /// for offset QPSK, then convolutionally encoded (one encoder throughout).
    static func channelBits(_ cadus: [[UInt8]], mode: LRPT.Mode) -> [UInt8] {
        var encoder = ConvolutionalEncoder()
        var previous: UInt8 = 0
        var bits: [UInt8] = []
        for cadu in cadus {
            var sent = cadu
            LRPT.derandomize(&sent)                    // XORing the pseudo-noise randomises as well
            for byte in sent {
                for shift in (0..<8).reversed() {
                    var bit = byte >> UInt8(shift) & 1
                    if mode.isDifferential { previous ^= bit; bit = previous }
                    let (first, second) = encoder.encode(bit)
                    bits += [first, second]
                }
            }
        }
        return bits
    }

    /// Soft symbols for channel bits (negative = 1), with Gaussian noise.
    static func soft(_ bits: [UInt8], amplitude: Double = 80, noise: Double = 30, generator: inout Seeded) -> [Int8] {
        bits.map { bit in
            let value = (bit == 1 ? -amplitude : amplitude) + noise * generator.gaussian()
            return Int8(max(-127, min(127, value.rounded())))
        }
    }

    static func randomSoft(_ count: Int, generator: inout Seeded) -> [Int8] {
        (0..<count).map { _ in Int8(max(-127, min(127, (60 * generator.gaussian()).rounded()))) }
    }

    /// What a carrier loop settled in another phase gives: the (I, Q) pairs mirrored (Q negated), then rotated by
    /// `rotation` quarter turns.
    static func transform(_ soft: [Int8], rotation: Int, mirrored: Bool) -> [Int8] {
        var out = soft
        var k = 0
        while k + 1 < soft.count {
            var i = Int(soft[k]), q = Int(soft[k + 1])
            if mirrored { q = -q }
            for _ in 0..<rotation { (i, q) = (-q, i) }
            out[k] = Int8(i); out[k + 1] = Int8(q)
            k += 2
        }
        return out
    }
}

/// Renders channel bits as QPSK or offset QPSK at 4 samples a symbol: root-raised-cosine pulses (the textbook formula,
/// roll-off 0.6), a carrier offset, noise, u8 I/Q.
struct LRPTModulator {
    var sampleRate = 288_000.0
    var carrierHz = -1500.0
    var amplitude = 40.0
    var noise = 10.0
    var offset = true
    var generator = Seeded(state: 137)

    static let samplesPerSymbol = 4
    static let span = 8                                // symbols either side

    static let pulse: [Double] = {
        let alpha = 0.6
        return (-span * samplesPerSymbol...span * samplesPerSymbol).map { n in
            let t = Double(n) / Double(samplesPerSymbol)
            if t == 0 { return 1 - alpha + 4 * alpha / .pi }
            let numerator = sin(.pi * t * (1 - alpha)) + 4 * alpha * t * cos(.pi * t * (1 + alpha))
            return numerator / (.pi * t * (1 - (4 * alpha * t) * (4 * alpha * t)))
        }
    }()

    mutating func iq(_ bits: [UInt8]) -> [UInt8] {
        let sps = Self.samplesPerSymbol, half = Self.span * sps
        let symbols = bits.count / 2
        let delay = offset ? sps / 2 : 0               // OQPSK: Q half a symbol late
        let count = (symbols + 2 * Self.span) * sps
        var i = [Double](repeating: 0, count: count), q = [Double](repeating: 0, count: count)
        for k in 0..<symbols {
            let centre = (k + Self.span) * sps
            let a = bits[2 * k] == 1 ? -1.0 : 1.0, b = bits[2 * k + 1] == 1 ? -1.0 : 1.0
            for (tap, h) in Self.pulse.enumerated() {
                let n = centre - half + tap
                i[n] += a * h
                if n + delay < count { q[n + delay] += b * h }
            }
        }
        var out = [UInt8](repeating: 0, count: 2 * count)
        let phase0 = Double.random(in: 0..<(2 * .pi), using: &generator)
        for n in 0..<count {
            let phase = phase0 + 2 * .pi * carrierHz * Double(n) / sampleRate
            let (c, s) = (cos(phase), sin(phase))
            let re = amplitude * (i[n] * c - q[n] * s) + noise * generator.gaussian()
            let im = amplitude * (i[n] * s + q[n] * c) + noise * generator.gaussian()
            out[2 * n] = UInt8(max(0, min(255, (127.5 + re).rounded())))
            out[2 * n + 1] = UInt8(max(0, min(255, (127.5 + im).rounded())))
        }
        return out
    }
}

struct LRPTCodingTests {
    @Test func pseudoNoiseIsTheCCSDSSequence() {
        #expect(Array(LRPT.pseudoNoise.prefix(8)) == [0xff, 0x48, 0x0e, 0xc0, 0x9a, 0x0d, 0x70, 0xbc])
    }

    /// Parity from reedsolo 1.7 (`RSCodec(32, 255, fcr=112, prim=0x187, generator=173)`) for bytes (37·i + 11) mod 256.
    @Test func reedSolomonParityMatchesReedsolo() {
        let data = (0..<223).map { UInt8((37 * $0 + 11) & 0xff) }
        #expect(LRPT.reedSolomon.parity(for: data) == bytes(hex: "ad18123772cac8e0a81458b1cdbe0c41ba95e23e5431bdc3f158135bb1d778aa"))
    }

    @Test func sixteenSymbolErrorsAreRepaired() {
        var generator = Seeded(state: 16)
        let data = (0..<223).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let clean = data + LRPT.reedSolomon.parity(for: data)
        var damaged = clean
        for position in Array(0..<255).shuffled(using: &generator).prefix(16) { damaged[position] ^= UInt8.random(in: 1...255, using: &generator) }
        #expect(LRPT.reedSolomon.correct(&damaged) == 16)
        #expect(damaged == clean)
    }

    @Test func framesRoundTripThroughTheCodes() {
        var generator = Seeded(state: 1)
        var cadu = LRPTTestSignal.frames(count: 1, generator: &generator)[0]
        let clean = cadu
        LRPT.derandomize(&cadu)
        #expect(cadu != clean)
        LRPT.derandomize(&cadu)
        #expect(LRPT.correct(&cadu) == 0)
        #expect(cadu == clean)
    }
}

struct LRPTFrameDecoderTests {
    /// Decodes a symbol stream in uneven pieces, as a live source would deliver it.
    private func decode(_ soft: [Int8], mode: LRPT.Mode) -> [LRPTFrame] {
        let decoder = LRPTFrameDecoder(mode: mode)
        var frames: [LRPTFrame] = []
        var index = 0, piece = 3_000
        while index < soft.count {
            let end = min(soft.count, index + piece)
            frames += decoder.process(Array(soft[index..<end]))
            index = end
            piece = piece * 7 % 20_011 + 1_000
        }
        return frames + decoder.flush()
    }

    @Test(arguments: LRPT.Mode.allCases, [false, true])
    func framesAreFoundInEveryPhase(mode: LRPT.Mode, mirrored: Bool) {
        for rotation in 0..<4 {
            var generator = Seeded(state: UInt64(10 + rotation))
            let cadus = LRPTTestSignal.frames(count: 4, generator: &generator)
            let signal = LRPTTestSignal.soft(LRPTTestSignal.channelBits(cadus, mode: mode), generator: &generator)
            let lead = LRPTTestSignal.randomSoft(3_001, generator: &generator)     // odd: the marker off the pairs
            let frames = decode(lead + LRPTTestSignal.transform(signal, rotation: rotation, mirrored: mirrored), mode: mode)
            #expect(frames.map(\.bytes) == cadus, "\(mode) rotation \(rotation) mirrored \(mirrored)")
        }
    }

    /// An offset-QPSK carrier loop slipping by a quarter turn moves the symbol pairing by one soft symbol and mirrors
    /// the constellation. The NRZ-M marker one soft symbol away still agrees with some phase in over 42 of 64 bits,
    /// which is where meteor_decode would stop looking: the frames after the slip must still be found.
    @Test func framesAfterAnOffsetQPSKCarrierSlipAreFound() {
        var generator = Seeded(state: 77)
        let cadus = LRPTTestSignal.frames(count: 6, generator: &generator)
        let soft = LRPTTestSignal.soft(LRPTTestSignal.channelBits(cadus, mode: .oqpskNRZM), generator: &generator)
        let slip = 2 * LRPT.caduSoftSymbols + 5_000                     // in the middle of the third frame
        let after = LRPTTestSignal.transform([0] + Array(soft[slip...]), rotation: 0, mirrored: true)
        let frames = decode(Array(soft[..<slip]) + after, mode: .oqpskNRZM)
        let valid = frames.filter(\.isValid).map(\.bytes)
        #expect(valid == cadus.enumerated().filter { $0.offset != 2 }.map(\.element))
        #expect(frames.map(\.markerOffset) == [0, 0, 0, 1, 0, 0])      // found one symbol late, once
    }

    @Test func noiseAloneGivesNoValidFrames() {
        var generator = Seeded(state: 5)
        let frames = decode(LRPTTestSignal.randomSoft(5 * LRPT.caduSoftSymbols, generator: &generator), mode: .qpsk)
        #expect(!frames.isEmpty && frames.allSatisfy { !$0.isValid })
    }
}

struct LRPTDemodulatorTests {
    /// About a second of signal: the carrier search needs its first 0.11 s, the loops a little more.
    private func signal(offset: Bool, carrierHz: Double, count: Int = 9) -> (iq: [UInt8], cadus: [[UInt8]]) {
        var generator = Seeded(state: 21)
        let cadus = LRPTTestSignal.frames(count: count, generator: &generator)
        var modulator = LRPTModulator(carrierHz: carrierHz, offset: offset)
        return (modulator.iq(LRPTTestSignal.channelBits(cadus, mode: offset ? .oqpskNRZM : .qpsk)), cadus)
    }

    @Test(arguments: [(true, -1500.0), (true, 0.0), (false, 2200.0)])
    func framesAreDemodulatedAndDecoded(offset: Bool, carrierHz: Double) {
        let (iq, cadus) = signal(offset: offset, carrierHz: carrierHz)
        let demodulator = LRPTDemodulator(sampleRate: 288_000, offset: offset)
        let decoder = LRPTFrameDecoder(mode: offset ? .oqpskNRZM : .qpsk)
        var frames: [LRPTFrame] = []
        var index = 0
        while index < iq.count {
            let end = min(iq.count, index + 65_536)
            frames += decoder.process(demodulator.process(Array(iq[index..<end])))
            index = end
        }
        frames += decoder.flush()
        let valid = Set(frames.filter(\.isValid).map(\.bytes))
        let status = demodulator.status
        // Everything after acquisition (well under 0.3 s: 3 frames) but the last, whose final symbols are still in
        // the filters when the signal ends.
        let decoded = cadus.indices.filter { valid.contains(cadus[$0]) }
        #expect(cadus[3..<(cadus.count - 1)].allSatisfy { valid.contains($0) }, "frames decoded: \(decoded)")
        #expect(status.locked)
        #expect(abs(status.carrierOffsetHz - carrierHz) < 20)
        #expect(abs((status.coarseCarrierHz ?? .infinity) - carrierHz) < 10)
        #expect(status.snrDB > 8)
        #expect(demodulator.recentSymbols.count == 512)
    }

    @Test func coarseSearchFindsTheCarrier() {
        let (iq, _) = signal(offset: true, carrierHz: -2345, count: 5)
        var search = LRPTCarrierSearch(sampleRate: 288_000, maximumHz: 3_400)
        var estimates: [LRPTCarrierSearch.Estimate] = []
        for n in 0..<(iq.count / 2) {
            if let estimate = search.push(Float(Int(iq[2 * n]) - 128), Float(Int(iq[2 * n + 1]) - 128)) { estimates.append(estimate) }
        }
        #expect(estimates.count == 5)                  // one a transform: the line is clear at once
        #expect(estimates.allSatisfy { abs($0.hz + 2345) < 5 && $0.strengthDB > 20 && !$0.isTone })
    }

    @Test func toneIsNotTakenForACarrier() {
        var generator = Seeded(state: 3)
        var search = LRPTCarrierSearch(sampleRate: 288_000, maximumHz: 3_400)
        var estimates: [LRPTCarrierSearch.Estimate] = []
        for n in 0..<150_000 {
            let phase = 2 * Double.pi * 1234 * Double(n) / 288_000
            let i = 20 * cos(phase) + 10 * generator.gaussian(), q = 20 * sin(phase) + 10 * generator.gaussian()
            if let estimate = search.push(Float(i), Float(q)) { estimates.append(estimate) }
        }
        #expect(!estimates.isEmpty)
        #expect(estimates.allSatisfy { abs($0.hz - 1234) < 5 && $0.isTone })
    }

    @Test func noiseGivesNoUsableEstimate() {
        var generator = Seeded(state: 4)
        var search = LRPTCarrierSearch(sampleRate: 288_000, maximumHz: 3_400)
        var estimates: [LRPTCarrierSearch.Estimate] = []
        for _ in 0..<300_000 {
            if let estimate = search.push(Float(10 * generator.gaussian()), Float(10 * generator.gaussian())) { estimates.append(estimate) }
        }
        #expect(estimates.count == 2)
        #expect(estimates.allSatisfy { $0.strengthDB < 9 })
    }
}

struct MSUMRTests {
    /// Six frames made by `Tools/lrpt-encode.py --lines 16 --seed 21` (a synthetic scene, compressed independently of
    /// this package), decoded from ideal soft symbols through the whole chain; the images are compared with the
    /// statistics of the source images' 8×8 blocks. The compression is lossy, so means must agree closely and the
    /// spread of each block roughly.
    @Test func imagesMatchTheSourceScene() throws {
        let url = try #require(Bundle.module.url(forResource: "lrpt-scene", withExtension: "cadu", subdirectory: "Resources"))
        let file = [UInt8](try Data(contentsOf: url))
        let cadus = stride(from: 0, to: file.count, by: LRPT.caduBytes).map { Array(file[$0..<($0 + LRPT.caduBytes)]) }
        var generator = Seeded(state: 9)
        let decoder = LRPTDecoder(mode: .qpsk)
        decoder.process(soft: LRPTTestSignal.soft(LRPTTestSignal.channelBits(cadus, mode: .qpsk), noise: 0, generator: &generator))
        decoder.flush()
        #expect(decoder.statistics.validFrames == 6)
        #expect(decoder.statistics.packetsPerAPID[64] == 28 && decoder.statistics.packetsPerAPID[65] == 28)
        #expect(decoder.statistics.packetsPerAPID[66] == 28 && decoder.statistics.packetsPerAPID[70] == 2)

        var statistics: [String: [Double]] = [:]
        for line in try resourceText("lrpt-scene-blocks").split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: " ")
            statistics[fields[0...2].joined(separator: " ")] = fields.dropFirst(3).map { Double($0)! }
        }
        var worstMean = 0.0, worstDeviation = 0.0
        for apid in [64, 65, 66] {
            let image = try #require(decoder.imager.image(apid: apid))
            #expect(image.width == 1568 && image.height == 16)
            for strip in 0..<2 {
                let means = try #require(statistics["mean \(apid) \(strip)"]), deviations = try #require(statistics["deviation \(apid) \(strip)"])
                for block in 0..<196 {
                    var values: [Double] = []
                    for y in 0..<8 { for x in 0..<8 { values.append(Double(image.pixels[(strip * 8 + y) * 1568 + block * 8 + x])) } }
                    let mean = values.reduce(0, +) / 64
                    let deviation = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 64).squareRoot()
                    worstMean = max(worstMean, abs(mean - means[block]))
                    worstDeviation = max(worstDeviation, abs(deviation - deviations[block]) - 0.25 * deviations[block])
                }
            }
        }
        // Quantising the mean costs up to about half a grey level, and the fixed-point IDCT (meteor_decode's, kept so
        // that images match its own) comes out a level low on some flat blocks.
        #expect(worstMean < 2, "block means off by up to \(worstMean)")
        #expect(worstDeviation < 2, "block deviations off by up to \(worstDeviation) beyond a quarter")
    }
}

struct LRPTDeinterleaverTests {
    /// The 80k mode's interleaver, written from its description: soft sample n of the channel stream goes out at
    /// n + (n mod 36) × 36 × `delay` (branch n mod 36 delays it that much), random samples fill what the branches hold
    /// before and after, and every 72 samples follow the marker 0x27 (as soft samples, 1 negative).
    static func interleave(_ soft: [Int8], delay: Int, generator: inout Seeded) -> [Int8] {
        let step = 36 * delay
        var total = soft.count + 35 * step
        total += (72 - total % 72) % 72
        let marker: [Int8] = [100, 100, -100, 100, 100, -100, -100, -100]
        var out: [Int8] = []
        out.reserveCapacity(total / 72 * 80)
        for n in 0..<total {
            if n % 72 == 0 { out += marker }
            let source = n - (n % 36) * step
            out.append(source >= 0 && source < soft.count ? soft[source] : Int8.random(in: -100...100, using: &generator))
        }
        return out
    }

    /// Feeds `stream` in uneven pieces, then flushes.
    static func deinterleave(_ stream: [Int8], _ deinterleaver: LRPTDeinterleaver) -> [Int8] {
        var output: [Int8] = []
        var index = 0, piece = 1_001
        while index < stream.count {
            let end = min(stream.count, index + piece)
            output += deinterleaver.process(Array(stream[index..<end]))
            index = end
            piece = piece * 7 % 9_973 + 500
        }
        return output + deinterleaver.flush()
    }

    /// Where `original` sits in `output` (acquisition starts at a marker the deinterleaver chooses), and how much of
    /// `original[range]` matches there.
    static func agreement(_ output: [Int8], _ original: [Int8], range: Range<Int>) -> Double {
        let probe = Array(original[(range.lowerBound + 1_000)..<(range.lowerBound + 1_400)])
        var bestShift = 0, bestCount = -1
        for shift in stride(from: 0, through: output.count - range.upperBound, by: 1) {
            var count = 0
            for k in 0..<probe.count where output[shift + range.lowerBound + 1_000 + k] == probe[k] { count += 1 }
            if count > bestCount { bestCount = count; bestShift = shift }
            if count == probe.count { break }
        }
        let matches = range.filter { output[bestShift + $0] == original[$0] }.count
        return Double(matches) / Double(range.count)
    }

    private static let delay = 4                       // latency 35 × 144 samples instead of 35 × 73 728

    @Test func samplesComeOutInOrderInEveryRotation() {
        for t in 0..<8 {
            var generator = Seeded(state: UInt64(100 + t))
            let original = LRPTTestSignal.randomSoft(72 * 600, generator: &generator)
            var stream = Self.interleave(original, delay: Self.delay, generator: &generator)
            var k = 0
            while k + 1 < stream.count {                // the demodulator settled in transform t
                let (x, y) = LRPTDeinterleaver.apply(t, Int(max(-127, stream[k])), Int(max(-127, stream[k + 1])))
                stream[k] = Int8(x); stream[k + 1] = Int8(y)
                k += 2
            }
            let lead = LRPTTestSignal.randomSoft(t % 2 == 0 ? 1_001 : 1_000, generator: &generator)
            let output = Self.deinterleave(lead + stream, LRPTDeinterleaver(branchDelay: Self.delay))
            #expect(Self.agreement(output, original.map { max(-127, $0) }, range: 0..<original.count) == 1, "transform \(t)")
        }
    }

    /// A carrier loop slipping by half a turn looks, at the marker, almost like a quarter turn and one sample (7 of 8
    /// samples agree); an offset-QPSK quarter turn really does move the pairs a sample. Both must be followed, and a
    /// symbol dropped or doubled by the clock too: past each event the output is exact again.
    @Test func phaseJumpsAndSymbolSlipsAreFollowed() {
        var generator = Seeded(state: 7)
        let original = LRPTTestSignal.randomSoft(72 * 2_000, generator: &generator).map { max(-127, $0) }
        let stream = Self.interleave(original, delay: Self.delay, generator: &generator)
        func turned(_ part: ArraySlice<Int8>, _ t: Int) -> [Int8] {
            var out = Array(part)
            var k = 0
            while k + 1 < out.count {
                let (x, y) = LRPTDeinterleaver.apply(t, Int(out[k]), Int(out[k + 1]))
                out[k] = Int8(x); out[k + 1] = Int8(y)
                k += 2
            }
            return out
        }
        let a = 30_000, b = 60_000, c = 90_000, d = 120_000
        var received = Array(stream[..<a])
        received += turned(stream[a..<b], 2)                               // half a turn
        received += turned([0] + stream[b..<c], 4)                          // OQPSK quarter turn: a sample on, mirrored
        received += turned(stream[(c + 2)..<d], 4)                          // a symbol lost
        received += turned(stream[d..<(d + 2)] + stream[d...], 4)           // a symbol doubled
        let deinterleaver = LRPTDeinterleaver(branchDelay: Self.delay)
        let output = Self.deinterleave(received, deinterleaver)
        // The last stretch, past the reach of the last event (its data index plus the latency and two windows), is
        // exact.
        let tail = (original.count - 18_000)..<(original.count - 1_000)
        #expect(Self.agreement(output, original, range: tail) == 1)
        #expect(deinterleaver.resynchronisations >= 4)
    }

    @Test func framesThroughInterleaverDeinterleaverAndDecoder() {
        // Six noisy frames; the demodulator settled a quarter turn off (offset QPSK: a sample on, mirrored). The
        // satellites' 2048 cells a branch (18 s) are checked against SatDump with real frames (DECODERS.md); 16 keep
        // this test fast.
        var generator = Seeded(state: 3)
        let cadus = LRPTTestSignal.frames(count: 6, generator: &generator)
        let soft = LRPTTestSignal.soft(LRPTTestSignal.channelBits(cadus, mode: .oqpskNRZM), generator: &generator)
        let stream = Self.interleave(soft, delay: 16, generator: &generator)
        let mirrored = LRPTTestSignal.transform([0] + stream, rotation: 2, mirrored: true)
        let deinterleaver = LRPTDeinterleaver(branchDelay: 16)
        let decoder = LRPTDecoder(mode: .oqpskNRZM)
        var index = 0
        while index < mirrored.count {
            let end = min(mirrored.count, index + 65_536)
            decoder.process(soft: deinterleaver.process(Array(mirrored[index..<end])))
            index = end
        }
        decoder.process(soft: deinterleaver.flush())
        decoder.flush()
        #expect(decoder.statistics.validFrames == 6)
        #expect(LRPTDeinterleaver().latency == 2_580_480)
    }
}
