// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRKit

/// The streaming contract SignalHive got wrong once: a callback buffer is a count of BYTES, two per complex sample
/// (I then Q). A caller that treats the byte count as a sample count keeps half of every block. These tests pin the
/// byte-per-sample relation on both entry points, and the copy-out helper that carries the sample count itself.
struct StreamContractTests {

    /// Collects the copies a handler made, from whatever thread delivered them.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var blocks: [[UInt8]] = []
        private var sampleCounts: [Int] = []
        func add(_ buffer: UnsafeBufferPointer<UInt8>) {
            lock.lock(); defer { lock.unlock() }
            blocks.append(Array(buffer))
            sampleCounts.append(buffer.count / 2)
        }
        var bytes: [UInt8] { lock.lock(); defer { lock.unlock() }; return blocks.flatMap { $0 } }
        var samples: Int { lock.lock(); defer { lock.unlock() }; return sampleCounts.reduce(0, +) }
    }

    @Test func aCallbackBufferCountsBytesAndEachSampleIsTwoOfThem() throws {
        let fake = RecordingTransport()
        let (device, _) = try openDevice(fake)
        let collected = Collected()
        try device.startStreaming { collected.add($0) }
        // Three complex samples in one block: six bytes, so three samples, never six.
        fake.deliver([10, 20, 30, 40, 50, 60])
        device.stopStreaming()
        #expect(collected.bytes == [10, 20, 30, 40, 50, 60])
        #expect(collected.samples == 3, "the handler sees bytes; samples are bytes / 2")
    }

    @Test func noByteIsLostWhenBlocksArriveOneAfterAnother() throws {
        let fake = RecordingTransport()
        let (device, _) = try openDevice(fake)
        let collected = Collected()
        try device.startStreaming { collected.add($0) }
        let blocks = (0..<5).map { block in (0..<512).map { UInt8(truncatingIfNeeded: block &* 7 &+ $0) } }
        for block in blocks { fake.deliver(block) }
        device.stopStreaming()
        #expect(collected.bytes == blocks.flatMap { $0 }, "every byte of every block arrives, in order")
        #expect(collected.samples == 5 * 256)
    }

    @Test func theSampleStreamDeliversEveryByteWithItsSampleCount() async throws {
        let fake = RecordingTransport()
        let (device, _) = try openDevice(fake)
        let stream = try device.sampleStream(blockSize: 512, bufferCount: 4)
        fake.deliver([1, 2, 3, 4])
        fake.deliver([5, 6])
        var received: [IQBlock] = []
        // Finish the stream from outside after the two blocks have been handed over.
        Task.detached { try? await Task.sleep(nanoseconds: 50_000_000); fake.fail(RTLSDRError.usb("end of test")) }
        do {
            for try await block in stream { received.append(block) }
        } catch {
            #expect(error as? RTLSDRError == .usb("end of test"))
        }
        #expect(received.map(\.bytes) == [[1, 2, 3, 4], [5, 6]])
        #expect(received.map(\.sampleCount) == [2, 1])
        #expect(!fake.isStreaming, "the stream stops the dongle when it ends")
    }

    @Test func aBlockOfOddLengthIsNotInventedAsAWholeSample() {
        // An odd byte count can only come from a broken transfer. The helper must not round it up to a sample.
        #expect(IQBlock(bytes: [1, 2, 3]).sampleCount == 1)
    }

    @Test func stopStreamingEndsTheSampleStreamWithoutAnError() async throws {
        let fake = RecordingTransport()
        let (device, _) = try openDevice(fake)
        let stream = try device.sampleStream()
        #expect(fake.isStreaming)
        let consumer = Task { () -> Int in
            var count = 0
            for try await _ in stream { count += 1 }
            return count
        }
        fake.deliver([9, 9])
        device.stopStreaming()
        let count = try await consumer.value
        #expect(count == 1)
        #expect(!fake.isStreaming)
    }

    private func openDevice(_ fake: RecordingTransport) throws -> (RTLSDRDevice, RecordingTransport) {
        (try RTLSDRDevice(transport: fake), fake)
    }
}
