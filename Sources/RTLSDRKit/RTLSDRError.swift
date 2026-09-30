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
    case pllOutOfRange(frequencyHz: Int)
    case alreadyStreaming
    case closed

    public var errorDescription: String? {
        switch self {
        case .noDeviceFound:
            return "No RTL-SDR device was found. Check the USB connection."
        case let .deviceNotFound(serial):
            return "No RTL-SDR with serial \(serial) is connected."
        case let .openFailed(reason):
            return "Could not open the RTL-SDR: \(reason). Another program may be using it; only one can at a time."
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
        case let .pllOutOfRange(hz):
            return "The tuner's oscillator cannot be programmed for \(hz) Hz."
        case .alreadyStreaming:
            return "The device is already streaming."
        case .closed:
            return "The device has been closed."
        }
    }
}
