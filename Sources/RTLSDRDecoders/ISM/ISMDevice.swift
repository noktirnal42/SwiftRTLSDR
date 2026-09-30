// SPDX-License-Identifier: GPL-2.0-or-later
//
// The device-decoder interface and the report format of the ISM decoders, modelled on rtl_433's r_device.h and its
// JSON output (output_file.c; GPL-2.0-or-later, release 25.02). See PROVENANCE.md.
import Foundation

/// How a sensor keys its bits onto the carrier, i.e. which pulse slicer turns its pulses into bits.
public enum ISMModulation: Sendable {
    /// OOK, non-return-to-zero or return-to-zero: a pulse is 1, no pulse is 0.
    case ookPCM
    /// OOK, pulse position: the gap's width carries the bit (short 0, long 1).
    case ookPPM
    /// OOK, pulse width: the pulse's width carries the bit (short 1, long 0).
    case ookPWM
    /// OOK, Manchester with a hard-coded leading zero (Oregon Scientific style).
    case ookManchesterZeroBit
    /// FSK, non-return-to-zero.
    case fskPCM
    /// FSK, pulse width.
    case fskPWM
    /// FSK, Manchester.
    case fskManchesterZeroBit

    var isFSK: Bool {
        switch self {
        case .fskPCM, .fskPWM, .fskManchesterZeroBit: return true
        default: return false
        }
    }
}

/// A protocol's timings in microseconds, as rtl_433's device definitions give them (0 = not used).
public struct ISMTiming: Sendable {
    public var short: Float
    public var long: Float
    public var reset: Float
    public var gap: Float = 0
    public var sync: Float = 0
    public var tolerance: Float = 0
}

/// What a decoder says about a bit buffer, with rtl_433's codes.
public enum DecodeStatus {
    public static let failOther = 0
    public static let abortLength = -1
    public static let abortEarly = -2
    public static let failMIC = -3
    public static let failSanity = -4
}

/// A sensor protocol: its modulation and timings, and a decoder from bits to reports.
public protocol ISMDevice: Sendable {
    /// rtl_433's description of the protocol.
    var name: String { get }
    /// rtl_433's protocol number (its `-R` option), so outputs can be compared decoder for decoder.
    var protocolNumber: Int { get }
    var modulation: ISMModulation { get }
    var timing: ISMTiming { get }
    /// Lower runs first; a later priority runs only if nothing earlier decoded the package.
    var priority: Int { get }
    /// Decodes the rows; appends a report per message. Returns the number of messages (> 0) or a `DecodeStatus`.
    func decode(_ bits: inout BitBuffer, into reports: inout [ISMReport]) -> Int
}

extension ISMDevice {
    public var priority: Int { 0 }
}

/// One decoded message: named fields in rtl_433's order and with its names ("model", "id", "temperature_C", ...).
public struct ISMReport: Sendable, Equatable, CustomStringConvertible {
    public enum Value: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, CustomStringConvertible {
        case int(Int)
        case double(Double)
        case string(String)

        public init(stringLiteral value: String) { self = .string(value) }
        public init(integerLiteral value: Int) { self = .int(value) }

        /// A single-precision value, as rtl_433 computes most readings (printed through a double).
        public static func float(_ value: Float) -> Value { .double(Double(value)) }
        /// An `int` field holding an unsigned 32-bit value, which rtl_433 prints as a signed int.
        public static func int32(_ value: UInt32) -> Value { .int(Int(Int32(bitPattern: value))) }

        public var description: String {
            switch self {
            case .int(let value): return String(value)
            case .double(let value): return String(format: "%.3f", value)
            case .string(let value): return value
            }
        }

        var json: String {
            switch self {
            case .int, .double: return description
            case .string(let value): return ISMReport.jsonString(value)
            }
        }
    }

    public struct Field: Sendable, Equatable {
        public let key: String
        public let value: Value
    }

    public private(set) var fields: [Field]

    /// Fields in order; nil values are left out (rtl_433's `DATA_COND`).
    public init(_ fields: KeyValuePairs<String, Value?>) {
        self.fields = fields.compactMap { key, value in value.map { Field(key: key, value: $0) } }
    }

    public mutating func append(_ key: String, _ value: Value) { fields.append(Field(key: key, value: value)) }

    public subscript(key: String) -> Value? { fields.first { $0.key == key }?.value }

    public var model: String {
        if case .string(let model)? = self["model"] { return model }
        return ""
    }

    /// rtl_433's `-F json` line: `{"time" : "@0.091892s", "model" : "Nexus-TH", "id" : 181, ...}`.
    public func json(time: String? = nil) -> String {
        var parts: [String] = []
        if let time { parts.append("\"time\" : " + Self.jsonString(time)) }
        parts += fields.map { Self.jsonString($0.key) + " : " + $0.value.json }
        return "{" + parts.joined(separator: ", ") + "}"
    }

    public var description: String {
        fields.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }

    static func jsonString(_ text: String) -> String {
        var out = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\r": out += "\\r"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default: out.unicodeScalars.append(character)
            }
        }
        return out + "\""
    }
}
