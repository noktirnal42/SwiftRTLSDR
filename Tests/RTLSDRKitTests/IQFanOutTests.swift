// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRKit

/// `IQFanOut` (SH-10): one producer, several consumers, each with its own bounded queue.
struct IQFanOutTests {

    private func publish(_ fanOut: IQFanOut, _ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { fanOut.publish($0) }
    }

    @Test func twoConsumersReceiveIdenticalBytesFromOneProducer() throws {
        let fanOut = IQFanOut()
        fanOut.open()
        let first = try #require(fanOut.subscribe())
        let second = try #require(fanOut.subscribe())
        let blocks = (0..<5).map { block in (0..<512).map { UInt8(truncatingIfNeeded: block &* 13 &+ $0) } }
        for block in blocks { publish(fanOut, block) }
        fanOut.finish()
        var a: [[UInt8]] = [], b: [[UInt8]] = []
        while let block = first.next() { a.append(block) }
        while let block = second.next() { b.append(block) }
        #expect(a == blocks)
        #expect(b == blocks)
        #expect(first.droppedBytes == 0 && second.droppedBytes == 0)
    }

    @Test func aSlowConsumerLosesItsOldestBlocksAndCountsThem() throws {
        let fanOut = IQFanOut(maximumQueuedBytesPerSubscriber: 1_000)
        fanOut.open()
        let fast = try #require(fanOut.subscribe())
        let slow = try #require(fanOut.subscribe())
        // Ten blocks of 400 bytes: the slow consumer can hold two (800 bytes) and so loses the first eight.
        let blocks = (0..<10).map { [UInt8](repeating: UInt8($0), count: 400) }
        for block in blocks {
            publish(fanOut, block)
            _ = fast.next()                                  // the fast one keeps up
        }
        fanOut.finish()
        var kept: [[UInt8]] = []
        while let block = slow.next() { kept.append(block) }
        #expect(kept == Array(blocks.suffix(2)), "the newest blocks survive")
        #expect(slow.droppedBytes == 8 * 400)
        #expect(fast.droppedBytes == 0, "one slow consumer does not cost the others anything")
    }

    @Test func aConsumerThatSubscribesBeforeOpenGetsNothing() {
        let fanOut = IQFanOut()
        #expect(fanOut.subscribe() == nil, "nothing is streaming")
        #expect(!fanOut.isOpen)
        fanOut.open()
        #expect(fanOut.isOpen && fanOut.subscribe() != nil)
    }

    @Test func finishEndsEveryConsumerAfterItsQueueDrains() throws {
        let fanOut = IQFanOut()
        fanOut.open()
        let consumer = try #require(fanOut.subscribe())
        publish(fanOut, [1, 2])
        fanOut.finish()
        #expect(consumer.next() == [1, 2], "data queued before the end is still delivered")
        #expect(consumer.next() == nil)
        #expect(!fanOut.isOpen)
    }

    @Test func aCancelledConsumerGetsNoMoreBlocks() throws {
        let fanOut = IQFanOut()
        fanOut.open()
        let kept = try #require(fanOut.subscribe())
        let cancelled = try #require(fanOut.subscribe())
        cancelled.cancel()
        publish(fanOut, [7, 7])
        #expect(cancelled.next() == nil)
        #expect(kept.next() == [7, 7])
        fanOut.finish()
    }
}
