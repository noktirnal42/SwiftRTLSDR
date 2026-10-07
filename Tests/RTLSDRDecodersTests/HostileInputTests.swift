import Foundation
import Testing
@testable import RTLSDRDecoders

/// The receivers are fed whatever is on the air: noise, other systems, a dongle gone wrong. No input may crash them, and a
/// frame that passes a checksum by chance must not become a report with an impossible position or date.
struct HostileInputTests {
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return state >> 11 }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
        mutating func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8(truncatingIfNeeded: next()) } }
        mutating func floats(_ n: Int) -> [Float] {
            (0..<n).map { _ in
                switch int(40) {
                case 0: return .nan
                case 1: return .infinity
                case 2: return -.infinity
                case 3: return 1e30
                case 4: return -1e30
                default: return Float(Double(next() % 2001) / 1000 - 1) * 4
                }
            }
        }
    }

    /// 280 soft bits for a frame made of the given nibbles (valid Hamming codewords, interleaved like the real thing).
    static func dfmSoft(config: [Int], data1: [Int], data2: [Int], flips: Int, rng: inout Rng) -> [Float] {
        var soft = [Float](repeating: -1, count: DFM.frameBits)
        for k in 0..<DFM.headerBits { soft[k] = ((DFM.headerWord >> (DFM.headerBits - 1 - k)) & 1) == 1 ? 1 : -1 }
        func place(_ nibbles: [Int], at start: Int) {
            let count = nibbles.count
            for (i, nibble) in nibbles.enumerated() {
                let word = DFM.codewords[nibble & 15]
                for j in 0..<8 { soft[start + count * j + i] = (word >> UInt8(7 - j)) & 1 == 1 ? 1 : -1 }
            }
        }
        place(config, at: DFM.headerBits)
        place(data1, at: DFM.headerBits + 8 * DFM.configCodewords)
        place(data2, at: DFM.headerBits + 8 * DFM.configCodewords + 8 * DFM.dataCodewords)
        for _ in 0..<flips { let k = DFM.headerBits + rng.int(DFM.frameBits - DFM.headerBits); soft[k] = -soft[k] }
        return soft
    }

    @Test func dfmDecoderSurvivesValidCodewordsOfRandomData() throws {
        var rng = Rng(state: 7)
        let decoder = DFMDecoder()
        var reports = 0, outOfRange = 0
        var counter = 0.0
        for n in 0..<8_000 {
            let nibbles = { (c: Int) in (0..<c).map { _ in rng.int(16) } }
            let soft = Self.dfmSoft(config: nibbles(7), data1: nibbles(13), data2: nibbles(13), flips: rng.int(4), rng: &rng)
            for repair in [false, true] {
                let frame = try DFMFrame(soft: soft, repairTwoBitErrors: repair)
                counter = [counter + 1, Double.nan, .infinity, -1, 1e12, Double(n)][rng.int(6)]
                if let report = decoder.ingest(frame, frameCount: counter) {
                    reports += 1
                    if !(report.latitude.isFinite && abs(report.latitude) <= 90 && report.longitude.isFinite && abs(report.longitude) <= 180
                         && (1...12).contains(report.month) && (1...31).contains(report.day)) { outOfRange += 1 }
                    _ = report.json(frequencyKHz: 403_000); _ = report.line; _ = report.isoTime
                }
            }
        }
        print("HOSTILE DFM random-valid-codeword frames: \(reports) reports, \(outOfRange) implausible")
        #expect(outOfRange == 0, "reports with an impossible position or date were returned")
    }

    @Test func dfmFrameAcceptsAnySoftValues() throws {
        var rng = Rng(state: 11)
        for _ in 0..<5_000 {
            let soft = rng.floats(DFM.frameBits)
            for repair in [false, true] { let frame = try DFMFrame(soft: soft, repairTwoBitErrors: repair); _ = frame.intactBlocks }
        }
    }

    @Test func syncsSurviveGarbageSamples() {
        var rng = Rng(state: 13)
        for rate in [8_000.0, 12_500.0, 48_000.0, 96_000.0, 250_000.0] {
            let dfmF = DFMFrameSync(sampleRate: rate), dfmT = DFMFrameSync(sampleRate: rate, input: .tones)
            let m10F = M10FrameSync(sampleRate: rate), m10T = M10FrameSync(sampleRate: rate, input: .tones)
            let rs41 = RS41FrameSync(sampleRate: rate)
            for _ in 0..<30 {
                let n = [0, 1, 7, 100, 4_000, 50_000][rng.int(6)]
                let values = rng.floats(n)
                _ = dfmF.process(values); _ = m10F.process(values); _ = rs41.process(values)
                _ = dfmT.process(values, frequency: rng.floats(n)); _ = m10T.process(values, frequency: rng.floats(n))
            }
        }
    }

    @Test func m10DecoderSurvivesForgedFramesWithValidChecksums() {
        var rng = Rng(state: 17)
        let decoder = M10Decoder()
        let kinds: [UInt8] = [0x9f, 0x8f, 0xaf, 0x20, 0x49, 0x00, 0xff]
        var reports = 0, outOfRange = 0
        for _ in 0..<25_000 {
            let length = [4, 5, 0x45, 0x64, 0x64 + rng.int(0x41), rng.int(256)][rng.int(6)]
            var body = rng.bytes(length + 1)
            guard body.count >= 2 else { continue }
            body[0] = UInt8(truncatingIfNeeded: length)
            body[1] = kinds[rng.int(kinds.count)]
            guard let draft = M10Frame(bytes: body) else { continue }
            let checksum = draft.computedChecksum
            var forged = draft.bytes
            forged[draft.length - 1] = UInt8(truncatingIfNeeded: checksum >> 8)
            forged[draft.length] = UInt8(truncatingIfNeeded: checksum)
            guard let frame = M10Frame(bytes: forged) else { continue }
            if let report = decoder.report(frame) {
                reports += 1
                if !(report.latitude.isFinite && abs(report.latitude) <= 90 && report.longitude.isFinite && abs(report.longitude) <= 180) { outOfRange += 1 }
                _ = report.json(frequencyKHz: 403_000); _ = report.line; _ = report.isoTime
            }
        }
        print("HOSTILE M10 forged-checksum frames: \(reports) reports, \(outOfRange) with an impossible position")
        #expect(outOfRange == 0, "reports with an impossible position were returned")
    }

    @Test func iqReceiversSurviveNoiseAtAnyBlockSize() {
        var rng = Rng(state: 19)
        for rate in [240_000.0, 1_024_000.0, 2_048_000.0, 2_400_000.0, 3_200_000.0] {
            let dfm = DFMReceiver(sampleRate: rate), dfmDisc = DFMReceiver(sampleRate: rate, useTones: false)
            let m10 = M10Receiver(sampleRate: rate), rs41 = RS41Receiver(sampleRate: rate)
            for _ in 0..<12 {
                let n = [0, 1, 2, 3, 999, 20_000, 200_000][rng.int(7)]
                let block: [UInt8] = rng.int(4) == 0 ? [UInt8](repeating: [0, 255, 127][rng.int(3)], count: n) : rng.bytes(n)
                _ = dfm.process(iq: block); _ = dfmDisc.process(iq: block); _ = m10.process(iq: block); _ = rs41.process(iq: block)
            }
        }
    }

    @Test func frontEndHandlesWildListenCalls() {
        var rng = Rng(state: 23)
        let front = FMFrontEnd(sampleRate: 2_048_000, channelCutoffHz: 4_500, tones: .init(offsetHz: 2_400, window: 19))
        for _ in 0..<40 {
            front.listen(at: [0, 1e9, -1e9, 12_345.6, Double.nan, Double.infinity][rng.int(6)])
            _ = front.processBlock(iq: rng.bytes([0, 1, 5_000, 80_000][rng.int(4)]))
            _ = front.listeningOffset(atSample: [0, -5, 1e9, Double.nan][rng.int(4)])
        }
    }

    @Test func meshPlannerAndReceiverHandleAnyListeners() throws {
        var rng = Rng(state: 29)
        let presets = MeshtasticPreset.allCases
        var planned = 0, refused = 0
        for _ in 0..<200 {
            let count = rng.int(6)
            let listeners = (0..<count).map { _ in
                MeshtasticListener(preset: presets[rng.int(presets.count)], frequencyHz: 902e6 + Double(rng.int(26_000_000)))
            }
            do {
                let capture = try MeshtasticPlan.capture(for: listeners)
                planned += 1
                if planned <= 12 {
                    let receiver = try MeshtasticMultiReceiver(listeners: listeners, capture: capture)
                    _ = receiver.process(iq: rng.bytes([0, 1, 3, 40_001][rng.int(4)]))
                }
            } catch { refused += 1 }
        }
        print("HOSTILE Meshtastic planner: \(planned) planned, \(refused) refused")
    }
}
