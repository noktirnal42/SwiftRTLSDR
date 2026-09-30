// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRServer

struct ProtocolTests {
    @Test func theHeaderIsRTL0ThenTunerAndGainCountBigEndian() {
        let header = RTLTCP.Header(tunerType: RTLTCP.tunerTypeR820T, gainCount: 29)
        #expect(header.bytes == [0x52, 0x54, 0x4c, 0x30, 0, 0, 0, 5, 0, 0, 0, 29])
        #expect(RTLTCP.Header(bytes: header.bytes) == header)
        #expect(RTLTCP.Header(bytes: Array("RTL1".utf8) + [UInt8](repeating: 0, count: 8)) == nil)
    }

    @Test func commandsParseFromTheirWireBytes() {
        #expect(RTLTCP.Command(bytes: [0x01, 0x05, 0xf5, 0xe1, 0x00]) == .setFrequency(100_000_000))
        #expect(RTLTCP.Command(bytes: [0x02, 0x00, 0x24, 0x9f, 0x00]) == .setSampleRate(2_400_000))
        #expect(RTLTCP.Command(bytes: [0x05, 0xff, 0xff, 0xff, 0xfb]) == .setFrequencyCorrection(ppm: -5))
        #expect(RTLTCP.Command(bytes: [0x06, 0x00, 0x02, 0xff, 0xf6]) == .setIFGain(stage: 2, gain: -10))
        #expect(RTLTCP.Command(bytes: [0x42, 0, 0, 0, 1]) == .unknown(code: 0x42, parameter: 1))
        #expect(RTLTCP.Command(bytes: [0x01, 0, 0]) == nil)
    }

    @Test func everyCommandSurvivesARoundTrip() {
        let all: [RTLTCP.Command] = [
            .setFrequency(1_090_000_000), .setSampleRate(250_000), .setGainMode(manual: true), .setGainMode(manual: false),
            .setGain(496), .setGain(-10), .setFrequencyCorrection(ppm: 57), .setIFGain(stage: 6, gain: 30), .setTestMode(true),
            .setAGCMode(false), .setDirectSampling(2), .setOffsetTuning(true), .setRTLCrystal(28_800_000),
            .setTunerCrystal(28_800_000), .setGainByIndex(12), .setBiasTee(true), .unknown(code: 0xee, parameter: 7),
        ]
        for command in all { #expect(RTLTCP.Command(bytes: command.bytes) == command, "\(command)") }
    }
}

/// Stands in for a dongle: records the calls, and lets the test push sample blocks or kill the stream.
final class FakeBackend: RTLTCPBackend, @unchecked Sendable {
    private let condition = NSCondition()
    private var handler: (@Sendable (UnsafeBufferPointer<UInt8>) -> Void)?
    private var errorHandler: (@Sendable (Error) -> Void)?
    private var log: [String] = []

    let rtlTCPTunerType = RTLTCP.tunerTypeR820T
    let supportedGains = [0, 9, 14, 27, 37, 77, 87, 125, 144, 157, 166, 197, 207, 229, 254, 280, 297, 328, 338, 364, 372,
                          386, 402, 421, 434, 439, 445, 480, 496]

    var calls: [String] { condition.lock(); defer { condition.unlock() }; return log }
    var isStreaming: Bool { condition.lock(); defer { condition.unlock() }; return handler != nil }

    private func note(_ call: String) { condition.lock(); log.append(call); condition.broadcast(); condition.unlock() }

    /// Waits until `predicate` holds for the call log.
    func wait(timeout: TimeInterval = 5, until predicate: ([String]) -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock(); defer { condition.unlock() }
        while !predicate(log) { if !condition.wait(until: deadline) { return false } }
        return true
    }

    func setCenterFrequency(_ hertz: Int) throws { note("frequency \(hertz)") }
    func setSampleRate(_ rate: Int) throws -> Double { note("rate \(rate)"); return Double(rate) }
    func setAutomaticGain() throws { note("gain auto") }
    func setTunerGain(tenthsDB: Int) throws { note("gain \(tenthsDB)") }
    func setFrequencyCorrection(ppm: Int) throws { note("ppm \(ppm)") }
    func setBiasTee(_ on: Bool) throws { note("bias tee \(on)") }

    func startStreaming(blockSize: Int, bufferCount: Int, onError: (@Sendable (Error) -> Void)?,
                        handler: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void) throws {
        condition.lock()
        self.handler = handler
        errorHandler = onError
        log.append("start")
        condition.broadcast()
        condition.unlock()
    }

    func stopStreaming() {
        condition.lock()
        let wasStreaming = handler != nil
        handler = nil
        if wasStreaming { log.append("stop") }
        condition.broadcast()
        condition.unlock()
    }

