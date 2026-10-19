// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// One producer, many consumers: the blocks of a single stream handed to each consumer through its own bounded queue
/// (SH-10). The app that owns the dongle publishes from its streaming handler; a network server, a recorder or a decoder
/// takes its own copy of every block.
///
/// The producer never waits. A consumer that falls behind loses its oldest blocks, which are counted in its
/// `droppedBytes`, and the others are unaffected. All consumers share the same array for a block, so publishing copies
/// the bytes once however many consumers there are.
///
///     let fanOut = IQFanOut()
///     fanOut.open()                                      // when the device starts streaming
///     try device.startStreaming { fanOut.publish($0) }
///     let mine = fanOut.subscribe()                      // any thread
///     while let block = mine?.next() { ... }             // nil once finished or cancelled
///
/// `finish()` ends the stream for everyone: each consumer gets what was queued, then nil.
public final class IQFanOut: @unchecked Sendable {

    /// One consumer's end of the fan-out.
    public final class Subscriber: @unchecked Sendable {
        public let maximumQueuedBytes: Int
        private let condition = NSCondition()
        private var queue: [[UInt8]] = []
        private var head = 0
        private var queuedBytes = 0
        private var ended = false
        private var dropped = 0
        private weak var owner: IQFanOut?

        fileprivate init(maximumQueuedBytes: Int, owner: IQFanOut) {
            self.maximumQueuedBytes = maximumQueuedBytes
            self.owner = owner
        }

        /// Bytes this consumer lost because it did not keep up (its oldest blocks, dropped to make room).
        public var droppedBytes: Int { condition.lock(); defer { condition.unlock() }; return dropped }

        /// The next block, waiting for one if necessary. nil once the stream has finished (after its queue drains) or
        /// this consumer was cancelled.
        public func next() -> [UInt8]? {
            condition.lock()
            defer { condition.unlock() }
            while head == queue.count && !ended { condition.wait() }
            guard head < queue.count else { return nil }      // ended and drained, or cancelled (queue emptied)
            let block = queue[head]
            queue[head] = []
            head += 1
            queuedBytes -= block.count
            if head > 64, head * 2 > queue.count {
                queue.removeFirst(head)
                head = 0
            }
            return block
        }

        /// Stops delivery to this consumer: `next()` returns nil from now on, and nothing more is queued for it.
        public func cancel() {
            condition.lock()
            ended = true
            queue.removeAll()
            head = 0
            queuedBytes = 0
            condition.broadcast()
            condition.unlock()
            owner?.remove(self)
        }

        /// Called by the fan-out under its lock. Queues `block`, dropping this consumer's oldest blocks while it is over
        /// its limit (the newest block is always kept).
        fileprivate func enqueue(_ block: [UInt8]) {
            condition.lock()
            defer { condition.unlock() }
            guard !ended else { return }
            queue.append(block)
            queuedBytes += block.count
            while queuedBytes > maximumQueuedBytes, queue.count - head > 1 {
                dropped += queue[head].count
                queuedBytes -= queue[head].count
                queue[head] = []
                head += 1
            }
            condition.signal()
        }

        fileprivate func end() {
            condition.lock()
            ended = true
            condition.broadcast()
            condition.unlock()
        }
    }

    public let maximumQueuedBytesPerSubscriber: Int
    private let lock = NSLock()
    private var subscribers: [Subscriber] = []
    private var opened = false

    public init(maximumQueuedBytesPerSubscriber: Int = 16 << 20) {
        self.maximumQueuedBytesPerSubscriber = maximumQueuedBytesPerSubscriber
    }

    /// Whether a stream is open (between `open()` and `finish()`).
    public var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return opened }

    /// Starts a stream: consumers can subscribe and blocks can be published. Call when the device starts streaming.
    public func open() {
        lock.lock()
        opened = true
        lock.unlock()
    }

    /// Ends the stream for every consumer, after each has taken what it was given. Call when the device stops.
    public func finish() {
        lock.lock()
        opened = false
        let current = subscribers
        subscribers = []
        lock.unlock()
        current.forEach { $0.end() }
    }

    /// A new consumer, or nil when no stream is open.
    public func subscribe() -> Subscriber? {
        lock.lock()
        defer { lock.unlock() }
        guard opened else { return nil }
        let subscriber = Subscriber(maximumQueuedBytes: maximumQueuedBytesPerSubscriber, owner: self)
        subscribers.append(subscriber)
        return subscriber
    }

    /// The number of consumers now subscribed.
    public var subscriberCount: Int { lock.lock(); defer { lock.unlock() }; return subscribers.count }

    /// Hands one block to every consumer. Copies the bytes once. Safe to call from the streaming handler: it never
    /// waits for a consumer. Ignored when no stream is open.
    public func publish(_ block: UnsafeBufferPointer<UInt8>) {
        lock.lock()
        guard opened, !subscribers.isEmpty else { lock.unlock(); return }
        let copy = Array(block)
        let current = subscribers
        lock.unlock()
        current.forEach { $0.enqueue(copy) }
    }

    fileprivate func remove(_ subscriber: Subscriber) {
        lock.lock()
        subscribers.removeAll { $0 === subscriber }
        lock.unlock()
    }
}
