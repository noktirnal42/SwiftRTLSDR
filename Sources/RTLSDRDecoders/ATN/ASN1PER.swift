// SPDX-License-Identifier: GPL-2.0-or-later
//
// Unaligned packed encoding rules (ITU-T X.691, the UPER variant): a decoder and an encoder for the schema model, and the
// value tree they work on. Written for this package from X.691. dumpvdl2's asn1c-generated decoders are the oracle.
import Foundation

public struct ASN1Field: Sendable, Equatable {
    public var name: String
    public var value: ASN1Value
}

public indirect enum ASN1Value: Sendable, Equatable {
    case boolean(Bool)
    case integer(Int)
    case enumerated(name: String, value: Int)
    /// One 0 or 1 per element.
    case bitString([UInt8])
    case octetString([UInt8])
    case string(String)
    case null
    case objectIdentifier([Int], relative: Bool)
    case sequence([ASN1Field])
    case choice(name: String, ASN1Value)
    case list([ASN1Value])
    /// An extension the schema does not know, as the octets of its open type.
    case opaque([UInt8])
}

struct PERReader {
    let bytes: [UInt8]
    private(set) var position = 0                    // in bits

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remainingBits: Int { bytes.count * 8 - position }

    mutating func read(_ count: Int) throws -> Int {
        guard count >= 0, count <= 62 else { throw ASN1Failure.unsupported("a field of \(count) bits") }
        guard remainingBits >= count else { throw ASN1Failure.truncated }
        var value = 0
        var left = count
        while left > 0 {
            let byte = Int(bytes[position >> 3]), offset = position & 7
            let take = min(left, 8 - offset)
            value = value << take | (byte >> (8 - offset - take)) & ((1 << take) - 1)
            position += take
            left -= take
        }
        return value
    }

    mutating func bit() throws -> Bool { try read(1) == 1 }

    mutating func octets(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remainingBits >= count * 8 else { throw ASN1Failure.truncated }
        return try (0..<count).map { _ in UInt8(try read(8)) }
    }
}

struct PERWriter {
    private(set) var bytes: [UInt8] = []
    private(set) var bitCount = 0

    mutating func write(_ value: Int, _ count: Int) {
        for k in stride(from: count - 1, through: 0, by: -1) {
            if bitCount & 7 == 0 { bytes.append(0) }
            if value >> k & 1 == 1 { bytes[bitCount >> 3] |= 0x80 >> UInt8(bitCount & 7) }
            bitCount += 1
        }
    }

    mutating func write(octets: [UInt8]) { for byte in octets { write(Int(byte), 8) } }

    /// The encoding padded to a whole number of octets (an empty encoding is one zero octet, as X.691 10.1.3 has it).
    var complete: [UInt8] { bytes.isEmpty ? [0] : bytes }
}

private func widthFor(range: Int) -> Int { range <= 1 ? 0 : Int.bitWidth - (range - 1).leadingZeroBitCount }

private let numericAlphabet = Array(" 0123456789")

/// The tag a CHOICE alternative sorts by: its explicit one, or its type's universal one.
private func sortKey(_ component: ASN1Component, in schema: ASN1Schema) -> (Int, Int) {
    if let tag = component.tag { return (tag.tagClass, tag.number) }
    if let tag = schema.outerTag(of: component.type) { return (tag.tagClass, tag.number) }
    guard let type = try? schema.resolve(component.type) else { return (0, 1000) }
    switch type {
    case .boolean: return (0, 1)
    case .integer: return (0, 2)
    case .bitString: return (0, 3)
    case .octetString: return (0, 4)
    case .null: return (0, 5)
    case .objectIdentifier: return (0, 6)
    case .enumerated: return (0, 10)
    case .relativeOID: return (0, 13)
    case .sequence, .sequenceOf: return (0, 16)
    case .string(let kind, _):
        switch kind { case .utf8: return (0, 12); case .numeric: return (0, 18); case .printable: return (0, 19); case .ia5: return (0, 22); case .visible: return (0, 26) }
    case .choice, .reference, .any, .tagged: return (0, 1000)
    }
}

extension ASN1Schema {
    /// The tag a type carries itself (through references), if any.
    func outerTag(of type: ASN1Type) -> ASN1Tag? {
        var current = type
        for _ in 0..<64 {
            switch current {
            case .tagged(let tag, _): return tag
            case .reference(let name): guard let next = types[name] else { return nil }; current = next
            default: return nil
            }
        }
        return nil
    }

