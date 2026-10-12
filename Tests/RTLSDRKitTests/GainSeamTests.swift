// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRKit

/// SH-7: `HostGainControl` takes anything that can set a tuner gain, so the overload and AGC decisions can be tested
/// without a dongle. The fake here is a stand-in, not a model: the decisions come from the real `GainLoop`.
struct GainSeamTests {

    /// Records every gain the control sets (the first entry is the starting gain).
    final class RecordingGainSetting: TunerGainSetting, @unchecked Sendable {
        let settings = Collected<Int>()
        func setTunerGain(tenthsDB: Int) throws { settings.append(tenthsDB) }
    }

    /// A fixed trace: loud blocks that clip, then quiet ones, long enough for the loop to raise the gain again.
    private var trace: [SampleStatistics] {
        Array(repeating: syntheticStatistics(levelDBFS: -6, railFraction: 0.05), count: 3)
            + Array(repeating: syntheticStatistics(levelDBFS: -30), count: 60)
    }

    /// What `GainLoop` alone does with the trace, applying each proposal as the control would: the block that prompted
    /// each change, and the change.
    private func expectedChanges(_ configuration: GainLoop.Configuration) -> [(block: Int, from: Int, to: Int, reason: GainLoop.Reason)] {
        var loop = GainLoop(configuration)
        var changes: [(block: Int, from: Int, to: Int, reason: GainLoop.Reason)] = []
        for (index, statistics) in trace.enumerated() {
            let before = loop.gainTenthsDB
            guard let proposal = loop.observe(statistics) else { continue }
            loop.changeApplied()
            changes.append((index, before, loop.gainTenthsDB, proposal.reason))
        }
        return changes
    }

    @Test func theControlSetsTheSameGainsAsTheLoopForAFixedTrace() throws {
        let configuration = GainLoop.Configuration.overloadGuard(ceilingTenthsDB: 496)
        let expected = expectedChanges(configuration)
        #expect(!expected.isEmpty, "the trace must make the loop act")

        let setting = RecordingGainSetting()
        let changes = Collected<HostGainControl.Change>()
        let control = try HostGainControl(device: setting, configuration: configuration, onChange: { changes.append($0) })
        // Feed one block at a time and wait for each change to land before the next block, as a stream would when the
        // change is applied in time (blocks that arrive during a change are deliberately skipped by the control).
        var landed = 0
        for (index, statistics) in trace.enumerated() {
            control.observe(statistics)
            if let change = expected.first(where: { $0.block == index }) {
                landed += 1
                #expect(changes.wait(for: landed), "change for block \(change.block) landed")
            }
        }
        control.stop()

        let got = changes.values.map { (from: $0.fromTenthsDB, to: $0.toTenthsDB, reason: $0.reason) }
        #expect(got.map(\.from) == expected.map(\.from))
        #expect(got.map(\.to) == expected.map(\.to))
        #expect(got.map(\.reason) == expected.map(\.reason))
        #expect(setting.settings.values.first == 496, "the starting gain is the ceiling")
        #expect(Array(setting.settings.values.dropFirst()) == expected.map(\.to), "every change reaches the setter, in order")
    }

    @Test func aSettingThatIsNotADeviceCanDriveTheControl() throws {
        let setting = RecordingGainSetting()
        let control = try HostGainControl(device: setting, configuration: .overloadGuard(ceilingTenthsDB: 372))
        #expect(control.gainTenthsDB == 372)
        #expect(setting.settings.values == [372])
        control.stop()
    }

    @Test func railFractionIsTheShareOfRailValuesAndIsDocumentedAsSo() {
        // Four pairs; the rail values are 0, 255, 0, 0 (four of the eight I and Q values): 4 / (2 * 4) = 0.5.
        let statistics = SampleStatistics([0, 128, 255, 128, 0, 0, 128, 128])
        #expect(statistics.sampleCount == 4)
        #expect(statistics.railCount == 4)
        #expect(statistics.railFraction == 0.5, "railCount / (2 * sampleCount)")
    }
}
