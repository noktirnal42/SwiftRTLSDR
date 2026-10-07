// SPDX-License-Identifier: GPL-2.0-or-later
//
// A small ASN.1 schema model and a parser for the subset of the notation the ATN's modules use (ICAO Doc 9705's CPDLC and
// context management, ISO 8650 ACSE and ISO 8823 presentation PDUs as the ATN profiles them): SEQUENCE, CHOICE,
// ENUMERATED, INTEGER, BOOLEAN, NULL, BIT STRING, OCTET STRING, the character strings, SEQUENCE OF, OBJECT IDENTIFIER,
// tags, OPTIONAL, DEFAULT and extension markers. Written for this package from X.680 and X.691.
import Foundation

public struct ASN1Size: Sendable, Equatable {
    public var lower: Int
    /// nil: unbounded.
    public var upper: Int?
    public var extensible: Bool
    var isFixed: Bool { upper == lower && !extensible }
}

public struct ASN1Range: Sendable, Equatable {
    public var lower: Int?
    public var upper: Int?
    public var extensible: Bool
}

public enum ASN1StringKind: String, Sendable {
    case ia5 = "IA5String", visible = "VisibleString", numeric = "NumericString", printable = "PrintableString", utf8 = "UTF8String"
}

/// What a schema comment says about an integer type's meaning: `-- unit = Feet, Range (-600..70000), resolution = 10`.
public struct ASN1Unit: Sendable, Equatable {
    public var name: String
    /// The value of the constraint's lowest integer, and the step between integers.
    public var low: Double
    public var resolution: Double
    /// Digits after the decimal point that the resolution has.
    public var decimals: Int

    /// The comment's text without its dashes, if it is a unit comment.
    init?(comment: String) {
        guard let match = try? NSRegularExpression(pattern: #"unit\s*=\s*([^,(]+?)[,\s]*\(?Range\s*\(?\s*(-?[0-9.]+)\s*(?:\.\.|to)\s*-?[0-9.]+\s*\)?.*?resolution\s*=\s*([0-9.]+)"#, options: [.caseInsensitive])
                .firstMatch(in: comment, range: NSRange(comment.startIndex..., in: comment)),
              let nameRange = Range(match.range(at: 1), in: comment), let lowRange = Range(match.range(at: 2), in: comment),
              let stepRange = Range(match.range(at: 3), in: comment), let low = Double(comment[lowRange]), let step = Double(comment[stepRange]) else { return nil }
        name = comment[nameRange].trimmingCharacters(in: .whitespaces)
        self.low = low
        resolution = step
        decimals = comment[stepRange].split(separator: ".").dropFirst().first.map(\.count) ?? 0
    }
}

public struct ASN1Tag: Sendable, Equatable {
    /// 0 universal, 1 application, 2 context-specific, 3 private.
    public var tagClass: Int
    public var number: Int
}

public struct ASN1Component: Sendable {
    public var name: String
    public var type: ASN1Type
    public var optional: Bool
    public var hasDefault: Bool
    public var tag: ASN1Tag?
    /// The comment lines just before the component (the CPDLC modules put each message's text there).
    public var comment: [String]
}

public struct ASN1Enumerated: Sendable {
    /// The root items in the order of their numbers, then the items after the extension marker.
    public var root: [(name: String, value: Int)]
    public var additions: [(name: String, value: Int)]
    public var extensible: Bool
}

public indirect enum ASN1Type: Sendable {
    case boolean
    case integer(ASN1Range?, names: [String: Int])
    case enumerated(ASN1Enumerated)
    case bitString(ASN1Size?)
    case octetString(ASN1Size?)
    case string(ASN1StringKind, ASN1Size?)
    case null
    case objectIdentifier
    case relativeOID
    /// An open type (ANY, or ABSTRACT-SYNTAX.&Type): a length and that many octets.
    case any
    /// A type with its own tag, as `AARQ-apdu ::= [APPLICATION 0] IMPLICIT SEQUENCE {…}` has; PER ignores it except to order CHOICEs.
    case tagged(ASN1Tag, ASN1Type)
    case sequence(root: [ASN1Component], additions: [ASN1Component], extensible: Bool)
    case sequenceOf(ASN1Type, ASN1Size?)
    /// `automaticTags`: the module assigned the tags in declaration order; otherwise PER orders the alternatives by tag.
    case choice(root: [ASN1Component], additions: [ASN1Component], extensible: Bool, automaticTags: Bool)
    case reference(String)
}

public enum ASN1Failure: Error, CustomStringConvertible {
    case syntax(String)
    case unknownType(String)
    case truncated
    case constraint(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .syntax(let text): return "ASN.1 syntax: \(text)"
        case .unknownType(let name): return "unknown type \(name)"
        case .truncated: return "the encoding ends too soon"
        case .constraint(let text): return "outside its constraint: \(text)"
        case .unsupported(let text): return "unsupported: \(text)"
        }
    }
}

