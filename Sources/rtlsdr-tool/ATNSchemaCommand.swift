// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRDecoders

/// `atn-schema` (for development): the PER-visible constraints of every named type in the packaged ASN.1 modules, one JSON
/// object a line, for Tools/atn-schema-compare.py.
func atnSchema(_ arguments: Arguments) {
    let schema: ASN1Schema
    do { schema = try ATNSchema.make() } catch { fail("\(error)") }
    func tuple(_ lower: Int?, _ upper: Int?, _ extensible: Bool) -> String { "[\(lower.map(String.init) ?? "null"), \(upper.map(String.init) ?? "null"), \(extensible)]" }
    for name in schema.types.keys.sorted() {
        var type = schema.types[name]!
        // Follow a tagged wrapper, but not a plain reference (that type's own entry covers it).
        while case .tagged(_, let inner) = type { type = inner }
        var kind = "other", value = "null", size = "null"
        switch type {
        case .integer(let range, _): kind = "integer"; if let range { value = tuple(range.lower, range.upper, range.extensible) }
        case .enumerated(let spec): kind = "enumerated"; value = tuple(0, max(0, spec.root.count - 1), spec.extensible)
        case .bitString(let s): kind = "bitstring"; if let s { size = tuple(s.lower, s.upper, s.extensible) }
        case .octetString(let s): kind = "octetstring"; if let s { size = tuple(s.lower, s.upper, s.extensible) }
        case .string(_, let s): kind = "string"; if let s { size = tuple(s.lower, s.upper, s.extensible) }
        case .sequenceOf(_, let s): kind = "sequenceof"; if let s { size = tuple(s.lower, s.upper, s.extensible) }
        case .choice(let root, _, let extensible, _): kind = "choice"; value = tuple(0, max(0, root.count - 1), extensible)
        case .sequence(_, _, let extensible): kind = "sequence"; value = tuple(nil, nil, extensible)
        default: break
        }
        // A SEQUENCE's or CHOICE's members, each with the name of its type when that is a named one.
        var members = "[]"
        func list(_ root: [ASN1Component], _ additions: [ASN1Component]) -> String {
            "[" + (root + additions).map { c -> String in
                var reference = "null"
                if case .reference(let r) = c.type { reference = "\"\(r.split(separator: ".").last!)\"" }
                else if case .tagged(_, .reference(let r)) = c.type { reference = "\"\(r.split(separator: ".").last!)\"" }
                return "{\"name\": \"\(c.name)\", \"type\": \(reference)}"
            }.joined(separator: ", ") + "]"
        }
        if case .sequence(let root, let additions, _) = type { members = list(root, additions) }
        if case .choice(let root, let additions, _, _) = type { members = list(root, additions) }
        print("{\"name\": \"\(name)\", \"kind\": \"\(kind)\", \"value\": \(value), \"size\": \(size), \"members\": \(members)}")
    }
}
