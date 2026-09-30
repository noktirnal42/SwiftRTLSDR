// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRKit

struct SampleStatisticsTests {
    @Test func aQuietBlockHasNoRailsAndALowLevel() {
        let stats = SampleStatistics([UInt8](repeating: 128, count: 1000) + [UInt8](repeating: 127, count: 1000))
        #expect(stats.sampleCount == 1000 && stats.railCount == 0 && stats.railFraction == 0)
        // Every value is half a code from centre: |z|² = 0.5, i.e. 10·log10(0.5 / 127.5²).
        #expect(abs(stats.meanPowerDBFS - 10 * log10(0.5 / (127.5 * 127.5))) < 1e-9)
    }

    @Test func valuesOnTheRailsAreCountedAndReadAsFullScale() {
        let stats = SampleStatistics([0, 255, 255, 0, 128, 127, 255, 255])
        #expect(stats.sampleCount == 4 && stats.railCount == 6)
        #expect(stats.railFraction == 0.75)
        let full = SampleStatistics([0, 255, 255, 0])
        #expect(abs(full.meanPowerDBFS - 10 * log10(2.0)) < 1e-9, "both components at full scale: +3 dBFS")
    }

    @Test func aToneReadsAtItsAmplitude() {
        // A complex tone with amplitude 50 codes: |z|² = 2500.
        var bytes: [UInt8] = []
        for n in 0..<4096 {
            let phase = 2 * Double.pi * Double(n) / 64
            bytes.append(UInt8((127.5 + 50 * cos(phase)).rounded()))
            bytes.append(UInt8((127.5 + 50 * sin(phase)).rounded()))
        }
        let stats = SampleStatistics(bytes)
        #expect(abs(stats.meanPowerDBFS - 10 * log10(2500 / (127.5 * 127.5))) < 0.05)
        #expect(abs(stats.dcOffset.i) < 0.1 && abs(stats.dcOffset.q) < 0.1)
    }

    @Test func dcOffsetIsTheMeanAwayFromCentre() {
        let stats = SampleStatistics([137, 117, 137, 117])
        #expect(stats.dcOffset.i == 9.5 && stats.dcOffset.q == -10.5)
    }

    @Test func aTrailingHalfPairIsIgnored() {
        #expect(SampleStatistics([10, 20, 30]) == SampleStatistics([10, 20]))
    }

    @Test func mergingEqualsOneBigBlock() {
        let a: [UInt8] = [0, 12, 200, 255, 90], b: [UInt8] = [3, 4, 128, 127]
        var merged = SampleStatistics(Array(a.prefix(4)))
        merged.merge(SampleStatistics(b))
        #expect(merged == SampleStatistics(Array(a.prefix(4)) + b))
    }

    @Test func anEmptyBlockIsHarmless() {
        let stats = SampleStatistics([])
        #expect(stats.sampleCount == 0 && stats.railFraction == 0 && stats.meanPowerDBFS == -120)
    }
}

/// Statistics with a chosen level and rail share (the loop only looks at those two numbers).
func syntheticStatistics(levelDBFS: Double, railFraction: Double = 0, pairs: Int = 32_768) -> SampleStatistics {
    let meanSquare = pow(10, levelDBFS / 10) * 127.5 * 127.5
    return SampleStatistics(sampleCount: pairs, railCount: Int((railFraction * Double(2 * pairs)).rounded()),
                            sumOfSquares: Int((meanSquare * 4 * Double(pairs)).rounded()))
}

struct GainLoopTests {
    let steps = RTLSDRDevice.supportedGainsTenthsDB
    let quiet = syntheticStatistics(levelDBFS: -40)
    let clipping = syntheticStatistics(levelDBFS: -5, railFraction: 0.02)

    @Test func itStartsAtTheCeiling() {
        #expect(GainLoop(.overloadGuard(ceilingTenthsDB: 297)).gainTenthsDB == 297)
        #expect(GainLoop(.overloadGuard(ceilingTenthsDB: 300)).gainTenthsDB == 297, "the nearest step")
        #expect(GainLoop(.automatic(targetDBFS: -25)).gainTenthsDB == 496)
    }

