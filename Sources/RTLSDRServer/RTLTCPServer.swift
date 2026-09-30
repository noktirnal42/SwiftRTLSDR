// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRKit

/// What the server needs from a radio. `RTLSDRDevice` provides it; tests use a fake.
public protocol RTLTCPBackend: AnyObject, Sendable {
    /// The tuner as `rtl_tcp` numbers it (see `RTLTCP.tunerTypeR820T`).
    var rtlTCPTunerType: UInt32 { get }
    var supportedGains: [Int] { get }
    func setCenterFrequency(_ hertz: Int) throws
    @discardableResult func setSampleRate(_ rate: Int) throws -> Double
    func setAutomaticGain() throws
    func setTunerGain(tenthsDB: Int) throws
    func setFrequencyCorrection(ppm: Int) throws
    func setBiasTee(_ on: Bool) throws
    func startStreaming(blockSize: Int, bufferCount: Int, onError: (@Sendable (Error) -> Void)?,
                        handler: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void) throws
    func stopStreaming()
}

extension RTLSDRDevice: RTLTCPBackend {
    public var rtlTCPTunerType: UInt32 { RTLTCP.tunerTypeR820T }
    public var supportedGains: [Int] { Self.supportedGainsTenthsDB }
}

/// Serves a dongle over the network with the `rtl_tcp` protocol, so an SDR application on another machine can use a
/// dongle plugged in at the antenna.
///
/// One client at a time, like `rtl_tcp`: further connections are closed at once while one is being served. Samples
/// are queued for the client up to `Configuration.maximumQueuedBytes`; a client that falls further behind loses the
/// oldest samples (counted in `Statistics.droppedBytes`) rather than making the dongle's FIFO overflow.
///
/// Commands the R820T or this driver cannot honour (E4000 IF gain, test mode, the RTL2832U's digital AGC, direct
/// sampling, offset tuning, crystal overrides) are reported as unsupported and otherwise ignored. The bias tee is off
/// limits to clients unless `allowBiasTee` is set, because driving GPIO 0 is only safe on dongles known to have one.
///
/// **The protocol has no authentication or encryption.** The default address is 127.0.0.1; serving on other
/// interfaces lets anyone who can reach the port retune the dongle and receive its samples.
public final class RTLTCPServer: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var address = "127.0.0.1"
        /// 0 picks a free port (see `RTLTCPServer.port`).
        public var port: UInt16 = 1234
        public var maximumQueuedBytes = 16 << 20
        public var blockSize = 65_536
        public var bufferCount = 8
        public var allowBiasTee = false

        public init() {}
    }

    public enum Event: Sendable {
        case listening(port: UInt16)
        case clientConnected(peer: String)
        case clientRejected(peer: String)
        case clientDisconnected(peer: String, reason: String)
        case command(RTLTCP.Command, outcome: CommandOutcome)
    }

    public enum CommandOutcome: Sendable, Equatable {
        case applied
        case unsupported
        case refused(String)
        case failed(String)
    }

    public struct Statistics: Sendable, Equatable {
        public var clientsServed = 0
        public var bytesSent = 0
        public var droppedBytes = 0
        public var commands = 0
    }

    private let backend: RTLTCPBackend
    public let configuration: Configuration
    private let onEvent: @Sendable (Event) -> Void

    private let lock = NSLock()
    private var listener: Int32 = -1
    private var boundPort: UInt16 = 0
    private var running = false
    private var session: Session?
    private var stats = Statistics()
    private let acceptLoopDone = DispatchSemaphore(value: 0)

    public init(backend: RTLTCPBackend, configuration: Configuration = Configuration(), onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.backend = backend
        self.configuration = configuration
        self.onEvent = onEvent
    }

    deinit { stop() }

    /// The port being listened on (useful with `port: 0`).
    public var port: UInt16 { lock.lock(); defer { lock.unlock() }; return boundPort }
    public var statistics: Statistics { lock.lock(); defer { lock.unlock() }; return stats }
    /// Whether a client is connected (a new one would be turned away).
    public var isServingClient: Bool { lock.lock(); defer { lock.unlock() }; return session != nil }

    /// Binds, listens, and starts accepting in the background.
    public func start() throws {
        lock.lock()
        guard !running else { lock.unlock(); return }
        lock.unlock()
        let (fd, port) = try POSIXSocket.listen(host: configuration.address, port: configuration.port)
        lock.lock()
        listener = fd
        boundPort = port
        running = true
        lock.unlock()
        onEvent(.listening(port: port))
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    /// Disconnects the client, stops listening, and waits for the server's threads to finish.
    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let current = session
        lock.unlock()
        current?.finish("server stopped")
        acceptLoopDone.wait()
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func acceptLoop(_ fd: Int32) {
        defer {
            POSIXSocket.close(fd)
            acceptLoopDone.signal()
        }
        while isRunning {
            let accepted: (fd: Int32, peer: String)?
            do { accepted = try POSIXSocket.accept(fd, timeout: 200) } catch { continue }
            guard let (client, peer) = accepted else { continue }
            lock.lock()
            let busy = session != nil || !running
            lock.unlock()
            if busy {
                POSIXSocket.close(client)
                onEvent(.clientRejected(peer: peer))
                continue
            }
            let newSession = Session(server: self, fd: client, peer: peer)
            lock.lock()
            session = newSession
            stats.clientsServed += 1
            lock.unlock()
            let finished = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                newSession.run()
                finished.signal()
            }
            // Accepting continues (to turn away extra clients); the session's own thread tidies up after it.
            Thread.detachNewThread { [self] in
                finished.wait()
                lock.lock()
                if session === newSession { session = nil }
                lock.unlock()
            }
        }
        // Wait for a session still winding down, so stop() returns only when the backend is idle.
        while true {
            lock.lock()
            let remaining = session
            lock.unlock()
            guard let remaining else { break }
            remaining.finish("server stopped")
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    // MARK: Commands

    func apply(_ command: RTLTCP.Command) -> CommandOutcome {
        do {
            switch command {
            case let .setFrequency(hertz):
                try backend.setCenterFrequency(Int(hertz))
            case let .setSampleRate(rate):
                try backend.setSampleRate(Int(rate))
            case let .setGainMode(manual):
                // rtl_tcp: manual mode starts at 0 dB until a gain command follows.
                if manual { try backend.setTunerGain(tenthsDB: 0) } else { try backend.setAutomaticGain() }
            case let .setGain(tenths):
                try backend.setTunerGain(tenthsDB: Int(tenths))
            case let .setFrequencyCorrection(ppm):
                try backend.setFrequencyCorrection(ppm: Int(ppm))
            case let .setGainByIndex(index):
                let gains = backend.supportedGains
                guard Int(index) < gains.count else { return .refused("no gain step \(index) (the tuner has \(gains.count))") }
                try backend.setTunerGain(tenthsDB: gains[Int(index)])
            case let .setBiasTee(on):
                guard configuration.allowBiasTee else { return .refused("bias tee control is disabled on this server") }
                try backend.setBiasTee(on)
            case .setIFGain, .setTestMode, .setAGCMode, .setDirectSampling, .setOffsetTuning, .setRTLCrystal, .setTunerCrystal, .unknown:
                return .unsupported
            }
            return .applied
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    fileprivate func record(_ event: Event) { onEvent(event) }
    fileprivate func count(sent: Int = 0, dropped: Int = 0, commands: Int = 0) {
        lock.lock()
        stats.bytesSent += sent
        stats.droppedBytes += dropped
        stats.commands += commands
        lock.unlock()
    }
    fileprivate var backendForSession: RTLTCPBackend { backend }
}

/// One connected client: a command reader (this thread), a sender, and the sample queue between the stream and it.
private final class Session: @unchecked Sendable {
    private unowned let server: RTLTCPServer
    private let fd: Int32
    let peer: String

    private let condition = NSCondition()
    private var queue: [[UInt8]] = []
    private var queueHead = 0
    private var queuedBytes = 0
    private var ending: String?
    private let senderDone = DispatchSemaphore(value: 0)

    init(server: RTLTCPServer, fd: Int32, peer: String) {
        self.server = server
        self.fd = fd
        self.peer = peer
    }

    /// Ends the session from any thread (idempotent): wakes the command reader and the sender.
    func finish(_ reason: String) {
        condition.lock()
        if ending == nil { ending = reason }
        condition.broadcast()
        condition.unlock()
        POSIXSocket.shutdown(fd)
    }

    private var endReason: String? { condition.lock(); defer { condition.unlock() }; return ending }

    func run() {
        let backend = server.backendForSession
        server.record(.clientConnected(peer: peer))
        defer {
            POSIXSocket.close(fd)
            server.record(.clientDisconnected(peer: peer, reason: endReason ?? "unknown"))
        }

        let header = RTLTCP.Header(tunerType: backend.rtlTCPTunerType, gainCount: UInt32(backend.supportedGains.count))
        do { try POSIXSocket.sendAll(fd, header.bytes) } catch { finish("could not send the header: \(error)"); return }

        Thread.detachNewThread { [self] in sendLoop() }
        do {
            try backend.startStreaming(
                blockSize: server.configuration.blockSize, bufferCount: server.configuration.bufferCount,
                onError: { [weak self] error in self?.finish("the dongle stopped streaming: \(error.localizedDescription)") },
                handler: { [weak self] block in self?.enqueue(block) })
        } catch {
            finish("could not start streaming: \(error.localizedDescription)")
        }

        readCommands()
        backend.stopStreaming()
        finish("closed")
        senderDone.wait()
    }

    private func readCommands() {
        var pending: [UInt8] = []
        while endReason == nil {
            guard POSIXSocket.waitReadable(fd, timeout: 200) else { continue }
            let received: [UInt8]
            do { received = try POSIXSocket.receive(fd, count: 1024) } catch { finish("receive failed: \(error)"); return }
            guard !received.isEmpty else { finish("the client disconnected"); return }
            pending += received
            while pending.count >= RTLTCP.commandSize {
                let bytes = Array(pending.prefix(RTLTCP.commandSize))
                pending.removeFirst(RTLTCP.commandSize)
                guard let command = RTLTCP.Command(bytes: bytes) else { continue }
                let outcome = server.apply(command)
                server.count(commands: 1)
                server.record(.command(command, outcome: outcome))
            }
        }
    }

    /// Called on the USB completion queue: copy and hand over, dropping the oldest data if the client lags.
    private func enqueue(_ block: UnsafeBufferPointer<UInt8>) {
        let copy = Array(block)
        var dropped = 0
        condition.lock()
        guard ending == nil else { condition.unlock(); return }
        queue.append(copy)
        queuedBytes += copy.count
        while queuedBytes > server.configuration.maximumQueuedBytes, queueHead < queue.count - 1 {
            dropped += queue[queueHead].count
            queuedBytes -= queue[queueHead].count
            queue[queueHead] = []
            queueHead += 1
        }
        condition.signal()
        condition.unlock()
        if dropped > 0 { server.count(dropped: dropped) }
    }

    private func sendLoop() {
        defer { senderDone.signal() }
        while true {
            condition.lock()
            while queueHead == queue.count && ending == nil { condition.wait() }
            if ending != nil { condition.unlock(); return }
            let block = queue[queueHead]
            queue[queueHead] = []
            queueHead += 1
            queuedBytes -= block.count
            if queueHead > 64, queueHead * 2 > queue.count {     // compact now and then
                queue.removeFirst(queueHead)
                queueHead = 0
            }
            condition.unlock()
            do {
                try POSIXSocket.sendAll(fd, block)
                server.count(sent: block.count)
            } catch {
                finish("send failed (the client probably left): \(error)")
                return
            }
        }
    }
}
