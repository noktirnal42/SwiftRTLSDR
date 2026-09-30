// SPDX-License-Identifier: GPL-2.0-or-later
#if canImport(IOUSBHost)
import Foundation
import IOKit
import IOUSBHost

/// A dongle that is plugged in.
public struct RTLSDRDeviceInfo: Sendable, Equatable, Hashable {
    public var vendorID: UInt16
    public var productID: UInt16
    /// Marketing name from the built-in table of known dongles.
    public var name: String
    public var manufacturer: String
    public var product: String
    public var serial: String
    public var locationID: UInt32
    /// Identifies this exact device in the I/O Registry (so it can be reopened).
    public var registryEntryID: UInt64
}

enum USBRegistry {
    /// Every connected USB device whose IDs are in the table of known RTL2832U dongles.
    static func connectedDongles() -> [RTLSDRDeviceInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var found: [RTLSDRDeviceInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let vendor = number(service, "idVendor"), let product = number(service, "idProduct"),
                  let name = KnownDevices.name(vendorID: UInt16(truncatingIfNeeded: vendor), productID: UInt16(truncatingIfNeeded: product))
            else { continue }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            found.append(RTLSDRDeviceInfo(
                vendorID: UInt16(truncatingIfNeeded: vendor), productID: UInt16(truncatingIfNeeded: product), name: name,
                manufacturer: string(service, "USB Vendor Name") ?? "",
                product: string(service, "USB Product Name") ?? "",
                serial: string(service, "kUSBSerialNumberString") ?? string(service, "USB Serial Number") ?? "",
                locationID: UInt32(truncatingIfNeeded: number(service, "locationID") ?? 0),
                registryEntryID: entryID))
        }
        return found.sorted { ($0.locationID, $0.registryEntryID) < ($1.locationID, $1.registryEntryID) }
    }

    /// The registry service for a device found earlier. The caller releases it.
    static func service(for info: RTLSDRDeviceInfo) -> io_service_t {
        IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(info.registryEntryID))
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func number(_ service: io_service_t, _ key: String) -> Int? {
        (property(service, key) as? NSNumber)?.intValue
    }

    private static func string(_ service: io_service_t, _ key: String) -> String? {
        property(service, key) as? String
    }
}

/// Talks to the dongle through Apple's IOUSBHost framework: no libusb, and it works inside the App Sandbox with the
/// `com.apple.security.device.usb` entitlement.
final class IOUSBHostTransport: RTLSDRTransport, @unchecked Sendable {
    private static let bulkEndpoint = 0x81
    private static let controlTimeout: TimeInterval = 0.3

    private let device: IOUSBHostDevice
    private var interface: IOUSBHostInterface?
    private var pipe: IOUSBHostPipe?
    private let lock = NSLock()            // guards `closed` and `stream`
    private var closed = false

    /// One running bulk stream. Every request in flight owns one buffer; a finished request re-queues its buffer.
    private struct Stream {
        let handler: @Sendable (UnsafeBufferPointer<UInt8>) -> Void
        let onError: @Sendable (Error) -> Void
        let finished = DispatchSemaphore(value: 0)
        var outstanding = 0
        var stopping = false
    }
    private var stream: Stream?

    /// A transfer buffer. Exactly one request owns it at a time, so sharing it with the completion handler is safe.
    private final class Buffer: @unchecked Sendable {
        let data: NSMutableData
        init?(size: Int) {
            guard let data = NSMutableData(length: size) else { return nil }
            self.data = data
        }
    }