    func deliver(_ bytes: [UInt8]) {
        condition.lock(); let current = handler; condition.unlock()
        bytes.withUnsafeBufferPointer { current?($0) }
    }

    func fail(_ error: Error) {
        condition.lock(); let current = errorHandler; condition.unlock()
        current?(error)
    }
}

/// A minimal rtl_tcp client over a real loopback socket.
final class TestClient {
    let fd: Int32
    init(port: UInt16) throws { fd = try POSIXSocket.connect(host: "127.0.0.1", port: port) }
    deinit { POSIXSocket.close(fd) }

    /// Reads exactly `count` bytes, or fewer if the connection ends or `timeout` passes.
    func read(_ count: Int, timeout: TimeInterval = 5) -> [UInt8] {
        var bytes: [UInt8] = []
        let deadline = Date(timeIntervalSinceNow: timeout)
        while bytes.count < count, Date() < deadline {
            guard POSIXSocket.waitReadable(fd, timeout: 100) else { continue }
            guard let chunk = try? POSIXSocket.receive(fd, count: count - bytes.count), !chunk.isEmpty else { break }
            bytes += chunk
        }
        return bytes
    }

    func send(_ command: RTLTCP.Command) throws { try POSIXSocket.sendAll(fd, command.bytes) }
}

final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RTLTCPServer.Event] = []
    func append(_ event: RTLTCPServer.Event) { lock.lock(); storage.append(event); lock.unlock() }
    var outcomes: [RTLTCPServer.CommandOutcome] {
        lock.lock(); defer { lock.unlock() }
        return storage.compactMap { if case let .command(_, outcome) = $0 { return outcome } else { return nil } }
    }
    var rejected: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.filter { if case .clientRejected = $0 { return true } else { return false } }.count
    }
}

