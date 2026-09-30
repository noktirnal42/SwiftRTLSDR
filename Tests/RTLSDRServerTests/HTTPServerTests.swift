// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRServer

struct HTTPServerTests {
    private func connect(_ server: HTTPServer, _ target: String) throws -> Int32 {
        let fd = try POSIXSocket.connect(host: "127.0.0.1", port: server.port)
        POSIXSocket.setTimeouts(fd, seconds: 5)
        try POSIXSocket.sendAll(fd, Array("GET \(target) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))
        return fd
    }

    /// The whole reply (the server closes the connection after it).
    private func get(_ server: HTTPServer, _ target: String) throws -> String {
        let fd = try connect(server, target)
        defer { POSIXSocket.close(fd) }
        var received: [UInt8] = []
        while let chunk = try? POSIXSocket.receive(fd, count: 4096), !chunk.isEmpty { received += chunk }
        return String(decoding: received, as: UTF8.self)
    }

    private func waitFor(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    @Test func requestsReachTheHandlerWithTheirQuery() throws {
        let server = try HTTPServer(port: 0) { request in
            request.path == "/echo" ? .text("\(request.query["a"] ?? "-") \(request.integer("n") ?? -1)") : .notFound
        }
        server.start()
        defer { server.stop() }
        let reply = try get(server, "/echo?a=hello%20there&n=42")
        #expect(reply.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(reply.contains("Content-Length: 14\r\n"))
        #expect(reply.hasSuffix("\r\n\r\nhello there 42"))
        #expect(try get(server, "/elsewhere").hasPrefix("HTTP/1.1 404 Not Found\r\n"))
    }

    @Test func eventsReachEveryOpenStreamAndClosedOnesAreDropped() throws {
        let server = try HTTPServer(port: 0) { _ in .eventStream }
        server.start()
        defer { server.stop() }
        let first = try connect(server, "/events"), second = try connect(server, "/events")
        defer { POSIXSocket.close(second) }
        #expect(waitFor { server.streamCount == 2 })

        server.broadcast(event: "telemetry", data: "{\"a\":1}\nmore")
        for fd in [first, second] {
            var received = ""
            #expect(waitFor {
                if let chunk = try? POSIXSocket.receive(fd, count: 4096) { received += String(decoding: chunk, as: UTF8.self) }
                return received.hasSuffix("\n\n") && received.contains("event:")
            })
            #expect(received.hasPrefix("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"))
            #expect(received.hasSuffix("event: telemetry\ndata: {\"a\":1}\ndata: more\n\n"))
        }

        // A client that went away is dropped at a later broadcast (the first send after it closes may still succeed).
        POSIXSocket.close(first)
        #expect(waitFor {
            server.broadcast(event: "ping", data: "")
            return server.streamCount == 1
        })
    }
}