    @Test func overloadDropsAtLeastSixDecibelsAtOnce() throws {
        var loop = GainLoop(.automatic(targetDBFS: -25))
        let proposal = loop.observe(clipping)
        let change = try #require(proposal)
        #expect(change.reason == .overload)
        #expect(steps[change.index] == 434, "49.6 dB down to 43.4 dB, the first step at least 6 dB lower")
        #expect(loop.gainTenthsDB == 434)
    }

    @Test func overloadAtTheBottomOfTheRangeProposesNothing() {
        var loop = GainLoop(GainLoop.Configuration(ceilingIndex: 0))
        let proposal = loop.observe(clipping)
        #expect(proposal == nil)
    }

    @Test func blocksRightAfterAChangeAreIgnored() {
        var loop = GainLoop(.automatic(targetDBFS: -25))
        _ = loop.observe(clipping)
        loop.changeApplied()
        let first = loop.observe(clipping), second = loop.observe(clipping), third = loop.observe(clipping)
        #expect(first == nil, "may straddle the change")
        #expect(second == nil)
        #expect(third?.reason == .overload, "settled: a real overload again")
    }

    @Test func itClimbsBackOneStepAfterARunOfCleanBlocksButNotAboveTheCeiling() throws {
        var loop = GainLoop(.overloadGuard(ceilingTenthsDB: 372))
        _ = loop.observe(clipping)
        loop.changeApplied()
        let dropped = loop.gainIndex
        for _ in 0..<2 { _ = loop.observe(quiet) }               // settling
        for _ in 0..<(loop.configuration.raiseAfterBlocks - 1) { let proposal = loop.observe(quiet); #expect(proposal == nil) }
        let proposal = loop.observe(quiet)
        let raise = try #require(proposal)
        #expect(raise.reason == .roomToRaise && raise.index == dropped + 1)

        // Keep going: it stops exactly at the ceiling.
        for _ in 0..<2000 { if loop.observe(quiet) != nil { loop.changeApplied() } }
        #expect(loop.gainTenthsDB == 372)
    }

    @Test func aGuardWithoutATargetLeavesLoudButUnclippedSignalsAlone() {
        var loop = GainLoop(.overloadGuard(ceilingTenthsDB: 297))
        for _ in 0..<100 { let proposal = loop.observe(syntheticStatistics(levelDBFS: -8)); #expect(proposal == nil) }
    }

    @Test func withATargetATooLoudLevelStepsDownOneStep() throws {
        var loop = GainLoop(.automatic(targetDBFS: -25))
        let proposal = loop.observe(syntheticStatistics(levelDBFS: -18))
        let change = try #require(proposal)
        #expect(change.reason == .tooLoud && change.index == steps.count - 2)
    }

    @Test func aRaiseThatHitsOverloadAtOnceMakesTheNextRaiseWaitLonger() throws {
        var loop = GainLoop(.overloadGuard(ceilingTenthsDB: 496))
        _ = loop.observe(clipping); loop.changeApplied()
        func blocksUntilRaise() -> Int {
            for _ in 0..<2 { _ = loop.observe(quiet) }           // settling
            var count = 0
            while true {
                count += 1
                if loop.observe(quiet) != nil { loop.changeApplied(); return count }
            }
        }
        #expect(blocksUntilRaise() == 16)
        for _ in 0..<2 { _ = loop.observe(quiet) }
        _ = loop.observe(clipping); loop.changeApplied()          // the raise ran straight into overload
        #expect(blocksUntilRaise() == 32)
    }

    @Test func emptyStatisticsAreIgnored() {
        var loop = GainLoop(.automatic(targetDBFS: -25))
        let proposal = loop.observe(SampleStatistics())
        #expect(proposal == nil)
    }

    /// A crude front end: the level follows the gain one for one, and the ADC clips above −6 dBFS.
    private func plant(inputDBFS: Double, gainTenthsDB: Int) -> SampleStatistics {
        let level = inputDBFS + Double(gainTenthsDB) / 10
        let rails = level > -6 ? 0.05 : level > -9 ? 0.0005 : 0
        return syntheticStatistics(levelDBFS: min(level, 3), railFraction: rails)
    }

    @Test(arguments: [-70.0, -50.0, -30.0])
    func automaticModeSettlesNearTheTargetAndStaysThere(inputDBFS: Double) {
        var loop = GainLoop(.automatic(targetDBFS: -25))
        var changes: [Int] = []
        for block in 0..<3000 {
            if loop.observe(plant(inputDBFS: inputDBFS, gainTenthsDB: loop.gainTenthsDB)) != nil {
                loop.changeApplied()
                changes.append(block)
            }
        }
        let level = inputDBFS + Double(loop.gainTenthsDB) / 10
        let reachable = inputDBFS + 49.6 >= -28
        if reachable { #expect(abs(level + 25) <= 3, "level \(level) dBFS") } else { #expect(loop.gainTenthsDB == 496) }
        #expect(changes.filter { $0 > 1500 }.isEmpty, "no hunting once settled")
    }

    @Test func aSignalThatWouldClipAtEveryGainAboveTheFloorDrivesTheGainDown() {
        var loop = GainLoop(.overloadGuard(ceilingTenthsDB: 496))
        for _ in 0..<3000 {
            if loop.observe(plant(inputDBFS: -20, gainTenthsDB: loop.gainTenthsDB)) != nil { loop.changeApplied() }
        }
        #expect(-20 + Double(loop.gainTenthsDB) / 10 <= -6, "never parked in clipping")
    }
}

/// Collects values from other threads and lets a test wait for them.
final class Collected<Value: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var storage: [Value] = []
    func append(_ value: Value) { condition.lock(); storage.append(value); condition.broadcast(); condition.unlock() }
    var values: [Value] { condition.lock(); defer { condition.unlock() }; return storage }
    /// Waits until at least `count` values have arrived; returns false on timeout.
    func wait(for count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock(); defer { condition.unlock() }
        while storage.count < count { if !condition.wait(until: deadline) { return false } }
        return true
    }
}

struct HostGainControlTests {
    private func clippingBlock() -> [UInt8] { (0..<4096).map { $0 % 2 == 0 ? 0 : 255 } }

    @Test func startingPutsTheTunerOnManualGainAtTheCeiling() throws {
        let fake = RecordingTransport()
        let device = try RTLSDRDevice(transport: fake)
        let control = try HostGainControl(device: device, configuration: .overloadGuard(ceilingTenthsDB: 372))
        #expect(device.tunerGainTenthsDB == 372 && control.gainTenthsDB == 372)
        let plan = R820T.planGain(372)
        #expect(RegisterFile(fake.transfers).tuner[0x05]! & 0x0f == plan.lna)
    }

    @Test func clippingBlocksFromTheStreamLowerTheTunerGain() throws {
        let fake = RecordingTransport()
        let device = try RTLSDRDevice(transport: fake)
        let changes = Collected<HostGainControl.Change>()
        let control = try HostGainControl(device: device, configuration: .overloadGuard(ceilingTenthsDB: 496),
                                          onChange: { changes.append($0) })
        try device.startStreaming { control.observe($0) }
        fake.deliver(clippingBlock())
        #expect(changes.wait(for: 1))
        device.stopStreaming()
        control.stop()

        let change = try #require(changes.values.first)
        #expect(change.fromTenthsDB == 496 && change.toTenthsDB == 434 && change.reason == .overload)
        #expect(device.tunerGainTenthsDB == 434)
        #expect(RegisterFile(fake.transfers).tuner[0x05]! & 0x0f == R820T.planGain(434).lna, "written to the tuner")
    }

    @Test func afterStopNothingChanges() throws {
        let fake = RecordingTransport()
        let device = try RTLSDRDevice(transport: fake)
        let changes = Collected<HostGainControl.Change>()
        let control = try HostGainControl(device: device, configuration: .overloadGuard(ceilingTenthsDB: 496),
                                          onChange: { changes.append($0) })
        control.stop()
        control.observe(SampleStatistics(clippingBlock()))
        #expect(!changes.wait(for: 1, timeout: 0.3))
        #expect(device.tunerGainTenthsDB == 496)
    }

    @Test func aFailedGainChangeIsReportedAndStopsTheControl() throws {
        let fake = RecordingTransport()
        let device = try RTLSDRDevice(transport: fake)
        let errors = Collected<String>()
        let control = try HostGainControl(device: device, configuration: .overloadGuard(ceilingTenthsDB: 496),
                                          onError: { errors.append("\($0)") })
        device.close()
        control.observe(SampleStatistics(clippingBlock()))
        #expect(errors.wait(for: 1))
        #expect(errors.values.first?.contains("closed") == true)
    }
}