/// Polls `condition` until it holds or `timeout` passes (for state another thread updates just after a callback).
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !condition() {
        if Date() > deadline { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return true
}

/// Serialised: every test binds loopback sockets and starts threads.
@Suite(.serialized)
struct ServerTests {
    private func startServer(_ configure: (inout RTLTCPServer.Configuration) -> Void = { _ in })
        throws -> (RTLTCPServer, FakeBackend, Events) {
        let backend = FakeBackend()
        let events = Events()
        var configuration = RTLTCPServer.Configuration()
        configuration.port = 0
        configure(&configuration)
        let server = RTLTCPServer(backend: backend, configuration: configuration, onEvent: { events.append($0) })
        try server.start()
        return (server, backend, events)
    }

    @Test func aClientGetsTheHeaderThenTheSamplesInOrder() throws {
        let (server, backend, _) = try startServer()
        defer { server.stop() }
        let client = try TestClient(port: server.port)
        #expect(RTLTCP.Header(bytes: client.read(12)) == RTLTCP.Header(tunerType: 5, gainCount: 29))
        #expect(backend.wait { $0.contains("start") })
        backend.deliver([1, 2, 3, 4])
        backend.deliver([5, 6])
        #expect(client.read(6) == [1, 2, 3, 4, 5, 6])
    }

    @Test func commandsReachTheDongleInOrder() throws {
        let (server, backend, events) = try startServer()
        defer { server.stop() }
        let client = try TestClient(port: server.port)
        _ = client.read(12)
        for command: RTLTCP.Command in [.setSampleRate(2_048_000), .setFrequency(100_000_000), .setGainMode(manual: true),
                                        .setGain(297), .setFrequencyCorrection(ppm: -3), .setGainByIndex(28), .setGainMode(manual: false)] {
            try client.send(command)
        }
        #expect(backend.wait { $0.count >= 8 })
        #expect(backend.calls == ["start", "rate 2048000", "frequency 100000000", "gain 0", "gain 297", "ppm -3", "gain 496", "gain auto"])
        // The dongle sees a command just before the server counts it and reports its outcome.
        #expect(eventually { server.statistics.commands == 7 && events.outcomes.count == 7 })
        #expect(events.outcomes.allSatisfy { $0 == .applied })
    }

    @Test func commandsSplitAcrossPacketsStillParse() throws {
        let (server, backend, _) = try startServer()
        defer { server.stop() }
        let client = try TestClient(port: server.port)
        _ = client.read(12)
        let bytes = RTLTCP.Command.setFrequency(433_920_000).bytes
        try POSIXSocket.sendAll(client.fd, Array(bytes.prefix(2)))
        Thread.sleep(forTimeInterval: 0.05)
        try POSIXSocket.sendAll(client.fd, Array(bytes.suffix(3)))
        #expect(backend.wait { $0.contains("frequency 433920000") })
    }

    @Test func theBiasTeeIsRefusedUnlessTheServerAllowsIt() throws {
        let (server, backend, events) = try startServer()
        let client = try TestClient(port: server.port)
        _ = client.read(12)
        try client.send(.setBiasTee(true))
        try client.send(.setFrequency(162_550_000))
        #expect(backend.wait { $0.contains("frequency 162550000") })
        #expect(!backend.calls.contains("bias tee true"))
        #expect(eventually { events.outcomes.count == 2 })
        #expect(events.outcomes.first == .refused("bias tee control is disabled on this server"))
        server.stop()

        let (allowing, allowedBackend, _) = try startServer { $0.allowBiasTee = true }
        defer { allowing.stop() }
        let second = try TestClient(port: allowing.port)
        _ = second.read(12)
        try second.send(.setBiasTee(true))
        #expect(allowedBackend.wait { $0.contains("bias tee true") })
    }

    @Test func unsupportedAndOutOfRangeCommandsAreReportedAndIgnored() throws {
        let (server, backend, events) = try startServer()
        defer { server.stop() }
        let client = try TestClient(port: server.port)
        _ = client.read(12)
        for command: RTLTCP.Command in [.setAGCMode(true), .setDirectSampling(1), .setGainByIndex(29), .unknown(code: 0x99, parameter: 0),
                                        .setFrequency(100_000_000)] {
            try client.send(command)
        }
        #expect(backend.wait { $0.contains("frequency 100000000") })
        #expect(eventually { events.outcomes.count == 5 })
        #expect(events.outcomes == [.unsupported, .unsupported, .refused("no gain step 29 (the tuner has 29)"), .unsupported, .applied])
        #expect(backend.calls == ["start", "frequency 100000000"])
    }

    @Test func aSecondClientIsTurnedAwayWhileOneIsServed() throws {
        let (server, _, events) = try startServer()
        defer { server.stop() }
        let first = try TestClient(port: server.port)
        #expect(first.read(12).count == 12)
        let second = try TestClient(port: server.port)
        #expect(second.read(12, timeout: 2).isEmpty, "closed without a header")
        #expect(eventually { events.rejected == 1 })
    }

    @Test func whenTheClientLeavesStreamingStopsAndTheNextClientIsServed() throws {
        let (server, backend, _) = try startServer()
        defer { server.stop() }
        var first: TestClient? = try TestClient(port: server.port)
        _ = first?.read(12)
        first = nil                                                    // disconnect
        #expect(backend.wait { $0.last == "stop" })
        #expect(eventually { !server.isServingClient })
        let second = try TestClient(port: server.port)
        #expect(second.read(12).count == 12)
        #expect(backend.wait { $0.filter { $0 == "start" }.count == 2 })
        #expect(eventually { server.statistics.clientsServed == 2 })
    }

    @Test func aClientThatFallsBehindLosesTheOldestDataNotTheStream() throws {
        let (server, backend, _) = try startServer { $0.maximumQueuedBytes = 256 * 1024 }
        defer { server.stop() }
        let client = try TestClient(port: server.port)
        _ = client.read(12)
        #expect(backend.wait { $0.contains("start") })
        // The client reads nothing while 32 MB arrive: far more than the socket buffers and the queue hold.
        let block = [UInt8](repeating: 0x55, count: 65_536)
        let started = Date()
        for _ in 0..<512 { backend.deliver(block) }
        #expect(Date().timeIntervalSince(started) < 5, "delivery never waits on the client")
        #expect(server.statistics.droppedBytes > 0)
        #expect(client.read(4096).count == 4096, "the client still gets samples")
    }

    @Test func aDyingStreamDisconnectsTheClient() throws {
        let (server, backend, _) = try startServer()
        defer { server.stop() }
        let client = try TestClient(port: server.port)
        _ = client.read(12)
        #expect(backend.wait { $0.contains("start") })
        backend.fail(POSIXSocket.Failure(call: "unplugged", code: 5))
        #expect(client.read(1, timeout: 3).isEmpty, "connection closed")
        #expect(backend.wait { $0.last == "stop" })
    }

    @Test func stoppingTheServerDisconnectsTheClientAndStopsTheStream() throws {
        let (server, backend, _) = try startServer()
        let client = try TestClient(port: server.port)
        _ = client.read(12)
        #expect(backend.wait { $0.contains("start") })
        server.stop()
        #expect(backend.calls.last == "stop", "stop() returns only once the dongle is idle")
        #expect(client.read(1, timeout: 2).isEmpty)
        #expect(throws: (any Error).self) { _ = try TestClient(port: server.port).read(1, timeout: 0.5) }
    }
}
