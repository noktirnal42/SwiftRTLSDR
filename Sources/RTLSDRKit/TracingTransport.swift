// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Wraps a transport and logs every control transfer, one line each, so a session can be compared byte for byte with
/// another driver's or replayed in a test. Bulk (sample) transfers are not logged.
///
///     W 0x0000 0x0110 09 00          a write:  wValue wIndex data
///     R 0x0000 0x0110 2 -> 09 00     a read:   wValue wIndex length -> data
///
/// Set the `RTLSDR_TRACE` environment variable to a file path (or `-` for stderr) to trace a real session.
final class TracingTransport: RTLSDRTransport, @unchecked Sendable {
    private let base: RTLSDRTransport
    private let sink: FileHandle
    private let lock = NSLock()

    init(wrapping base: RTLSDRTransport, to sink: FileHandle) {
        self.base = base
        self.sink = sink
    }

    /// A tracing wrapper if `RTLSDR_TRACE` is set, otherwise `transport` itself.
    static func fromEnvironment(_ transport: RTLSDRTransport) -> RTLSDRTransport {
        guard let target = ProcessInfo.processInfo.environment["RTLSDR_TRACE"], !target.isEmpty else { return transport }
        if target == "-" { return TracingTransport(wrapping: transport, to: .standardError) }
        FileManager.default.createFile(atPath: target, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: target) else { return transport }
        return TracingTransport(wrapping: transport, to: handle)
    }

    private func log(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        sink.write(Data((line + "\n").utf8))
    }

    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }
    private static func word(_ value: UInt16) -> String { String(format: "0x%04x", value) }

    func vendorRead(value: UInt16, index: UInt16, length: Int) throws -> [UInt8] {
        let bytes = try base.vendorRead(value: value, index: index, length: length)
        log("R \(Self.word(value)) \(Self.word(index)) \(length) -> \(Self.hex(bytes))")
        return bytes
    }

    func vendorWrite(value: UInt16, index: UInt16, data: [UInt8]) throws {
        log("W \(Self.word(value)) \(Self.word(index)) \(Self.hex(data))")
        try base.vendorWrite(value: value, index: index, data: data)
    }

    func startBulkStream(
        bufferSize: Int,
        bufferCount: Int,
        handler: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws {
        try base.startBulkStream(bufferSize: bufferSize, bufferCount: bufferCount, handler: handler, onError: onError)
    }

    func stopBulkStream() { base.stopBulkStream() }
    var isStreaming: Bool { base.isStreaming }

    func close() { base.close() }
}
