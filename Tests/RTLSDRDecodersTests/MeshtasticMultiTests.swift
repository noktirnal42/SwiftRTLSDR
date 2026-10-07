// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

struct MeshtasticPlanTests {
    @Test func everyDefaultPresetOfEU868ShareOneCapture() throws {
        let region = try #require(MeshtasticRegion.named("EU_868"))
        let presets: [MeshtasticPreset] = [.longFast, .mediumFast, .shortFast, .shortSlow, .mediumSlow, .longSlow]
        let listeners = presets.map { preset in
            MeshtasticListener(preset: preset, frequencyHz: region.frequency(slot: region.defaultSlot(channelName: preset.rawValue,
                                bandwidth: preset.modulation.bandwidth), bandwidth: preset.modulation.bandwidth))
        }
        let capture = try MeshtasticPlan.capture(for: listeners)
        #expect(capture.sampleRate == 1_000_000)
        for listener in listeners {
            let distance = abs(listener.frequencyHz - capture.centerHz)
            #expect(distance - listener.bandwidth / 2 >= MeshtasticPlan.dcGuardHz, "\(listener.preset) is in the DC spike")
            #expect(distance + listener.bandwidth / 2 <= capture.sampleRate * MeshtasticPlan.usableShare / 2, "\(listener.preset) is off the band")
        }
    }

    @Test func aWiderSpreadNeedsTheFasterRateAndATooWideOneIsRefused() throws {
        // Two 250 kHz channels 1.0 MHz apart: 1.25 MHz of band, which 1 MS/s cannot hold but 2 MS/s can.
        let near = [MeshtasticListener(preset: .shortFast, frequencyHz: 906.375e6), MeshtasticListener(preset: .shortFast, frequencyHz: 907.375e6)]
        #expect(try MeshtasticPlan.capture(for: near).sampleRate == 2_000_000)
        let far = [MeshtasticListener(preset: .shortFast, frequencyHz: 906.375e6), MeshtasticListener(preset: .shortFast, frequencyHz: 910.375e6)]
        #expect(throws: MeshtasticPlan.Failure.self) { try MeshtasticPlan.capture(for: far) }
        #expect(throws: MeshtasticPlan.Failure.self) { try MeshtasticPlan.capture(for: []) }
    }

    @Test func aSingleChannelIsKeptClearOfTheSpike() throws {
        let capture = try MeshtasticPlan.capture(for: [MeshtasticListener(preset: .longFast, frequencyHz: 906.875e6)])
        #expect(abs(capture.centerHz - 906.875e6) >= 125_000 + MeshtasticPlan.dcGuardHz)
    }

    @Test func slotsInAWindow() throws {
        let region = try #require(MeshtasticRegion.named("US"))
        let slots = MeshtasticPlan.slots(of: region, bandwidth: 250_000, from: 905.9e6, to: 907.9e6)
        // Centres 906.125 to 907.625 MHz in 250 kHz steps: the next one up would reach past 907.9.
        #expect(slots.count == 7 && slots.contains { abs($0 - 906.875e6) < 1 } && slots.allSatisfy { $0 >= 906.125e6 - 1 && $0 <= 907.625e6 + 1 })
    }
}

