// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum RTLSDRError: Error, LocalizedError, Equatable, Sendable {
    case noDeviceFound
    case deviceNotFound(serial: String)
    case openFailed(String)
    case usb(String)
    case shortTransfer(expected: Int, actual: Int)
    case unsupportedTuner
    case invalidSampleRate(Int)
    case frequencyOutOfRange(Int)
    case frequencyCorrectionOutOfRange(Int)
    case pllOutOfRange(frequencyHz: Int)
    case alreadyStreaming
    case closed
    case eepromMalformed(String)
    case eepromHeaderProtected(offset: Int)
    case eepromVerifyFailed(offsets: [Int])
    case invalidSerial(String)

    public var errorDescription: String? {
        switch self {
        case .noDeviceFound:
            return "No RTL-SDR device was found. Check the USB connection."
        case let .deviceNotFound(serial):
            return "No RTL-SDR with serial \(serial) is connected."
        case let .openFailed(reason):
            return "Could not open the RTL-SDR: \(reason)"
        case let .usb(reason):
            return "USB transfer failed: \(reason)"
        case let .shortTransfer(expected, actual):
            return "USB transfer moved \(actual) of \(expected) bytes."
        case .unsupportedTuner:
            return "This dongle's tuner chip is not supported yet (only the Rafael Micro R820T is)."
        case let .invalidSampleRate(rate):
            return "\(rate) S/s is not a sample rate the RTL2832U can produce (225-300 kS/s or 900 kS/s-3.2 MS/s)."
        case let .frequencyOutOfRange(hz):
            return "\(hz) Hz is outside what the tuner can reach."
        case let .frequencyCorrectionOutOfRange(ppm):
            return "A correction of \(ppm) ppm is more than the demodulator can hold (±488 ppm)."
        case let .pllOutOfRange(hz):
            return "The tuner's oscillator cannot be programmed for \(hz) Hz."
        case .alreadyStreaming:
            return "The device is already streaming."
        case .closed:
            return "The device has been closed."
        case let .eepromMalformed(reason):
            return "The EEPROM contents are not in the expected layout: \(reason)."
        case let .eepromHeaderProtected(offset):
            return String(format: "Refusing to write EEPROM offset 0x%02x: bytes 0-8 hold the USB IDs and flags, and this driver never writes them.", offset)
        case let .eepromVerifyFailed(offsets):
            return "The EEPROM did not read back as written at offsets \(offsets.map { String(format: "0x%02x", $0) }.joined(separator: ", ")). Restore from the backup."
        case let .invalidSerial(reason):
            return "Invalid serial number: \(reason)."
        }
    }

    /// Turns the IOKit code behind a failed open into a message that says what is actually wrong. macOS reports
    /// "Failed to create IOUSBHostObject" whether another program has the dongle, the sandbox denied access, or
    /// the dongle went away, so the code is what tells them apart.
    public static func explainOpenFailure(code: Int, description: String) -> String {
        let unsigned = UInt32(truncatingIfNeeded: code)
        let hex = String(format: "0x%08x", unsigned)
        let cleaned = description.hasSuffix(".") ? String(description.dropLast()) : description
        switch unsigned {
        case 0xe00002c5, 0xe00002d5:      // exclusive access, busy
            return "\(cleaned) (IOKit \(hex)): another program has the dongle open. Only one program can use it at a time."
        case 0xe00002e2, 0xe00002c1:      // not permitted, not privileged
            return "\(cleaned) (IOKit \(hex)): macOS denied access to the USB device. A sandboxed app needs the com.apple.security.device.usb entitlement."
        case 0xe00002c0:                  // no device
            return "\(cleaned) (IOKit \(hex)): the dongle was unplugged or is no longer responding."
        default:
            return "\(cleaned) (IOKit \(hex))."
        }
    }
}