    init(info: RTLSDRDeviceInfo) throws {
        let service = USBRegistry.service(for: info)
        guard service != 0 else { throw RTLSDRError.deviceNotFound(serial: info.serial) }
        defer { IOObjectRelease(service) }

        do {
            device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            throw RTLSDRError.openFailed(error.localizedDescription)
        }

        // The bulk endpoint belongs to interface 0, which is a child of the device in the registry.
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS else {
            device.destroy()
            throw RTLSDRError.openFailed("the device has no interfaces")
        }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            guard IOObjectConformsTo(child, "IOUSBHostInterface") != 0 else { continue }
            do {
                let opened = try IOUSBHostInterface(__ioService: child, options: [], queue: nil, interestHandler: nil)
                pipe = try opened.copyPipe(withAddress: Self.bulkEndpoint)
                interface = opened
                break
            } catch {
                device.destroy()
                throw RTLSDRError.openFailed(error.localizedDescription)
            }
        }
        guard pipe != nil else {
            device.destroy()
            throw RTLSDRError.openFailed("the sample endpoint (0x81) was not found")
        }
    }

    deinit { close() }

    func vendorRead(value: UInt16, index: UInt16, length: Int) throws -> [UInt8] {
        let request = IOUSBDeviceRequest(bmRequestType: 0xC0, bRequest: 0, wValue: value, wIndex: index, wLength: UInt16(length))
        let data = NSMutableData(length: length) ?? NSMutableData()
        var transferred = 0
        do {
            try device.__send(request, data: data, bytesTransferred: &transferred, completionTimeout: Self.controlTimeout)
        } catch {
            throw RTLSDRError.usb(error.localizedDescription)
        }
        guard transferred == length else { throw RTLSDRError.shortTransfer(expected: length, actual: transferred) }
        return [UInt8](data as Data)
    }

    func vendorWrite(value: UInt16, index: UInt16, data bytes: [UInt8]) throws {
        let request = IOUSBDeviceRequest(bmRequestType: 0x40, bRequest: 0, wValue: value, wIndex: index, wLength: UInt16(bytes.count))
        let data = NSMutableData(bytes: bytes, length: bytes.count)
        var transferred = 0
        do {
            try device.__send(request, data: data, bytesTransferred: &transferred, completionTimeout: Self.controlTimeout)
        } catch {
            throw RTLSDRError.usb(error.localizedDescription)
        }
        guard transferred == bytes.count else { throw RTLSDRError.shortTransfer(expected: bytes.count, actual: transferred) }
    }

    // MARK: Sample stream

    var isStreaming: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stream != nil
    }

    func startBulkStream(
        bufferSize: Int,
        bufferCount: Int,
        handler: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws {
        // Bulk requests must be a whole number of 512-byte packets, or the endpoint reports an overflow.
        guard bufferSize > 0, bufferSize % 512 == 0, bufferCount > 0 else {
            throw RTLSDRError.usb("the stream needs a block size that is a multiple of 512 bytes and at least one buffer")
        }
        lock.lock()
        guard !closed, let pipe else { lock.unlock(); throw RTLSDRError.closed }
        guard stream == nil else { lock.unlock(); throw RTLSDRError.alreadyStreaming }
        stream = Stream(handler: handler, onError: onError)

        var failure: Error?
        for _ in 0..<bufferCount {
            guard let buffer = Buffer(size: bufferSize) else { failure = RTLSDRError.usb("out of memory"); break }
            do {
                try enqueue(buffer, on: pipe)
                stream?.outstanding += 1
            } catch {
                failure = RTLSDRError.usb(error.localizedDescription)
                break
            }
        }
        guard let failure else { lock.unlock(); return }

        // Could not queue everything: cancel what was queued and report.
        stream?.stopping = true
        let finished = stream?.finished
        let queued = stream?.outstanding ?? 0
        if queued == 0 { stream = nil }
        lock.unlock()
        if queued > 0 {
            try? pipe.__abort(with: .asynchronous)
            _ = finished?.wait(timeout: .now() + 3)
        }
        throw failure
    }

    /// Queues one request. The caller holds `lock`, which also makes "still running?" and "queue" a single step, so a
    /// request can never be queued after `stopBulkStream()` has aborted the pipe.
    private func enqueue(_ buffer: Buffer, on pipe: IOUSBHostPipe) throws {
        try pipe.enqueueIORequest(with: buffer.data, completionTimeout: 0) { [weak self] status, transferred in
            self?.completed(buffer, status: status, transferred: Int(transferred))
        }
    }

    private func completed(_ buffer: Buffer, status: IOReturn, transferred: Int) {
        lock.lock()
        let handler = stream?.handler
        let running = stream.map { !$0.stopping } ?? false
        lock.unlock()

        if status == kIOReturnSuccess, running {
            if transferred > 0, let handler {
                handler(UnsafeBufferPointer(start: buffer.data.bytes.assumingMemoryBound(to: UInt8.self), count: min(transferred, buffer.data.length)))
            }
            lock.lock()
            if let pipe, let current = stream, !current.stopping {
                do {
                    try enqueue(buffer, on: pipe)      // the buffer goes straight back into the queue
                    lock.unlock()
                    return
                } catch {
                    lock.unlock()
                    retire(error: RTLSDRError.usb(error.localizedDescription))
                    return
                }
            }
            lock.unlock()
            retire(error: nil)
            return
        }
        // Cancelled by stopBulkStream(), or the endpoint failed (unplugged, stalled).
        let aborted = status == kIOReturnAborted || !running
        retire(error: aborted ? nil : RTLSDRError.usb(String(format: "the sample endpoint failed (0x%08x)", UInt32(bitPattern: status))))
    }

    /// A request is finished for good. The first real error stops everything else and is reported once.
    private func retire(error: Error?) {
        lock.lock()
        guard var current = stream else { lock.unlock(); return }
        current.outstanding -= 1
        var report: (@Sendable (Error) -> Void)?
        if error != nil, !current.stopping {
            current.stopping = true
            report = current.onError
            try? pipe?.__abort(with: .asynchronous)
        }
        let done = current.outstanding == 0
        stream = done ? nil : current
        let finished = current.finished
        lock.unlock()
        if let error, let report { report(error) }
        if done { finished.signal() }
    }

    func stopBulkStream() {
        lock.lock()
        guard var current = stream else { lock.unlock(); return }
        current.stopping = true
        stream = current
        let finished = current.finished
        lock.unlock()
        try? pipe?.__abort(with: .asynchronous)
        // Every queued request completes (aborted) on the completion queue; wait for the last one.
        _ = finished.wait(timeout: .now() + 3)
    }

    func close() {
        stopBulkStream()
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        interface?.destroy()
        device.destroy()
        pipe = nil
        interface = nil
    }
}

#endif
