// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Hands sample blocks from the USB completion queue to a processing queue, and drops blocks (counting them) rather than
/// queueing without limit when processing falls behind: a slow machine, or a debug build, then loses data instead of
/// growing without bound and drifting ever further from real time.
final class Backlog: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let queue: DispatchQueue
    private var pending = 0
    private var droppedBlocks = 0
    private var reportedDrops = 0

    init(label: String, limit: Int = 64) {
        queue = DispatchQueue(label: label)
        self.limit = limit
    }

    /// Call from the streaming handler: copies the block and runs `work` on it in order, unless the backlog is full.
    func submit(_ block: UnsafeBufferPointer<UInt8>, _ work: @escaping @Sendable ([UInt8]) -> Void) {
        lock.lock()
        guard pending < limit else { droppedBlocks += 1; lock.unlock(); return }
        pending += 1
        lock.unlock()
        let copy = Array(block)
        queue.async { [self] in
            work(copy)
            lock.lock(); pending -= 1; lock.unlock()
        }
    }

    /// Runs `work` on the processing queue, after everything submitted so far.
    func sync(_ work: () -> Void) { queue.sync(execute: work) }
    func async(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }

    /// Blocks dropped since the last call (so a caller can warn once per batch).
    func newlyDropped() -> Int {
        lock.lock(); defer { lock.unlock() }
        let new = droppedBlocks - reportedDrops
        reportedDrops = droppedBlocks
        return new
    }
}
