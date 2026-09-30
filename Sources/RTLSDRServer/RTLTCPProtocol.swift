// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The `rtl_tcp` wire format, which SDR# , GQRX, SDR++, OpenWebRX and many others speak.
///
/// On connect the server sends a 12-byte header (`"RTL0"`, the tuner type, the number of gain steps, both 32-bit
/// big-endian), then nothing but raw interleaved unsigned 8-bit I/Q. The client sends 5-byte commands: a command byte
/// and a 32-bit big-endian parameter. Codes and meanings follow `rtl_tcp.c` in librtlsdr 2.0.2.
public enum RTLTCP {
    public static let headerSize = 12
    public static let commandSize = 5
    /// `enum rtlsdr_tuner` in librtlsdr: unknown 0, E4000 1, FC0012 2, FC0013 3, FC2580 4, R820T 5, R828D 6.
    public static let tunerTypeR820T: UInt32 = 5

    public struct Header: Sendable, Equatable {
        public var tunerType: UInt32
        public var gainCount: UInt32

        public init(tunerType: UInt32, gainCount: UInt32) {
            self.tunerType = tunerType
            self.gainCount = gainCount
        }

        public var bytes: [UInt8] { Array("RTL0".utf8) + bigEndian(tunerType) + bigEndian(gainCount) }

        public init?(bytes: [UInt8]) {
            guard bytes.count == RTLTCP.headerSize, Array(bytes[0..<4]) == Array("RTL0".utf8) else { return nil }
            tunerType = readBigEndian(bytes[4..<8])
            gainCount = readBigEndian(bytes[8..<12])
        }
    }

    public enum Command: Sendable, Equatable {
        case setFrequency(UInt32)
        case setSampleRate(UInt32)
        /// true = manual gain, false = the tuner's automatic gain.
        case setGainMode(manual: Bool)
        /// Tenths of a dB.
        case setGain(Int32)
        case setFrequencyCorrection(ppm: Int32)
        /// E4000 IF gain stages; meaningless for the R820T.
        case setIFGain(stage: UInt16, gain: Int16)
        case setTestMode(Bool)
        /// The RTL2832U's digital AGC.
        case setAGCMode(Bool)
        case setDirectSampling(UInt32)
        case setOffsetTuning(Bool)
        case setRTLCrystal(UInt32)
        case setTunerCrystal(UInt32)
        case setGainByIndex(UInt32)
        case setBiasTee(Bool)
        case unknown(code: UInt8, parameter: UInt32)

        public init?(bytes: [UInt8]) {
            guard bytes.count == RTLTCP.commandSize else { return nil }
            let parameter: UInt32 = readBigEndian(bytes[1..<5])
            let signed = Int32(bitPattern: parameter)
            switch bytes[0] {
            case 0x01: self = .setFrequency(parameter)
            case 0x02: self = .setSampleRate(parameter)
            case 0x03: self = .setGainMode(manual: parameter != 0)
            case 0x04: self = .setGain(signed)
            case 0x05: self = .setFrequencyCorrection(ppm: signed)
            case 0x06: self = .setIFGain(stage: UInt16(parameter >> 16), gain: Int16(truncatingIfNeeded: parameter & 0xffff))
            case 0x07: self = .setTestMode(parameter != 0)
            case 0x08: self = .setAGCMode(parameter != 0)
            case 0x09: self = .setDirectSampling(parameter)
            case 0x0a: self = .setOffsetTuning(parameter != 0)
            case 0x0b: self = .setRTLCrystal(parameter)
            case 0x0c: self = .setTunerCrystal(parameter)
            case 0x0d: self = .setGainByIndex(parameter)
            case 0x0e: self = .setBiasTee(parameter != 0)
            default: self = .unknown(code: bytes[0], parameter: parameter)
            }
        }

        public var bytes: [UInt8] {
            let (code, parameter): (UInt8, UInt32)
            switch self {
            case let .setFrequency(hz): (code, parameter) = (0x01, hz)
            case let .setSampleRate(rate): (code, parameter) = (0x02, rate)
            case let .setGainMode(manual): (code, parameter) = (0x03, manual ? 1 : 0)
            case let .setGain(tenths): (code, parameter) = (0x04, UInt32(bitPattern: tenths))
            case let .setFrequencyCorrection(ppm): (code, parameter) = (0x05, UInt32(bitPattern: ppm))
            case let .setIFGain(stage, gain): (code, parameter) = (0x06, UInt32(stage) << 16 | UInt32(UInt16(bitPattern: gain)))
            case let .setTestMode(on): (code, parameter) = (0x07, on ? 1 : 0)
            case let .setAGCMode(on): (code, parameter) = (0x08, on ? 1 : 0)
            case let .setDirectSampling(mode): (code, parameter) = (0x09, mode)
            case let .setOffsetTuning(on): (code, parameter) = (0x0a, on ? 1 : 0)
            case let .setRTLCrystal(hz): (code, parameter) = (0x0b, hz)
            case let .setTunerCrystal(hz): (code, parameter) = (0x0c, hz)
            case let .setGainByIndex(index): (code, parameter) = (0x0d, index)
            case let .setBiasTee(on): (code, parameter) = (0x0e, on ? 1 : 0)
            case let .unknown(unknownCode, unknownParameter): (code, parameter) = (unknownCode, unknownParameter)
            }
            return [code] + bigEndian(parameter)
        }
    }
}

private func bigEndian(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
}

private func readBigEndian(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    bytes.reduce(0) { $0 << 8 | UInt32($1) }
}
