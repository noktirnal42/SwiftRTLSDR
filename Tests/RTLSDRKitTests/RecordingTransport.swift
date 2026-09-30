// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
@testable import RTLSDRKit

/// One USB control transfer, in the same form the wire traces use.
struct Transfer: Equatable, Sendable {
    var isWrite: Bool
    var value: UInt16
    var index: UInt16
    var data: [UInt8]
}

/// A stand-in for the dongle: records every control transfer and answers reads the way an R820T dongle does,
/// so a whole driver session can run (and be inspected) without hardware.
final class RecordingTransport: RTLSDRTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Transfer] = []
    private var streamHandler: (@Sendable (UnsafeBufferPointer<UInt8>) -> Void)?
    private var errorHandler: (@Sendable (Error) -> Void)?

    /// Blocks handed to the stream handler, from a background queue, right after streaming starts.
    var blocksToDeliver: [[UInt8]] = []

    /// What the tuner returns for status registers 0...4, as raw wire bytes (the driver bit-reverses them).
    /// Register 0 is the chip ID, register 2 has the PLL-lock flag (0x40 after reversing), register 4 the VCO fine tune.
    /// These are the values a real dongle answered with in the recorded sessions.
    var tunerStatus: [UInt8] = [0x69, 0x01, 0x1f, 0xff, 0x17]
    /// What the demodulator/system registers read back as. Zero unless a test says otherwise.
    var registerReadValue: UInt8 = 0

    var transfers: [Transfer] { lock.lock(); defer { lock.unlock() }; return log }
    var writes: [Transfer] { transfers.filter(\.isWrite) }
    var isStreaming: Bool { lock.lock(); defer { lock.unlock() }; return streamHandler != nil }
    private(set) var closed = false

    func vendorRead(value: UInt16, index: UInt16, length: Int) throws -> [UInt8] {
        var answer = [UInt8](repeating: registerReadValue, count: length)
        if (index >> 8) & 0xff == 6, value == 0x34 {                     // I2C block, the tuner's address
            answer = length == 1 ? [tunerStatus[0]] : Array((tunerStatus + [UInt8](repeating: 0, count: 8)).prefix(length))
        }
        lock.lock(); log.append(Transfer(isWrite: false, value: value, index: index, data: answer)); lock.unlock()
        return answer
    }

    func vendorWrite(value: UInt16, index: UInt16, data: [UInt8]) throws {
        lock.lock(); log.append(Transfer(isWrite: true, value: value, index: index, data: data)); lock.unlock()
    }

    func startBulkStream(
        bufferSize: Int,
        bufferCount: Int,
        handler: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws {
        lock.lock(); defer { lock.unlock() }
        guard streamHandler == nil else { throw RTLSDRError.alreadyStreaming }
        streamHandler = handler
        errorHandler = onError
        let blocks = blocksToDeliver
        if !blocks.isEmpty { DispatchQueue.global().async { [self] in for block in blocks { deliver(block) } } }
    }

    /// Ends the stream the way an unplugged dongle would.
    func fail(_ error: Error) {
        lock.lock(); let handler = errorHandler; lock.unlock()
        handler?(error)
    }

    /// Delivers one block to whoever is streaming (tests use this to stand in for the USB completion queue).
    func deliver(_ bytes: [UInt8]) {
        lock.lock(); let handler = streamHandler; lock.unlock()
        bytes.withUnsafeBufferPointer { handler?($0) }
    }

    func stopBulkStream() { lock.lock(); streamHandler = nil; lock.unlock() }
    func close() { lock.lock(); closed = true; lock.unlock() }
}