    /// A CHOICE's root alternatives in the order PER indexes them.
    func canonical(_ root: [ASN1Component], automaticTags: Bool) -> [ASN1Component] {
        guard !automaticTags else { return root }
        return root.enumerated().sorted { a, b in
            let ka = sortKey(a.element, in: self), kb = sortKey(b.element, in: self)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
    }

    /// Decodes a complete encoding (as the top-level type of a message) of the named type.
    public func decode(_ name: String, _ bytes: [UInt8]) throws -> ASN1Value {
        var reader = PERReader(bytes)
        return try decode(try type(named: name), &reader)
    }

    /// Encodes `value` as the named top-level type.
    public func encode(_ name: String, _ value: ASN1Value) throws -> [UInt8] {
        var writer = PERWriter()
        try encode(try type(named: name), value, &writer)
        return writer.complete
    }

    // MARK: Decoding

    private func generalLength(_ r: inout PERReader) throws -> Int {
        let first = try r.read(8)
        if first & 0x80 == 0 { return first }
        if first & 0xC0 == 0x80 { return (first & 0x3F) << 8 | (try r.read(8)) }
        throw ASN1Failure.unsupported("a fragmented length")
    }

    private func normallySmallNumber(_ r: inout PERReader) throws -> Int {
        if !(try r.bit()) { return try r.read(6) }
        let length = try generalLength(&r)
        return try (0..<length).reduce(0) { acc, _ in acc << 8 | (try r.read(8)) }
    }

    private func normallySmallLength(_ r: inout PERReader) throws -> Int {
        if !(try r.bit()) { return try r.read(6) + 1 }
        return try generalLength(&r)
    }

    private func constrained(_ r: inout PERReader, lower: Int, upper: Int) throws -> Int {
        let width = widthFor(range: upper - lower + 1)
        let value = lower + (width == 0 ? 0 : try r.read(width))
        guard value <= upper else { throw ASN1Failure.constraint("\(value) above \(upper)") }
        return value
    }

    /// A length governed by `size`: nothing for a fixed size, a bit-field for a small range, the general form otherwise.
    private func sizedLength(_ r: inout PERReader, _ size: ASN1Size?) throws -> Int {
        guard let size else { return try generalLength(&r) }
        if size.extensible, try r.bit() { return try generalLength(&r) }
        if let upper = size.upper {
            if upper == size.lower { return upper }
            if upper < 65536 { return try constrained(&r, lower: size.lower, upper: upper) }
        }
        return try generalLength(&r)
    }

    private func openType(_ r: inout PERReader) throws -> [UInt8] { try r.octets(try generalLength(&r)) }

    func decode(_ type: ASN1Type, _ r: inout PERReader) throws -> ASN1Value {
        switch try resolve(type) {
        case .reference, .tagged: throw ASN1Failure.syntax("unresolved reference")
        case .any: return .opaque(try openType(&r))
        case .boolean: return .boolean(try r.bit())
        case .null: return .null
        case .integer(let range, let names):
            _ = names
            if let range, range.extensible, try r.bit() { return .integer(try unconstrainedInteger(&r)) }
            if let range, let lower = range.lower, let upper = range.upper {
                return .integer(try constrained(&r, lower: lower, upper: upper))
            }
            if let range, let lower = range.lower {
                let length = try generalLength(&r)
                return .integer(lower + (try (0..<length).reduce(0) { acc, _ in acc << 8 | (try r.read(8)) }))
            }
            return .integer(try unconstrainedInteger(&r))
        case .enumerated(let spec):
            if spec.extensible, try r.bit() {
                let index = try normallySmallNumber(&r)
                guard index < spec.additions.count else { return .enumerated(name: "extension#\(index)", value: index) }
                return .enumerated(name: spec.additions[index].name, value: spec.additions[index].value)
            }
            let index = try constrained(&r, lower: 0, upper: max(0, spec.root.count - 1))
            guard index < spec.root.count else { throw ASN1Failure.constraint("enumeration index \(index)") }
            return .enumerated(name: spec.root[index].name, value: spec.root[index].value)
        case .bitString(let size):
            let length = try sizedLength(&r, size)
            return .bitString(try (0..<length).map { _ in UInt8(try r.read(1)) })
        case .octetString(let size):
            return .octetString(try r.octets(try sizedLength(&r, size)))
        case .string(let kind, let size):
            if kind == .utf8 { return .string(String(decoding: try r.octets(try sizedLength(&r, nil)), as: UTF8.self)) }
            let length = try sizedLength(&r, size)
            let width = kind == .numeric ? 4 : 7
            var text = ""
            for _ in 0..<length {
                let value = try r.read(width)
                if kind == .numeric {
                    guard value < numericAlphabet.count else { throw ASN1Failure.constraint("NumericString character \(value)") }
                    text.append(numericAlphabet[value])
                } else {
                    text.unicodeScalars.append(Unicode.Scalar(UInt8(value)))
                }
            }
            return .string(text)
        case .objectIdentifier, .relativeOID:
            let bytes = try openType(&r)
            var arcs: [Int] = [], current = 0
            for byte in bytes {
                current = current << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { arcs.append(current); current = 0 }
            }
            var isRelative = true
            if case .objectIdentifier = try resolve(type) {
                isRelative = false
                if let first = arcs.first { arcs = first < 40 ? [0, first] + arcs.dropFirst() : first < 80 ? [1, first - 40] + arcs.dropFirst() : [2, first - 80] + arcs.dropFirst() }
            }
            return .objectIdentifier(arcs, relative: isRelative)
        case .sequenceOf(let element, let size):
            let count = try sizedLength(&r, size)
            return .list(try (0..<count).map { _ in try decode(element, &r) })
        case .sequence(let root, let additions, let extensible):
            let hasExtension = extensible ? try r.bit() : false
            let optionals = try root.filter { $0.optional || $0.hasDefault }.map { _ in try r.bit() }
            var fields: [ASN1Field] = []
            var presence = optionals.makeIterator()
            for component in root {
                if component.optional || component.hasDefault, presence.next() != true { continue }
                fields.append(ASN1Field(name: component.name, value: try decode(component.type, &r)))
            }
            if hasExtension {
                let count = try normallySmallLength(&r)
                let bitmap = try (0..<count).map { _ in try r.bit() }
                for (index, present) in bitmap.enumerated() where present {
                    let bytes = try openType(&r)
                    if index < additions.count {
                        var inner = PERReader(bytes)
                        fields.append(ASN1Field(name: additions[index].name, value: try decode(additions[index].type, &inner)))
                    } else {
                        fields.append(ASN1Field(name: "extension#\(index)", value: .opaque(bytes)))
                    }
                }
            }
            return .sequence(fields)
        case .choice(let root, let additions, let extensible, let automatic):
            if extensible, try r.bit() {
                let index = try normallySmallNumber(&r)
                let bytes = try openType(&r)
                guard index < additions.count else { return .choice(name: "extension#\(index)", .opaque(bytes)) }
                var inner = PERReader(bytes)
                return .choice(name: additions[index].name, try decode(additions[index].type, &inner))
            }
            let ordered = canonical(root, automaticTags: automatic)
            let index = try constrained(&r, lower: 0, upper: max(0, ordered.count - 1))
            guard index < ordered.count else { throw ASN1Failure.constraint("choice index \(index)") }
            return .choice(name: ordered[index].name, try decode(ordered[index].type, &r))
        }
    }

    private func unconstrainedInteger(_ r: inout PERReader) throws -> Int {
        let length = try generalLength(&r)
        guard length > 0, length <= 8 else { throw ASN1Failure.unsupported("an integer of \(length) octets") }
        var value = Int(Int8(bitPattern: UInt8(try r.read(8))))
        for _ in 1..<length { value = value << 8 | (try r.read(8)) }
        return value
    }

    // MARK: Encoding

    private func writeGeneralLength(_ n: Int, _ w: inout PERWriter) throws {
        if n < 128 { w.write(n, 8) } else if n < 16384 { w.write(0x8000 | n, 16) } else { throw ASN1Failure.unsupported("a fragmented length") }
    }

    private func writeNormallySmallNumber(_ n: Int, _ w: inout PERWriter) throws {
        if n < 64 { w.write(0, 1); w.write(n, 6); return }
        w.write(1, 1)
        var bytes: [UInt8] = []
        var rest = n
        repeat { bytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 } while rest > 0
        try writeGeneralLength(bytes.count, &w)
        w.write(octets: bytes)
    }

    private func writeConstrained(_ value: Int, lower: Int, upper: Int, _ w: inout PERWriter) throws {
        guard value >= lower, value <= upper else { throw ASN1Failure.constraint("\(value) outside \(lower)..\(upper)") }
        w.write(value - lower, widthFor(range: upper - lower + 1))
    }

    private func writeSizedLength(_ n: Int, _ size: ASN1Size?, _ w: inout PERWriter) throws {
        guard let size else { try writeGeneralLength(n, &w); return }
        let inRoot = n >= size.lower && (size.upper.map { n <= $0 } ?? true)
        if size.extensible { w.write(inRoot ? 0 : 1, 1) }
        if !inRoot {
            guard size.extensible else { throw ASN1Failure.constraint("length \(n)") }
            try writeGeneralLength(n, &w)
            return
        }
        if let upper = size.upper {
            if upper == size.lower { return }
            if upper < 65536 { try writeConstrained(n, lower: size.lower, upper: upper, &w); return }
        }
        try writeGeneralLength(n, &w)
    }

    func encode(_ type: ASN1Type, _ value: ASN1Value, _ w: inout PERWriter) throws {
        func mismatch() -> ASN1Failure { ASN1Failure.syntax("a value that does not fit its type") }
        switch (try resolve(type), value) {
        case (.any, .opaque(let bytes)): try writeGeneralLength(bytes.count, &w); w.write(octets: bytes)
        case (.boolean, .boolean(let b)): w.write(b ? 1 : 0, 1)
        case (.null, .null): break
        case (.integer(let range, _), .integer(let n)):
            let inRoot = (range?.lower.map { n >= $0 } ?? true) && (range?.upper.map { n <= $0 } ?? true)
            if let range, range.extensible { w.write(inRoot ? 0 : 1, 1) }
            if let range, inRoot, let lower = range.lower, let upper = range.upper { try writeConstrained(n, lower: lower, upper: upper, &w); return }
            if let range, inRoot, let lower = range.lower {
                var bytes: [UInt8] = []
                var rest = n - lower
                repeat { bytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 } while rest > 0
                try writeGeneralLength(bytes.count, &w)
                w.write(octets: bytes)
                return
            }
            guard inRoot || (range?.extensible ?? false) else { throw ASN1Failure.constraint("integer \(n)") }
            var bytes: [UInt8] = []
            var rest = n
            repeat { bytes.insert(UInt8(truncatingIfNeeded: rest), at: 0); rest >>= 8 } while !((rest == 0 && bytes[0] & 0x80 == 0) || (rest == -1 && bytes[0] & 0x80 != 0))
            try writeGeneralLength(bytes.count, &w)
            w.write(octets: bytes)
        case (.enumerated(let spec), .enumerated(_, let number)):
            if let index = spec.root.firstIndex(where: { $0.value == number }) {
                if spec.extensible { w.write(0, 1) }
                try writeConstrained(index, lower: 0, upper: max(0, spec.root.count - 1), &w)
            } else if let index = spec.additions.firstIndex(where: { $0.value == number }) {
                w.write(1, 1)
                try writeNormallySmallNumber(index, &w)
            } else { throw ASN1Failure.constraint("enumeration value \(number)") }
        case (.bitString(let size), .bitString(let bits)):
            try writeSizedLength(bits.count, size, &w)
            for bit in bits { w.write(Int(bit), 1) }
        case (.octetString(let size), .octetString(let bytes)):
            try writeSizedLength(bytes.count, size, &w)
            w.write(octets: bytes)
        case (.string(let kind, let size), .string(let text)):
            if kind == .utf8 { let bytes = Array(text.utf8); try writeGeneralLength(bytes.count, &w); w.write(octets: bytes); return }
            let scalars = Array(text.unicodeScalars)
            try writeSizedLength(scalars.count, size, &w)
            for scalar in scalars {
                if kind == .numeric {
                    guard let index = numericAlphabet.firstIndex(of: Character(scalar)) else { throw ASN1Failure.constraint("NumericString character") }
                    w.write(index, 4)
                } else {
                    guard scalar.value < 128 else { throw ASN1Failure.constraint("a character outside ASCII") }
                    w.write(Int(scalar.value), 7)
                }
            }
        case (.objectIdentifier, .objectIdentifier(let arcs, let relative)), (.relativeOID, .objectIdentifier(let arcs, let relative)):
            var list = arcs
            if !relative, list.count >= 2 { list = [list[0] * 40 + list[1]] + list.dropFirst(2) }
            var bytes: [UInt8] = []
            for arc in list {
                var group: [UInt8] = [UInt8(arc & 0x7F)]
                var rest = arc >> 7
                while rest > 0 { group.insert(UInt8(rest & 0x7F) | 0x80, at: 0); rest >>= 7 }
                bytes += group
            }
            try writeGeneralLength(bytes.count, &w)
            w.write(octets: bytes)
        case (.sequenceOf(let element, let size), .list(let items)):
            try writeSizedLength(items.count, size, &w)
            for item in items { try encode(element, item, &w) }
        case (.sequence(let root, let additions, let extensible), .sequence(let fields)):
            let byName = Dictionary(fields.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
            let usedAdditions = additions.enumerated().filter { byName[$0.element.name] != nil }
            if extensible { w.write(usedAdditions.isEmpty ? 0 : 1, 1) }
            for component in root where component.optional || component.hasDefault { w.write(byName[component.name] != nil ? 1 : 0, 1) }
            for component in root {
                if let v = byName[component.name] { try encode(component.type, v, &w) }
                else if !(component.optional || component.hasDefault) { throw ASN1Failure.syntax("missing component \(component.name)") }
            }
            if !usedAdditions.isEmpty {
                let count = (usedAdditions.last!.offset) + 1
                if count <= 64 { w.write(0, 1); w.write(count - 1, 6) } else { w.write(1, 1); try writeGeneralLength(count, &w) }
                for index in 0..<count { w.write(byName[additions[index].name] != nil ? 1 : 0, 1) }
                for index in 0..<count {
                    guard let v = byName[additions[index].name] else { continue }
                    var inner = PERWriter()
                    try encode(additions[index].type, v, &inner)
                    let bytes = inner.complete
                    try writeGeneralLength(bytes.count, &w)
                    w.write(octets: bytes)
                }
            }
        case (.choice(let root, let additions, let extensible, let automatic), .choice(let name, let inner)):
            let ordered = canonical(root, automaticTags: automatic)
            if let index = ordered.firstIndex(where: { $0.name == name }) {
                if extensible { w.write(0, 1) }
                try writeConstrained(index, lower: 0, upper: max(0, ordered.count - 1), &w)
                try encode(ordered[index].type, inner, &w)
            } else if let index = additions.firstIndex(where: { $0.name == name }) {
                w.write(1, 1)
                try writeNormallySmallNumber(index, &w)
                var scratch = PERWriter()
                try encode(additions[index].type, inner, &scratch)
                let bytes = scratch.complete
                try writeGeneralLength(bytes.count, &w)
                w.write(octets: bytes)
            } else { throw ASN1Failure.syntax("no alternative \(name)") }
        default: throw mismatch()
        }
    }
}

// MARK: - Printing

extension ASN1Value {
    /// The value as indented lines of `name: value`.
    public func dump(indent: Int = 0, name: String? = nil) -> String {
        let pad = String(repeating: "  ", count: indent)
        let label = name.map { "\($0): " } ?? ""
        switch self {
        case .boolean(let b): return "\(pad)\(label)\(b)\n"
        case .integer(let n): return "\(pad)\(label)\(n)\n"
        case .enumerated(let name, _): return "\(pad)\(label)\(name)\n"
        case .bitString(let bits): return "\(pad)\(label)\(bits.map(String.init).joined())\n"
        case .octetString(let bytes), .opaque(let bytes): return "\(pad)\(label)" + bytes.map { String(format: "%02x", $0) }.joined() + "\n"
        case .string(let s): return "\(pad)\(label)\"\(s)\"\n"
        case .null: return "\(pad)\(label)NULL\n"
        case .objectIdentifier(let arcs, _): return "\(pad)\(label)" + arcs.map(String.init).joined(separator: ".") + "\n"
        case .sequence(let fields): return "\(pad)\(label){\n" + fields.map { $0.value.dump(indent: indent + 1, name: $0.name) }.joined() + "\(pad)}\n"
        case .choice(let name, let value):
            if case .null = value { return "\(pad)\(label)\(name)\n" }
            return value.dump(indent: indent, name: "\(label)\(name)")
        case .list(let items): return "\(pad)\(label)[\n" + items.map { $0.dump(indent: indent + 1) }.joined() + "\(pad)]\n"
        }
    }
}

extension ASN1Value {
    /// The value as JSON: sequences as objects, choices as `{"choice": name, "value": …}`, lists as arrays, bit strings as
    /// strings of 0 and 1, octets as hexadecimal.
    public var json: String {
        func quote(_ s: String) -> String {
            var out = "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                default: out += scalar.value < 32 || scalar.value == 127 ? String(format: "\\u%04x", scalar.value) : String(scalar)
                }
            }
            return out + "\""
        }
        switch self {
        case .boolean(let b): return b ? "true" : "false"
        case .integer(let n): return String(n)
        case .enumerated(let name, _): return quote(name)
        case .bitString(let bits): return quote(bits.map(String.init).joined())
        case .octetString(let bytes), .opaque(let bytes): return quote(bytes.map { String(format: "%02x", $0) }.joined())
        case .string(let s): return quote(s)
        case .null: return "null"
        case .objectIdentifier(let arcs, _): return quote(arcs.map(String.init).joined(separator: "."))
        case .sequence(let fields): return "{" + fields.map { quote($0.name) + ": " + $0.value.json }.joined(separator: ", ") + "}"
        case .choice(let name, let value): return "{\"choice\": \(quote(name)), \"value\": \(value.json)}"
        case .list(let items): return "[" + items.map(\.json).joined(separator: ", ") + "]"
        }
    }
}
