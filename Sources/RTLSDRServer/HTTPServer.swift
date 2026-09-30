// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A small HTTP/1.1 server for live dashboards: GET requests answered by a handler, and Server-Sent Events pushed to
/// every open event stream. One request per connection; not meant for the open internet (bind it to localhost).
public final class HTTPServer: @unchecked Sendable {
    public struct Request: Sendable {
        public let method: String
        public let path: String
        public let query: [String: String]

        public func integer(_ name: String) -> Int? { query[name].flatMap { Int($0) } }
    }

    public enum Response: Sendable {
        case content(type: String, body: [UInt8])
        case text(String)
        case notFound
        /// Keep the connection open as an event stream (see `broadcast`).
        case eventStream
    }

    public typealias Handler = @Sendable (Request) -> Response

    public let port: UInt16
    private let listener: Int32
    private let handler: Handler
    private let lock = NSLock()
    private var streams: [Int32] = []
    private var running = false
    private var acceptThread: Thread?

    /// Binds at once (port 0 picks a free port); call `start()` to accept connections.
    public init(host: String = "127.0.0.1", port: UInt16, handler: @escaping Handler) throws {
        (listener, self.port) = try POSIXSocket.listen(host: host, port: port, backlog: 16)
        self.handler = handler
    }

    deinit { POSIXSocket.close(listener) }

    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "HTTPServer.accept"
        acceptThread = thread
        thread.start()
    }

    public func stop() {
        lock.lock()
        running = false
        let open = streams
        streams.removeAll()
        lock.unlock()
        for fd in open { POSIXSocket.shutdown(fd); POSIXSocket.close(fd) }
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// Event streams currently open.
    public var streamCount: Int { lock.lock(); defer { lock.unlock() }; return streams.count }

    /// Sends one event to every open stream; streams that cannot take it are closed.
    public func broadcast(event: String, data: String) {
        let lines = data.split(separator: "\n", omittingEmptySubsequences: false).map { "data: \($0)\n" }.joined()
        let bytes = Array("event: \(event)\n\(lines)\n".utf8)
        lock.lock()
        let open = streams
        lock.unlock()
        var failed: [Int32] = []
        for fd in open {
            do { try POSIXSocket.sendAll(fd, bytes) } catch { failed.append(fd) }
        }
        guard !failed.isEmpty else { return }
        lock.lock()
        streams.removeAll { failed.contains($0) }
        lock.unlock()
        for fd in failed { POSIXSocket.close(fd) }
    }

    private func acceptLoop() {
        while isRunning {
            guard let connection = try? POSIXSocket.accept(listener, timeout: 200) else { continue }
            let fd = connection.fd
            POSIXSocket.setTimeouts(fd, seconds: 2)
            DispatchQueue.global().async { [self] in serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        var received: [UInt8] = []
        while received.count < 16_384 {
            guard let chunk = try? POSIXSocket.receive(fd, count: 4096), !chunk.isEmpty else { break }
            received += chunk
            if String(decoding: received, as: UTF8.self).contains("\r\n\r\n") { break }
        }
        let head = String(decoding: received, as: UTF8.self)
        guard let line = head.split(separator: "\r\n").first else { POSIXSocket.close(fd); return }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { POSIXSocket.close(fd); return }
        let target = String(parts[1])
        let pathEnd = target.firstIndex(of: "?") ?? target.endIndex
        var query: [String: String] = [:]
        if pathEnd < target.endIndex {
            for pair in target[target.index(after: pathEnd)...].split(separator: "&") {
                let items = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if items.count == 2 { query[items[0]] = items[1] }
            }
        }
        let request = Request(method: String(parts[0]), path: String(target[..<pathEnd]), query: query)
        let response = request.method == "GET" ? handler(request) : .notFound

        func send(_ status: String, _ type: String, _ body: [UInt8]) {
            let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
                + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            try? POSIXSocket.sendAll(fd, Array(header.utf8) + body)
            POSIXSocket.shutdown(fd)
            POSIXSocket.close(fd)
        }
        switch response {
        case .content(let type, let body): send("200 OK", type, body)
        case .text(let text): send("200 OK", "text/plain; charset=utf-8", Array(text.utf8))
        case .notFound: send("404 Not Found", "text/plain", Array("not found\n".utf8))
        case .eventStream:
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n"
                + "Connection: keep-alive\r\n\r\nretry: 1000\n\n"
            guard (try? POSIXSocket.sendAll(fd, Array(header.utf8))) != nil else { POSIXSocket.close(fd); return }
            lock.lock()
            if running { streams.append(fd) } else { POSIXSocket.close(fd) }
            lock.unlock()
        }
    }
}
