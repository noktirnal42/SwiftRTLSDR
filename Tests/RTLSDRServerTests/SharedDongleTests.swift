// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
import RTLSDRKit
@testable import RTLSDRServer

/// SH-10: a network client on a dongle that an app is already streaming. The app publishes its stream to an `IQFanOut`;
/// the server's client gets a copy, and a remote retune is refused (or applied and reported), as documented.
struct SharedDongleTests {

    /// Collects what a relayed client receives.
    final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var blocks: [[UInt8]] = []
        private var errors: [String] = []
        func add(_ buffer: UnsafeBufferPointer<UInt8>) { lock.lock(); blocks.append(Array(buffer)); lock.unlock() }
        func fail(_ error: Error) { lock.lock(); errors.append("\(error)"); lock.unlock() }
        var bytes: [UInt8] { lock.lock(); defer { lock.unlock() }; return blocks.flatMap { $0 } }
        var errorCount: Int { lock.lock(); defer { lock.unlock() }; return errors.count }
    }

    private func publish(_ fanOut: IQFanOut, _ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { fanOut.publish($0) }
    }

    @Test func aClientGetsTheOwnersSamplesAndTheDongleIsNotStartedAgain() throws {
        let dongle = FakeBackend()
        let stream = IQFanOut()
        stream.open()                                        // the owner's device is streaming
        let shared = SharedDongleBackend(dongle: dongle, stream: stream)
        let received = Received()
        try shared.startStreaming(blockSize: 65_536, bufferCount: 8, onError: { received.fail($0) }, handler: { received.add($0) })
        publish(stream, [1, 2, 3, 4])
        publish(stream, [5, 6])
        let deadline = Date(timeIntervalSinceNow: 5)            // the client's thread takes the blocks in its own time
        while received.bytes.count < 6 && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        shared.stopStreaming()
        #expect(received.bytes == [1, 2, 3, 4, 5, 6], "the client sees what the owner's stream carries")
        #expect(!dongle.calls.contains("start"), "the dongle is not started for the client")
        #expect(!dongle.calls.contains("stop"), "stopping the client does not stop the owner's stream")
        #expect(received.errorCount == 0, "a client stopping is not an error")
    }

    @Test func aRemoteTuneIsRefusedByDefaultAndTheDongleIsUntouched() throws {
        let dongle = FakeBackend()
        let shared = SharedDongleBackend(dongle: dongle, stream: IQFanOut())
        #expect(throws: RemoteRefusal.self) { try shared.setCenterFrequency(100_000_000) }
        #expect(throws: RemoteRefusal.self) { try shared.setTunerGain(tenthsDB: 300) }
        #expect(throws: RemoteRefusal.self) { try shared.setSampleRate(2_048_000) }
        #expect(dongle.calls.isEmpty, "the owner keeps the dongle's settings")
    }

    @Test func aRemoteTuneCanBeAppliedWithAnEventForTheOwner() throws {
        final class Messages: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []
            func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let dongle = FakeBackend()
        let messages = Messages()
        let shared = SharedDongleBackend(dongle: dongle, stream: IQFanOut(), remoteControl: .apply(onChange: { messages.add($0) }))
        try shared.setCenterFrequency(100_000_000)
        #expect(dongle.calls == ["frequency 100000000"])
        #expect(messages.all.count == 1 && messages.all[0].contains("100000000"), "the owner is told what changed")
    }

    @Test func aClientCannotStreamFromADongleNobodyIsStreamingFrom() {
        let shared = SharedDongleBackend(dongle: FakeBackend(), stream: IQFanOut())
        #expect(throws: RemoteRefusal.self) {
            try shared.startStreaming(blockSize: 65_536, bufferCount: 8, onError: nil, handler: { _ in })
        }
    }

    @Test func theClientIsToldWhenTheOwnersStreamEnds() throws {
        let stream = IQFanOut()
        stream.open()
        let shared = SharedDongleBackend(dongle: FakeBackend(), stream: stream)
        let received = Received()
        try shared.startStreaming(blockSize: 65_536, bufferCount: 8, onError: { received.fail($0) }, handler: { received.add($0) })
        publish(stream, [9, 9])
        stream.finish()
        let deadline = Date(timeIntervalSinceNow: 5)
        while received.errorCount == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(received.bytes == [9, 9], "what was queued still arrives")
        #expect(received.errorCount == 1, "the client is told the stream ended, once")
    }

    @Test func aRefusedRemoteCommandIsReportedAsRefusedNotAsAFailure() {
        let shared = SharedDongleBackend(dongle: FakeBackend(), stream: IQFanOut())
        let server = RTLTCPServer(backend: shared)
        #expect(server.apply(.setFrequency(100_000_000)) == .refused("the owner of this dongle is streaming; remote control is refused"))
    }
}