/// Types by name, from one or more modules.
public struct ASN1Schema: Sendable {
    public private(set) var types: [String: ASN1Type] = [:]
    /// The module that defined the plain name's entry in `types`.
    private var owners: [String: String] = [:]
    /// Units of integer types, from the comments that follow their definitions, by qualified and plain name.
    public private(set) var units: [String: ASN1Unit] = [:]

    public init() {
        types["ObjectDescriptor"] = .string(.utf8, nil)         // a GraphicString: a length and its octets
        types["EXTERNAL"] = .reference("EXTERNALt")           // ACSE's definition of it (X.691 has EXTERNAL's own encoding)
    }

    public init(modules: [String]) throws {
        self.init()
        for text in modules { try add(module: text) }
    }

    /// Adds the definitions of every module in `text`.
    ///
    /// A name defined in a module means that module's definition wherever the module uses it (the CM and CPDLC modules each
    /// have their own `VersionNumber`); a name the module imports is the first definition loaded. Types are also stored as
    /// `Module.Name`; the plain name is the first module's to define it.
    public mutating func add(module text: String) throws {
        var parser = ASN1Parser(text)
        for (module, definitions, moduleUnits) in try parser.parseModules() {
            let own = Set(definitions.map(\.0))
            func scoped(_ type: ASN1Type) -> ASN1Type {
                func component(_ c: ASN1Component) -> ASN1Component { var c = c; c.type = scoped(c.type); return c }
                switch type {
                case .reference(let name): return .reference(own.contains(name) ? "\(module).\(name)" : name)
                case .tagged(let tag, let inner): return .tagged(tag, scoped(inner))
                case .sequenceOf(let element, let size): return .sequenceOf(scoped(element), size)
                case .sequence(let root, let additions, let extensible): return .sequence(root: root.map(component), additions: additions.map(component), extensible: extensible)
                case .choice(let root, let additions, let extensible, let automatic):
                    return .choice(root: root.map(component), additions: additions.map(component), extensible: extensible, automaticTags: automatic)
                default: return type
                }
            }
            for (name, type) in definitions {
                let value = scoped(type)
                types["\(module).\(name)"] = value
                if types[name] == nil { types[name] = value; owners[name] = module }
                if let unit = moduleUnits[name] { units["\(module).\(name)"] = unit; if owners[name] == module { units[name] = unit } }
            }
        }
    }

    /// Replaces a named type (`Module.Name`), and the plain name too when that module is the one it stands for.
    public mutating func replace(type qualified: String, with type: ASN1Type) {
        types[qualified] = type
        if let dot = qualified.firstIndex(of: ".") {
            let module = String(qualified[..<dot]), plain = String(qualified[qualified.index(after: dot)...])
            if owners[plain] == module { types[plain] = type }
        }
    }

    /// Replaces the type of one component of a named SEQUENCE.
    public mutating func replaceComponent(of qualified: String, named component: String, with type: ASN1Type) throws {
        guard case .sequence(var root, let additions, let extensible)? = types[qualified] else { throw ASN1Failure.unknownType(qualified) }
        guard let index = root.firstIndex(where: { $0.name == component }) else { throw ASN1Failure.syntax("\(qualified) has no \(component)") }
        root[index].type = type
        replace(type: qualified, with: .sequence(root: root, additions: additions, extensible: extensible))
    }

