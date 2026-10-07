// SPDX-License-Identifier: GPL-2.0-or-later
//
// Random values that fit a schema's types: for tests of the encoders and for the tool that makes ATN traffic to compare
// with another decoder. Written for this package.
import Foundation

/// A small seeded generator (SplitMix64), so that a seed always gives the same values.
public struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    public init(state: UInt64) { self.state = state }
    public mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// Makes random values that fit a schema's types, for round-trip tests.
public struct ASN1RandomValues {
    let schema: ASN1Schema
    var generator: SplitMix64
    /// Extension additions are used now and then.
    public var useExtensions = true

    public init(schema: ASN1Schema, seed: UInt64) { self.schema = schema; generator = SplitMix64(state: seed) }

    private mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &generator) }

    public mutating func value(_ type: ASN1Type) throws -> ASN1Value {
        switch try schema.resolve(type) {
        case .reference, .tagged: throw ASN1Failure.syntax("reference")
        case .any: return .opaque((0..<int(0...6)).map { _ in UInt8(int(0...255)) })
        case .boolean: return .boolean(int(0...1) == 1)
        case .null: return .null
        case .integer(let range, _):
            let lower = range?.lower ?? -1000, upper = range?.upper ?? (range?.lower.map { $0 + 100_000 } ?? 1000)
            // Mostly small and the extremes, as the edges are where encodings go wrong.
            switch int(0...5) {
            case 0: return .integer(lower)
            case 1: return .integer(upper)
            default: return .integer(int(lower...max(lower, min(upper, lower + 1_000_000))))
            }
        case .enumerated(let spec):
            if spec.extensible, !spec.additions.isEmpty, useExtensions, int(0...9) == 0 {
                let item = spec.additions[int(0...(spec.additions.count - 1))]
                return .enumerated(name: item.name, value: item.value)
            }
            let item = spec.root[int(0...(spec.root.count - 1))]
            return .enumerated(name: item.name, value: item.value)
        case .bitString(let size):
            return .bitString((0..<length(size)).map { _ in UInt8(int(0...1)) })
        case .octetString(let size):
            return .octetString((0..<length(size)).map { _ in UInt8(int(0...255)) })
        case .string(let kind, let size):
            let alphabet = kind == .numeric ? Array(" 0123456789") : Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,/-")
            return .string(String((0..<length(size)).map { _ in alphabet[int(0...(alphabet.count - 1))] }))
        case .objectIdentifier: return .objectIdentifier([1, 3, 27, int(0...300)], relative: false)
        case .relativeOID: return .objectIdentifier([int(0...20), int(0...300), int(0...20000)], relative: true)
        case .sequenceOf(let element, let size):
            return .list(try (0..<length(size, cap: 3)).map { _ in try value(element) })
        case .sequence(let root, let additions, _):
            var fields: [ASN1Field] = []
            for component in root where !(component.optional || component.hasDefault) || int(0...1) == 1 {
                fields.append(ASN1Field(name: component.name, value: try value(component.type)))
            }
            if useExtensions, !additions.isEmpty, int(0...3) == 0 {
                for component in additions where int(0...1) == 1 { fields.append(ASN1Field(name: component.name, value: try value(component.type))) }
            }
            return .sequence(fields)
        case .choice(let root, let additions, _, _):
            if useExtensions, !additions.isEmpty, int(0...9) == 0 {
                let alternative = additions[int(0...(additions.count - 1))]
                return .choice(name: alternative.name, try value(alternative.type))
            }
            let alternative = root[int(0...(root.count - 1))]
            return .choice(name: alternative.name, try value(alternative.type))
        }
    }

    private mutating func length(_ size: ASN1Size?, cap: Int = 40) -> Int {
        guard let size else { return int(0...cap) }
        let upper = min(size.upper ?? size.lower + cap, size.lower + cap)
        return int(size.lower...max(size.lower, upper))
    }
}

