// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Chooses the tuner gain from what the samples look like, because with the tuner's own AGC off (manual gain) nobody
/// else will: with 8-bit samples a strong signal clips the ADC and buries everything else.
///
/// The rule is asymmetric on purpose. When too many samples sit on the ADC's rails the gain drops at once by at least
/// `Configuration.overloadDropDB`; afterwards it climbs back one step at a time, only after a run of clean blocks, and
/// never above `ceilingIndex`. With a `targetDBFS` it also steps toward that level. Blocks that may have been taken
/// while a change was being applied are ignored.
///
/// Pure logic (no hardware), so it can be tested; `HostGainControl` runs it against a device.
public struct GainLoop: Sendable {

    public struct Configuration: Sendable, Equatable {
        /// The highest gain the loop may use, as an index into `RTLSDRDevice.supportedGainsTenthsDB`. The loop starts here.
        public var ceilingIndex: Int
        /// Also steer the mean level toward this (dBFS). nil makes the loop a pure overload guard: it only backs off
        /// when the ADC clips and then returns to the ceiling.
        public var targetDBFS: Double?
        /// Share of I and Q values on a rail that counts as overload. The default, 0.1 %, is a guess, not a measurement.
        public var overloadRailFraction: Double = 0.001
        /// On overload, drop by at least this much at once.
        public var overloadDropDB: Double = 6
        /// A level this far from the target is left alone (hysteresis), in dB.
        public var levelMarginDB: Double = 3
        /// Clean blocks in a row before the gain may go up one step. Doubles (up to 64×) each time a raise is
        /// followed by an overload within that many blocks, so the loop does not keep hitting the same wall.
        public var raiseAfterBlocks: Int = 16
        /// Blocks to ignore after a change is applied: the block being filled during the change is a mix of both gains.
        public var settleBlocks: Int = 2

        public init(ceilingIndex: Int = RTLSDRDevice.supportedGainsTenthsDB.count - 1, targetDBFS: Double? = nil) {
            self.ceilingIndex = ceilingIndex
            self.targetDBFS = targetDBFS
        }

        /// An overload guard that returns to (and never exceeds) the manual gain nearest `tenthsDB`.
        public static func overloadGuard(ceilingTenthsDB tenthsDB: Int) -> Configuration {
            Configuration(ceilingIndex: GainLoop.nearestIndex(tenthsDB: tenthsDB))
        }

        /// A level-seeking AGC over the whole gain range that still backs off hard on overload.
        public static func automatic(targetDBFS: Double) -> Configuration {
            Configuration(targetDBFS: targetDBFS)
        }
    }

    /// Why the loop wants a change.
    public enum Reason: Sendable, Equatable {
        case overload
        case tooLoud
        case roomToRaise
    }

    public let configuration: Configuration
    /// The gain step in use (index into the gain table).
    public private(set) var gainIndex: Int
    public var gainTenthsDB: Int { steps[gainIndex] }

    private let steps: [Int]
    /// Blocks still to be ignored after a change.
    private var settling = 0
    private var cleanBlocks = 0
    private var raiseWait: Int
    /// Settled blocks since the last raise, or nil when the last change was not a raise.
    private var blocksSinceRaise: Int?

    public init(_ configuration: Configuration, gainSteps: [Int] = RTLSDRDevice.supportedGainsTenthsDB) {
        precondition(!gainSteps.isEmpty, "a gain table is needed")
        steps = gainSteps
        var configuration = configuration
        configuration.ceilingIndex = min(max(0, configuration.ceilingIndex), gainSteps.count - 1)
        configuration.raiseAfterBlocks = max(1, configuration.raiseAfterBlocks)
        configuration.settleBlocks = max(0, configuration.settleBlocks)
        self.configuration = configuration
        gainIndex = configuration.ceilingIndex
        raiseWait = configuration.raiseAfterBlocks
    }

    /// The index of the gain step nearest `tenthsDB`.
    public static func nearestIndex(tenthsDB: Int, in steps: [Int] = RTLSDRDevice.supportedGainsTenthsDB) -> Int {
        steps.indices.min { abs(steps[$0] - tenthsDB) < abs(steps[$1] - tenthsDB) } ?? 0
    }

    /// Feeds one block's statistics. Returns the new gain index and why, when the loop wants a change; the caller
    /// applies it and then calls `changeApplied()`.
    public mutating func observe(_ statistics: SampleStatistics) -> (index: Int, reason: Reason)? {
        guard statistics.sampleCount > 0 else { return nil }
        if settling > 0 { settling -= 1; return nil }
        if let since = blocksSinceRaise { blocksSinceRaise = since + 1 }

        let overloaded = statistics.railFraction > configuration.overloadRailFraction
        let level = statistics.meanPowerDBFS

        if overloaded {
            cleanBlocks = 0
            // A raise that ran into overload quickly means the ceiling for now is lower: wait longer next time.
            if let since = blocksSinceRaise, since <= raiseWait {
                raiseWait = min(raiseWait * 2, configuration.raiseAfterBlocks * 64)
            }
            blocksSinceRaise = nil
            guard gainIndex > 0 else { return nil }
            var target = gainIndex - 1
            while target > 0, Double(steps[gainIndex] - steps[target]) / 10 < configuration.overloadDropDB { target -= 1 }
            return propose(target, .overload)
        }

        if let targetDBFS = configuration.targetDBFS, level > targetDBFS + configuration.levelMarginDB {
            cleanBlocks = 0
            blocksSinceRaise = nil
            guard gainIndex > 0 else { return nil }
            return propose(gainIndex - 1, .tooLoud)
        }

        // A raise that held for a whole wait period earns back the normal pace.
        if let since = blocksSinceRaise, since > raiseWait {
            raiseWait = configuration.raiseAfterBlocks
            blocksSinceRaise = nil
        }

        // Room to raise: nearly nothing on the rails, and (with a target) comfortably below it.
        let headroom = statistics.railFraction <= configuration.overloadRailFraction / 10
        let belowTarget = configuration.targetDBFS.map { level < $0 - configuration.levelMarginDB } ?? true
        guard headroom, belowTarget, gainIndex < configuration.ceilingIndex else { cleanBlocks = 0; return nil }
        cleanBlocks += 1
        guard cleanBlocks >= raiseWait else { return nil }
        cleanBlocks = 0
        blocksSinceRaise = 0
        return propose(gainIndex + 1, .roomToRaise)
    }

    private mutating func propose(_ index: Int, _ reason: Reason) -> (index: Int, reason: Reason) {
        gainIndex = index
        return (index, reason)
    }

    /// The proposed change is now in effect; ignore the blocks that may straddle it.
    public mutating func changeApplied() {
        settling = configuration.settleBlocks
    }
}