    func resolve(_ type: ASN1Type) throws -> ASN1Type {
        var current = type
        var depth = 0
        while true {
            switch current {
            case .reference(let name):
                guard let next = types[name] else { throw ASN1Failure.unknownType(name) }
                current = next
            case .tagged(_, let inner):
                current = inner
            default:
                return current
            }
            depth += 1
            if depth > 64 { throw ASN1Failure.syntax("circular definition") }
        }
    }

    public func type(named name: String) throws -> ASN1Type {
        guard let type = types[name] else { throw ASN1Failure.unknownType(name) }
        return type
    }
}

// MARK: - Parser

private enum Token: Equatable {
    case word(String)           // identifiers and keywords
    case number(Int)
    case symbol(String)         // ::= { } ( ) [ ] , .. ... | ; !
    case comment(String)
}

struct ASN1Parser {
    private var tokens: [Token] = []
    private var position = 0
    private var automaticTags = false

    init(_ text: String) { tokens = Self.tokenize(text) }

    private static func tokenize(_ text: String) -> [Token] {
        var out: [Token] = []
        let chars = Array(text.unicodeScalars)
        var i = 0
        func isWordStart(_ c: Unicode.Scalar) -> Bool { c.properties.isAlphabetic }
        func isWord(_ c: Unicode.Scalar) -> Bool { c.properties.isAlphabetic || (c.value >= 48 && c.value <= 57) || c == "-" || c == "_" }
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1; continue }
            if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                // A comment runs to the end of the line or to the next "--".
                var j = i + 2
                var body = ""
                while j < chars.count, chars[j] != "\n" {
                    if chars[j] == "-", j + 1 < chars.count, chars[j + 1] == "-" { j += 2; break }
                    body.unicodeScalars.append(chars[j]); j += 1
                }
                out.append(.comment(body.trimmingCharacters(in: .whitespaces)))
                i = j
                continue
            }
            if c == ":", i + 2 < chars.count, chars[i + 1] == ":", chars[i + 2] == "=" { out.append(.symbol("::=")); i += 3; continue }
            if c == ".", i + 1 < chars.count, chars[i + 1] == "." {
                if i + 2 < chars.count, chars[i + 2] == "." { out.append(.symbol("...")); i += 3 } else { out.append(.symbol("..")); i += 2 }
                continue
            }
            if "{}()[],|;!<".unicodeScalars.contains(c) { out.append(.symbol(String(c))); i += 1; continue }
            if c.value >= 48 && c.value <= 57 || (c == "-" && i + 1 < chars.count && chars[i + 1].value >= 48 && chars[i + 1].value <= 57) {
                var j = i + 1
                while j < chars.count, chars[j].value >= 48 && chars[j].value <= 57 { j += 1 }
                out.append(.number(Int(String(String.UnicodeScalarView(chars[i..<j])))!))
                i = j
                continue
            }
            if isWordStart(c) {
                var j = i + 1
                while j < chars.count, isWord(chars[j]) {
                    // A trailing hyphen followed by a hyphen starts a comment.
                    if chars[j] == "-", j + 1 < chars.count, chars[j + 1] == "-" { break }
                    j += 1
                }
                out.append(.word(String(String.UnicodeScalarView(chars[i..<j]))))
                i = j
                continue
            }
            i += 1                                   // anything else (quotes, ampersands) is skipped
        }
        return out
    }

    // MARK: Token helpers

    private mutating func skipComments() { while position < tokens.count, case .comment = tokens[position] { position += 1 } }

    private mutating func peek() -> Token? { skipComments(); return position < tokens.count ? tokens[position] : nil }

    private mutating func next() -> Token? { let t = peek(); if t != nil { position += 1 }; return t }

    private mutating func accept(_ symbol: String) -> Bool {
        if case .symbol(let s)? = peek(), s == symbol { position += 1; return true }
        return false
    }

    private mutating func accept(word: String) -> Bool {
        if case .word(let w)? = peek(), w == word { position += 1; return true }
        return false
    }

    private mutating func expect(_ symbol: String) throws {
        guard accept(symbol) else { throw ASN1Failure.syntax("expected \(symbol) near token \(position): \(describe())") }
    }

    private mutating func expectWord() throws -> String {
        guard case .word(let w)? = next() else { throw ASN1Failure.syntax("expected a name near token \(position): \(describe()), after \(context())") }
        return w
    }

    private func context() -> String {
        tokens[max(0, position - 10)..<min(tokens.count, position)].map { t -> String in
            switch t { case .word(let w): return w; case .number(let n): return String(n); case .symbol(let s): return s; case .comment: return "" }
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private mutating func describe() -> String {
        guard let t = peek() else { return "end of text" }
        switch t {
        case .word(let w): return w
        case .number(let n): return String(n)
        case .symbol(let s): return s
        case .comment(let c): return "--" + c
        }
    }

    /// Comment lines between the last comma or brace and the next token (consumed, not skipped past it).
    private mutating func takeComments() -> [String] {
        var lines: [String] = []
        while position < tokens.count, case .comment(let c) = tokens[position] { if !c.isEmpty { lines.append(c) }; position += 1 }
        return lines
    }

    // MARK: Modules

    mutating func parseModules() throws -> [(module: String, types: [(String, ASN1Type)], units: [String: ASN1Unit])] {
        var modules: [(module: String, types: [(String, ASN1Type)], units: [String: ASN1Unit])] = []
        while peek() != nil {
            let moduleName = try expectWord()
            var out: [(String, ASN1Type)] = []
            var units: [String: ASN1Unit] = [:]
            while case .symbol(let s)? = peek(), s == "{" {                // its object identifier
                var depth = 0
                repeat {
                    if accept("{") { depth += 1 } else if accept("}") { depth -= 1 } else { guard next() != nil else { throw ASN1Failure.syntax("module identifier") } }
                } while depth > 0
            }
            guard accept(word: "DEFINITIONS") else { throw ASN1Failure.syntax("expected DEFINITIONS") }
            automaticTags = false
            while !accept("::=") {
                if accept(word: "AUTOMATIC") { automaticTags = true }
                guard next() != nil else { throw ASN1Failure.syntax("module header") }
            }
            guard accept(word: "BEGIN") else { throw ASN1Failure.syntax("expected BEGIN") }
            while accept(word: "IMPORTS") || accept(word: "EXPORTS") {
                while !accept(";") { guard next() != nil else { throw ASN1Failure.syntax("IMPORTS or EXPORTS") } }
            }
            while !accept(word: "END") {
                guard peek() != nil else { throw ASN1Failure.syntax("module not closed") }
                let name = try expectWord()
                let isTypeAssignment: Bool = {
                    guard let first = name.unicodeScalars.first, first.properties.isUppercase else { return false }
                    var k = position
                    while k < tokens.count, case .comment = tokens[k] { k += 1 }
                    if k < tokens.count, case .symbol("::=") = tokens[k] { return true }
                    return false
                }()
                if !isTypeAssignment {
                    // A value assignment, an information object or a class: skip to its `::=` and over what follows.
                    while !accept("::=") { guard next() != nil else { throw ASN1Failure.syntax("assignment of \(name)") } }
                    if accept("{") {
                        var depth = 1
                        while depth > 0 { guard let t = next() else { break }; if t == .symbol("{") { depth += 1 } else if t == .symbol("}") { depth -= 1 } }
                    } else { _ = next() }
                    continue
                }
                try expect("::=")
                out.append((name, try parseType()))
                // The comments right after a definition may say what its integers mean.
                var look = position
                while look < tokens.count, case .comment(let text) = tokens[look] {
                    if let unit = ASN1Unit(comment: text) { units[name] = unit; break }
                    look += 1
                }
            }
            modules.append((moduleName, out, units))
        }
        return modules
    }

    // MARK: Types

    private mutating func parseTag() throws -> ASN1Tag? {
        guard accept("[") else { return nil }
        var tagClass = 2
        if accept(word: "UNIVERSAL") { tagClass = 0 } else if accept(word: "APPLICATION") { tagClass = 1 } else if accept(word: "PRIVATE") { tagClass = 3 }
        guard case .number(let n)? = next() else { throw ASN1Failure.syntax("tag number") }
        try expect("]")
        _ = accept(word: "IMPLICIT") || accept(word: "EXPLICIT")
        return ASN1Tag(tagClass: tagClass, number: n)
    }

    mutating func parseType() throws -> ASN1Type {
        if let tag = try parseTag() { return .tagged(tag, try parseType()) }
        guard case .word(let word)? = next() else { throw ASN1Failure.syntax("a type, near \(describe())") }
        switch word {
        case "BOOLEAN": return .boolean
        case "NULL": return .null
        case "INTEGER":
            var names: [String: Int] = [:]
            if accept("{") {
                while !accept("}") {
                    _ = accept(",")
                    let name = try expectWord()
                    try expect("(")
                    guard case .number(let n)? = next() else { throw ASN1Failure.syntax("named number") }
                    try expect(")")
                    names[name] = n
                }
            }
            return .integer(try parseRangeConstraint(), names: names)
        case "ENUMERATED":
            try expect("{")
            var root: [(String, Int)] = [], additions: [(String, Int)] = []
            var extensible = false, nextValue = 0
            while !accept("}") {
                _ = takeComments()
                if accept(",") { continue }
                if accept("...") { extensible = true; continue }
                let name = try expectWord()
                var value = nextValue
                if accept("(") {
                    guard case .number(let n)? = next() else { throw ASN1Failure.syntax("enumeration value") }
                    value = n
                    try expect(")")
                }
                nextValue = value + 1
                if extensible { additions.append((name, value)) } else { root.append((name, value)) }
            }
            return .enumerated(ASN1Enumerated(root: root.sorted { $0.1 < $1.1 }.map { (name: $0.0, value: $0.1) },
                                              additions: additions.map { (name: $0.0, value: $0.1) }, extensible: extensible))
        case "BIT":
            guard accept(word: "STRING") else { throw ASN1Failure.syntax("BIT STRING") }
            if accept("{") { while !accept("}") { guard next() != nil else { throw ASN1Failure.syntax("named bits") } } }
            return .bitString(try parseSizeConstraint())
        case "OCTET":
            guard accept(word: "STRING") else { throw ASN1Failure.syntax("OCTET STRING") }
            return .octetString(try parseSizeConstraint())
        case "OBJECT":
            guard accept(word: "IDENTIFIER") else { throw ASN1Failure.syntax("OBJECT IDENTIFIER") }
            return .objectIdentifier
        case "RELATIVE-OID": return .relativeOID
        case "IA5String", "VisibleString", "NumericString", "PrintableString", "UTF8String":
            return .string(ASN1StringKind(rawValue: word)!, try parseSizeConstraint())
        case "SEQUENCE", "SET":
            if accept(word: "OF") { return .sequenceOf(try parseType(), nil) }
            if accept("(") {                                              // SEQUENCE (SIZE (…)) OF
                guard accept(word: "SIZE") else { throw ASN1Failure.syntax("SIZE") }
                let size = try parseSizeBody()
                try expect(")")
                guard accept(word: "OF") else { throw ASN1Failure.syntax("OF") }
                return .sequenceOf(try parseElementType(), size)
            }
            if accept(word: "SIZE") {                                     // SEQUENCE SIZE (…) OF
                let size = try parseSizeBody()
                guard accept(word: "OF") else { throw ASN1Failure.syntax("OF") }
                return .sequenceOf(try parseElementType(), size)
            }
            let (root, additions, extensible) = try parseComponents(isChoice: false)
            return .sequence(root: root, additions: additions, extensible: extensible)
        case "CHOICE":
            let (root, additions, extensible) = try parseComponents(isChoice: true)
            return .choice(root: root, additions: additions, extensible: extensible, automaticTags: automaticTags)
        case "ANY":
            return .any
        case "ABSTRACT-SYNTAX":
            _ = accept(word: "Type")                                      // ABSTRACT-SYNTAX.&Type
            if accept("(") { var depth = 1; while depth > 0 { guard let t = next() else { break }; if t == .symbol("(") { depth += 1 } else if t == .symbol(")") { depth -= 1 } } }
            return .any
        default:
            return .reference(word)
        }
    }

    /// The element type of a SEQUENCE OF, which may be an identifier-named one (`element Type`) in some modules.
    private mutating func parseElementType() throws -> ASN1Type { try parseType() }

    private mutating func parseComponents(isChoice: Bool) throws -> ([ASN1Component], [ASN1Component], Bool) {
        try expect("{")
        var root: [ASN1Component] = [], additions: [ASN1Component] = []
        var extensible = false
        var markers = 0                                                  // `...` seen: after the second, components are root again
        var pending: [String] = []
        while true {
            pending += takeComments()
            if accept("}") { break }
            if accept(",") { continue }
            if accept("...") {
                extensible = true
                markers += 1
                if accept("!") { _ = next() }                            // an exception specification
                continue
            }
            if accept(word: "COMPONENTS") { throw ASN1Failure.unsupported("COMPONENTS OF") }
            let name = try expectWord()
            let tag = try parseTag()
            let type = try parseType()
            var optional = false, hasDefault = false
            if accept(word: "OPTIONAL") { optional = true }
            else if accept(word: "DEFAULT") {
                hasDefault = true
                if accept("{") {                                          // the default value: braces, or a word or number
                    var depth = 1
                    while depth > 0 { guard let t = next() else { break }; if t == .symbol("{") { depth += 1 } else if t == .symbol("}") { depth -= 1 } }
                } else { _ = next() }
            }
            let component = ASN1Component(name: name, type: type, optional: optional, hasDefault: hasDefault, tag: tag, comment: pending)
            pending = []
            if extensible && markers == 1 { additions.append(component) } else { root.append(component) }
        }
        // `...` twice (root, additions, root again) is accepted; the trailing root members are folded into the root.
        return (root, additions, extensible)
    }

    // MARK: Constraints

    private mutating func parseSizeConstraint() throws -> ASN1Size? {
        guard accept("(") else { return nil }
        guard accept(word: "SIZE") else {
            // A constraint that is not a size (a permitted alphabet): skip it.
            var depth = 1
            while depth > 0 { guard let t = next() else { break }; if t == .symbol("(") { depth += 1 } else if t == .symbol(")") { depth -= 1 } }
            return nil
        }
        let size = try parseSizeBody()
        try expect(")")
        return size
    }

    private mutating func parseSizeBody() throws -> ASN1Size {
        try expect("(")
        let range = try parseRangeBody()
        try expect(")")
        return ASN1Size(lower: range.lower ?? 0, upper: range.upper, extensible: range.extensible)
    }

    private mutating func parseRangeConstraint() throws -> ASN1Range? {
        guard accept("(") else { return nil }
        let range = try parseRangeBody()
        try expect(")")
        return range
    }

    /// `a..b`, `n`, `MIN..MAX`, unions of those with `|`, and a trailing `, ...` for an extensible constraint (what follows the
    /// marker, the extension's own values, does not concern PER's root).
    private mutating func parseRangeBody() throws -> ASN1Range {
        var lower: Int?, upper: Int?
        var unbounded = (low: false, high: false)
        var first = true
        func value(_ t: Token?) -> Int? { if case .number(let n)? = t { return n }; return nil }
        repeat {
            var a: Int?, b: Int?
            let one = next()
            if case .word(let w)? = one, w == "MIN" { unbounded.low = true } else { a = value(one) }
            if accept("..") {
                let two = next()
                if case .word(let w)? = two, w == "MAX" { unbounded.high = true } else { b = value(two) }
            } else { b = a }
            if first { lower = a; upper = b; first = false } else {
                if let a { lower = lower.map { min($0, a) } ?? a }
                if let b { upper = upper.map { max($0, b) } ?? b }
            }
        } while accept("|")
        if unbounded.low { lower = nil }
        if unbounded.high { upper = nil }
        var extensible = false
        if accept(",") && accept("...") {
            extensible = true
            while accept(",") { _ = next(); if accept("..") { _ = next() }; while accept("|") { _ = next(); if accept("..") { _ = next() } } }
        }
        return ASN1Range(lower: lower, upper: upper, extensible: extensible)
    }
}
