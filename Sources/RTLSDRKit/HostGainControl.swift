// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Runs a `GainLoop` against a streaming device: an overload guard or a host-side AGC.
///
///     let control = try HostGainControl(device: device, configuration: .overloadGuard(ceilingTenthsDB: 372))
///     try device.startStreaming { block in
///         control.observe(block)          // cheap: statistics here, decisions and gain changes on its own queue
///         // ... your own processing ...
///     }
///
/// The device is switched to manual gain at the loop's starting step. While the control is active, don't set the gain
/// yourself; call `stop()` first. Not verified on hardware: the thresholds are starting points, not measurements.
public final class HostGainControl: @unchecked Sendable {

    /// One gain change, reported after it was applied.
    public struct Change: Sendable {
        public var fromTenthsDB: Int
        public var toTenthsDB: Int
        public var reason: GainLoop.Reason
        /// The block that prompted it.
        public var statistics: SampleStatistics
    }

    private let device: RTLSDRDevice
    private let queue = DispatchQueue(label: "RTLSDRKit.HostGainControl")
    private let onQueue = DispatchSpecificKey<Bool>()
    private let onChange: (@Sendable (Change) -> Void)?
    private let onError: (@Sendable (Error) -> Void)?

    private let lock = NSLock()
    private var loop: GainLoop
    private var appliedTenthsDB: Int
    private var arrived = 0            // blocks handed to observe(), numbered from 1
    private var appliedThrough = 0     // blocks that had arrived when the last change finished applying
    private var stopped = false
    private var latest = SampleStatistics()

    /// - Parameters:
    ///   - onChange: called on the control's queue after each gain change.
    ///   - onError: called on the control's queue if a gain change fails; the control then stops.
    public init(
        device: RTLSDRDevice,
        configuration: GainLoop.Configuration,
        onChange: (@Sendable (Change) -> Void)? = nil,
        onError: (@Sendable (Error) -> Void)? = nil
    ) throws {
        self.device = device
        self.onChange = onChange
        self.onError = onError
        loop = GainLoop(configuration)
        appliedTenthsDB = loop.gainTenthsDB
        queue.setSpecific(key: onQueue, value: true)
        try device.setTunerGain(tenthsDB: appliedTenthsDB)
    }

    /// The gain the control last applied, in tenths of a dB.
    public var gainTenthsDB: Int { lock.lock(); defer { lock.unlock() }; return appliedTenthsDB }

    /// The statistics of the most recent block observed.
    public var latestStatistics: SampleStatistics { lock.lock(); defer { lock.unlock() }; return latest }

    /// Call with every streamed block (from the streaming handler).
    public func observe(_ block: UnsafeBufferPointer<UInt8>) {
        observe(SampleStatistics(block))
    }

    /// Call with every block's statistics, if the handler already computes them.
    public func observe(_ statistics: SampleStatistics) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        arrived += 1
        let sequence = arrived
        latest = statistics
        lock.unlock()
        queue.async { [self] in process(statistics, sequence: sequence) }
    }

    /// Stops adjusting (the gain stays where it is). Waits for a change in progress to finish, except when called from
    /// `onChange` or `onError`, which run on the control's queue: there it returns at once, and nothing follows.
    public func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        if DispatchQueue.getSpecific(key: onQueue) != true { queue.sync {} }
    }

    private func process(_ statistics: SampleStatistics, sequence: Int) {
        lock.lock()
        // Blocks that arrived before the last change finished may hold samples taken at the old gain.
        guard !stopped, sequence > appliedThrough else { lock.unlock(); return }
        let before = appliedTenthsDB
        let proposal = loop.observe(statistics)
        let after = loop.gainTenthsDB
        lock.unlock()
        guard let proposal else { return }

        do {
            try device.setTunerGain(tenthsDB: after)
        } catch {
            lock.lock(); stopped = true; lock.unlock()
            onError?(error)
            return
        }
        lock.lock()
        loop.changeApplied()
        appliedTenthsDB = after
        appliedThrough = arrived
        lock.unlock()
        onChange?(Change(fromTenthsDB: before, toTenthsDB: after, reason: proposal.reason, statistics: statistics))
    }
}