struct MeshtasticMultiReceiverTests {
    /// Some bytes for a LoRa payload, different for each seed.
    private func payload(_ seed: UInt8, count: Int = 28) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: Int($0) * 37 + Int(seed) * 11 + 5) }
    }

    /// A channel's signal moved to `offset` hertz from the tuned frequency, as complex floats at `rate`.
    private func channelSignal(_ preset: MeshtasticPreset, payloads: [[UInt8]], offset: Double, rate: Double, snr: Double, seed: UInt64) -> [Float] {
        let p = preset.parameters
        let base = loraModulate(payloads.map { LoRaCoding.encode($0, p) }, p, rate: rate, rf: 906.875e6, ppm: 12, snr: snr, seed: seed)
        var shifted = base
        for k in 0..<(base.count / 2) {
            let phase = 2 * Double.pi * offset * Double(k) / rate
            let (c, s) = (cos(phase), sin(phase))
            let i = Double(base[2 * k]), q = Double(base[2 * k + 1])
            shifted[2 * k] = Float(i * c - q * s)
            shifted[2 * k + 1] = Float(i * s + q * c)
        }
        return shifted
    }

    private func bytes(_ signals: [[Float]], gain: Float) -> [UInt8] {
        let length = signals.map(\.count).max() ?? 0
        var sum = [Float](repeating: 0, count: length)
        for signal in signals { for k in signal.indices { sum[k] += signal[k] } }
        return sum.map { UInt8(max(0, min(255, ($0 * gain + 127.5).rounded()))) }
    }

    private func run(_ receiver: MeshtasticMultiReceiver, _ iq: [UInt8]) -> [MeshtasticFrame] {
        var frames: [MeshtasticFrame] = []
        var index = 0
        while index < iq.count {
            let end = min(iq.count, index + 262_145)                  // odd, so that blocks split samples
            frames += receiver.process(iq: Array(iq[index..<end]))
            index = end
        }
        return frames
    }

    /// Three presets of different bandwidths in different places in one 2 MS/s capture, all at once.
    @Test func severalPresetsAreDecodedFromOneCapture() throws {
        let rate = 2_000_000.0, tuned = 906.0e6
        let plan: [(MeshtasticPreset, Double, UInt8)] = [(.shortFast, -450_000, 1), (.mediumFast, 150_000, 2), (.shortTurbo, 550_000, 3)]
        let sent = plan.map { [payload($0.2), payload($0.2 &+ 50)] }
        let signals = plan.enumerated().map { index, entry in
            channelSignal(entry.0, payloads: sent[index], offset: entry.1, rate: rate, snr: 8, seed: UInt64(index + 1))
        }
        let listeners = plan.map { MeshtasticListener(preset: $0.0, frequencyHz: tuned + $0.1) }
        let receiver = try MeshtasticMultiReceiver(listeners: listeners, sampleRate: rate, centerHz: tuned)
        let capture = bytes(signals, gain: 6)
        // For trying the command line on the same capture: MESH_MULTI_DUMP=/path swift test --filter severalPresets
        if let path = ProcessInfo.processInfo.environment["MESH_MULTI_DUMP"] { try? Data(capture).write(to: URL(fileURLWithPath: path)) }
        let frames = run(receiver, capture)
        for (index, entry) in plan.enumerated() {
            let mine = frames.filter { $0.listener.preset == entry.0 }
            #expect(mine.map(\.frame.payload) == sent[index], "\(entry.0.rawValue): \(mine.count) frames")
            #expect(mine.allSatisfy { $0.frame.crcValid == true && abs($0.carrierHz - (tuned + entry.1 + 906.875e6 * 12e-6)) < 800 },
                    "\(entry.0.rawValue): \(mine.map(\.carrierHz))")
        }
        #expect(frames.count == 6)
    }

    /// Writes a capture whose channels sit on the US slot grid, for trying `mesh --all-slots` on it:
    /// MESH_GRID_DUMP=/path swift test --filter aGridAlignedCapture. Without the variable it does nothing.
    @Test func aGridAlignedCaptureForTheCommandLine() throws {
        guard let path = ProcessInfo.processInfo.environment["MESH_GRID_DUMP"] else { return }
        let rate = 2_000_000.0, tuned = 906.5e6
        let plan: [(MeshtasticPreset, Double, UInt8)] = [(.shortFast, 906.125e6, 1), (.shortSlow, 906.875e6, 2), (.mediumFast, 907.125e6, 3)]
        let signals = plan.map { entry in
            channelSignal(entry.0, payloads: [payload(entry.2), payload(entry.2 &+ 50)], offset: entry.1 - tuned, rate: rate, snr: 8, seed: UInt64(entry.2))
        }
        try? Data(bytes(signals, gain: 6)).write(to: URL(fileURLWithPath: path))
    }

    /// The same signal heard by two listeners (here, two on nearly the same frequency) is reported once, by the one the
    /// carrier is nearer.
    @Test func aTransmissionHeardTwiceIsReportedOnce() throws {
        let rate = 1_000_000.0, tuned = 906.0e6
        let sent = [payload(7), payload(8), payload(9)]
        let signal = channelSignal(.shortFast, payloads: sent, offset: 250_000, rate: rate, snr: 6, seed: 5)
        let near = MeshtasticListener(preset: .shortFast, frequencyHz: tuned + 250_000 + 4_000)
        let far = MeshtasticListener(preset: .shortFast, frequencyHz: tuned + 250_000 - 9_000)
        let frames = run(try MeshtasticMultiReceiver(listeners: [far, near], sampleRate: rate, centerHz: tuned), bytes([signal], gain: 10))
        #expect(frames.map(\.frame.payload) == sent)
        #expect(frames.allSatisfy { $0.listener == near }, "\(frames.map(\.listener.frequencyHz))")
    }

    /// A strong signal leaks into the slots either side: their listeners must not report it, or what is left of it.
    @Test func aStrongSignalDoesNotLeaveFramesOnTheNeighbouringSlots() throws {
        let rate = 1_000_000.0, tuned = 906.0e6
        let sent = [payload(31), payload(32), payload(33)]
        let signal = channelSignal(.shortSlow, payloads: sent, offset: 250_000, rate: rate, snr: 25, seed: 17)
        let listeners = [-250_000.0, 0, 250_000, 500_000].filter { abs($0) >= 150_000 || $0 == 0 }.map {
            MeshtasticListener(preset: .shortSlow, frequencyHz: tuned + $0)
        }
        let frames = run(try MeshtasticMultiReceiver(listeners: listeners, sampleRate: rate, centerHz: tuned), bytes([signal], gain: 3))
        #expect(frames.map(\.frame.payload) == sent && frames.allSatisfy { $0.frame.crcValid == true }, "\(frames.map { ($0.listener.frequencyHz, $0.frame.crcValid) })")
    }

    /// A channelizer must not cost the receiver its sensitivity: a weak signal (SNR in the LoRa bandwidth below zero)
    /// still comes through.
    @Test func aWeakSignalSurvivesTheChannelizer() throws {
        let rate = 2_000_000.0, tuned = 906.0e6
        let sent = [payload(21), payload(22)]
        let signal = channelSignal(.shortFast, payloads: sent, offset: -300_000, rate: rate, snr: -4, seed: 11)
        let listener = MeshtasticListener(preset: .shortFast, frequencyHz: tuned - 300_000)
        let frames = run(try MeshtasticMultiReceiver(listeners: [listener], sampleRate: rate, centerHz: tuned), bytes([signal], gain: 4))
        #expect(frames.map(\.frame.payload) == sent)
    }

    /// A rate that is not a whole multiple of a listener's bandwidth is refused instead of trapping.
    @Test func aRateThatDoesNotHoldTheBandwidthIsRefused() {
        let listener = MeshtasticListener(preset: .shortFast, frequencyHz: 906.0e6)      // 250 kHz
        for rate in [1_100_000.0, 100_000, 0, .nan, .infinity] {
            #expect(throws: MeshtasticMultiReceiver.Failure.self) { try MeshtasticMultiReceiver(listeners: [listener], sampleRate: rate, centerHz: 906.0e6) }
        }
        #expect(throws: Never.self) { try MeshtasticMultiReceiver(listeners: [listener], sampleRate: 1_000_000, centerHz: 906.0e6) }
    }

    @Test func noiseAloneGivesNoFrames() throws {
        var state: UInt64 = 123
        func uniform() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(state >> 11) + 0.5) / Double(1 << 53)
        }
        let noise = (0..<(2 * 2_000_000)).map { _ in UInt8(max(0, min(255, (127.5 + 12 * (-2 * log(uniform())).squareRoot() * cos(2 * Double.pi * uniform())).rounded()))) }
        let listeners = [MeshtasticListener(preset: .shortFast, frequencyHz: 906.2e6), MeshtasticListener(preset: .longFast, frequencyHz: 905.7e6)]
        #expect(try MeshtasticMultiReceiver(listeners: listeners, sampleRate: 2_000_000, centerHz: 906.0e6).process(iq: noise).isEmpty)
    }
}
