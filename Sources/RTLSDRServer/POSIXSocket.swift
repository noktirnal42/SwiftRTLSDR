// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The few BSD-socket calls the server needs, over IPv4, with the Darwin/Glibc differences hidden. Plain sockets
/// rather than Network.framework so the server builds (and is tested) on Linux as well as macOS.
enum POSIXSocket {
    #if canImport(Glibc)
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    private static let sendFlags = Int32(MSG_NOSIGNAL)          // a vanished client must not kill us with SIGPIPE
    #else
    private static let streamType = SOCK_STREAM
    private static let sendFlags: Int32 = 0                      // Darwin uses SO_NOSIGPIPE on the socket instead
    #endif

    struct Failure: Error, CustomStringConvertible {
        let call: String
        let code: Int32
        var description: String { "\(call) failed: \(String(cString: strerror(code)))" }
    }

    private static func address(_ host: String, _ port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw Failure(call: "inet_pton(\(host))", code: EINVAL) }
        return address
    }

    private static func newSocket() throws -> Int32 {
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw Failure(call: "socket", code: errno) }
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return fd
    }

    /// A listening socket on `host:port` (port 0 picks a free one) and the port it got.
    static func listen(host: String, port: UInt16, backlog: Int32 = 1) throws -> (fd: Int32, port: UInt16) {
        let fd = try newSocket()
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = try address(host, port)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { let code = errno; close(fd); throw Failure(call: "bind(\(host):\(port))", code: code) }
        guard systemListen(fd, backlog) == 0 else { let code = errno; close(fd); throw Failure(call: "listen", code: code) }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, UInt16(bigEndian: actual.sin_port))
    }

    /// Waits up to `timeout` milliseconds for `fd` to become readable (or to be closed/shut down).
    static func waitReadable(_ fd: Int32, timeout: Int32) -> Bool {
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&entry, 1, timeout) > 0
    }

    /// The next connection and the peer's address, or nil if none arrived within `timeout` milliseconds.
    static func accept(_ fd: Int32, timeout: Int32) throws -> (fd: Int32, peer: String)? {
        guard waitReadable(fd, timeout: timeout) else { return nil }
        var peer = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { systemAccept(fd, $0, &length) }
        }
        guard client >= 0 else {
            if errno == EAGAIN || errno == EINTR || errno == ECONNABORTED { return nil }
            throw Failure(call: "accept", code: errno)
        }
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &peer.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
        let host = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (client, "\(host):\(UInt16(bigEndian: peer.sin_port))")
    }

    /// A connection to `host:port` (used by the tests, and by anything that wants to be a client).
    static func connect(host: String, port: UInt16) throws -> Int32 {
        let fd = try newSocket()
        var address = try address(host, port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { systemConnect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { let code = errno; close(fd); throw Failure(call: "connect", code: code) }
        return fd
    }

    /// Sends every byte, or throws.
    static func sendAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let sent = send(fd, bytes.baseAddress! + offset, bytes.count - offset, sendFlags)
            if sent < 0 {
                if errno == EINTR { continue }
                throw Failure(call: "send", code: errno)
            }
            offset += sent
        }
    }

    static func sendAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try sendAll(fd, $0) }
    }

    /// Reads up to `count` bytes: an empty array means the peer closed the connection.
    static func receive(_ fd: Int32, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        while true {
            let received = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, count, 0) }
            if received < 0 {
                if errno == EINTR { continue }
                throw Failure(call: "recv", code: errno)
            }
            return Array(buffer.prefix(received))
        }
    }

    /// Makes a blocked send or recv on `fd` give up after `seconds` (a stalled client must not hold the sender).
    static func setTimeouts(_ fd: Int32, seconds: Int) {
        var value = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Wakes any thread blocked in send or recv on `fd`.
    static func shutdown(_ fd: Int32) {
        _ = systemShutdown(fd, Int32(SHUT_RDWR))
    }

    static func close(_ fd: Int32) {
        _ = systemClose(fd)
    }
}

// Some C calls share names with this enum's own functions; these aliases keep each call site unambiguous.
#if canImport(Glibc)
private let systemListen = Glibc.listen
private let systemAccept = Glibc.accept
private let systemConnect = Glibc.connect
private let systemShutdown = Glibc.shutdown
private let systemClose = Glibc.close
#else
private let systemListen = Darwin.listen
private let systemAccept = Darwin.accept
private let systemConnect = Darwin.connect
private let systemShutdown = Darwin.shutdown
private let systemClose = Darwin.close
#endif
