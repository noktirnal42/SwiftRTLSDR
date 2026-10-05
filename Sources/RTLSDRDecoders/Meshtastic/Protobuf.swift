// SPDX-License-Identifier: GPL-2.0-or-later
//
// The protocol buffers wire format, read without a schema: each field is a key (field number and wire type) and a
// varint, a 32 or 64-bit little-endian word, or a length and that many bytes.
import Foundation

/// One message's fields, in order, from their wire encoding.
public struct ProtobufMessage: Sendable {
    public enum Value: Sendable, Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes([UInt8])
        case fixed32(UInt32)
    }

    public private(set) var fields: [(number: Int, value: Value)] = []

    /// nil if the bytes are not a well-formed message (a truncated field, a group, an unknown wire type).
    public init?(_ bytes: [UInt8]) {
        var index = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0, shift: UInt64 = 0
            while index < bytes.count && shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        func little(_ count: Int) -> UInt64? {
            guard index + count <= bytes.count else { return nil }
            var value: UInt64 = 0
            for k in 0..<count { value |= UInt64(bytes[index + k]) << (8 * UInt64(k)) }
            index += count
            return value
        }
        while index < bytes.count {
            guard let key = varint(), key >> 3 > 0, key >> 3 < 1 << 29 else { return nil }
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = varint() else { return nil }
                fields.append((number, .varint(value)))
            case 1:
                guard let value = little(8) else { return nil }
                fields.append((number, .fixed64(value)))
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - index) else { return nil }
                fields.append((number, .bytes(Array(bytes[index..<(index + Int(length))]))))
                index += Int(length)
            case 5:
                guard let value = little(4) else { return nil }
                fields.append((number, .fixed32(UInt32(value))))
            default:
                return nil
            }
        }
    }

    /// The last value of field `number` (the one that counts for a singular field).
    public func value(_ number: Int) -> Value? { fields.last { $0.number == number }?.value }

    public func values(_ number: Int) -> [Value] { fields.filter { $0.number == number }.map(\.value) }

    public func has(_ number: Int) -> Bool { fields.contains { $0.number == number } }

    /// An unsigned varint or fixed-width field.
    public func unsigned(_ number: Int) -> UInt64? {
        switch value(number) {
        case .varint(let v): return v
        case .fixed32(let v): return UInt64(v)
        case .fixed64(let v): return v
        default: return nil
        }
    }

    /// An `int32`/`int64` varint (two's complement) or an `sfixed32`/`sfixed64`.
    public func signed(_ number: Int) -> Int64? {
        switch value(number) {
        case .varint(let v): return Int64(bitPattern: v)
        case .fixed32(let v): return Int64(Int32(bitPattern: v))
        case .fixed64(let v): return Int64(bitPattern: v)
        default: return nil
        }
    }

    /// A `sint32`/`sint64` (zigzag) varint.
    public func zigzag(_ number: Int) -> Int64? {
        guard case .varint(let v)? = value(number) else { return nil }
        return Int64(bitPattern: v >> 1) ^ -Int64(bitPattern: v & 1)
    }

    /// A `float` field.
    public func float(_ number: Int) -> Float? {
        guard case .fixed32(let v)? = value(number) else { return nil }
        return Float(bitPattern: v)
    }

    public func bytes(_ number: Int) -> [UInt8]? {
        guard case .bytes(let v)? = value(number) else { return nil }
        return v
    }

    /// A `string` field; nil if absent or not UTF-8.
    public func string(_ number: Int) -> String? {
        bytes(number).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    public func message(_ number: Int) -> ProtobufMessage? { bytes(number).flatMap(ProtobufMessage.init) }
}
