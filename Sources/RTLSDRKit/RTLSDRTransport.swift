// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The USB operations the driver needs. The real implementation talks to the dongle through Apple's IOUSBHost;
/// tests use a recording fake, so every register access can be checked without hardware.
public protocol RTLSDRTransport: AnyObject, Sendable {
    /// Vendor request 0, device-to-host (bmRequestType 0xC0).
    func vendorRead(value: UInt16, index: UInt16, length: Int) throws -> [UInt8]
    /// Vendor request 0, host-to-device (bmRequestType 0x40). Must fail unless every byte was accepted.
    func vendorWrite(value: UInt16, index: UInt16, data: [UInt8]) throws

    /// Starts streaming sample data from the bulk-in endpoint (0x81), keeping `bufferCount` requests of `bufferSize`
    /// bytes queued so the dongle's small FIFO never waits on the host.
    ///
    /// `handler` receives each completed block, in order, on a USB completion queue: it must return quickly, must not
    /// call `stopBulkStream()`, and the buffer is only valid during the call. `onError` is called at most once if the
    /// stream ends on its own (for example when the dongle is unplugged).
    func startBulkStream(
        bufferSize: Int,
        bufferCount: Int,
        handler: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws
    /// Cancels the stream and returns once every queued request has finished. Safe to call when not streaming.
    func stopBulkStream()
    var isStreaming: Bool { get }
    func close()
}

/// The tuner sits behind the RTL2832U's I2C repeater. Kept as its own protocol so the tuner logic can be
/// tested without the demodulator layer.
protocol I2CBus: AnyObject {
    func i2cWrite(address: UInt8, bytes: [UInt8]) throws
    func i2cRead(address: UInt8, length: Int) throws -> [UInt8]
}
