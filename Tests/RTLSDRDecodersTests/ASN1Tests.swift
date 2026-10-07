// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

struct ASN1PERTests {
    private func schema(_ text: String) throws -> ASN1Schema { try ASN1Schema(modules: [text]) }

    /// Hand-worked encodings (X.691 clauses 10 to 20).
    @Test func smallTypesEncodeAsTheStandardHasThem() throws {
        let s = try schema("""
        M DEFINITIONS ::= BEGIN
        Int7 ::= INTEGER (0..7)
        Fixed ::= INTEGER (5..5)
        Neg ::= INTEGER (-3..3)
        Flag ::= BOOLEAN
        Seq ::= SEQUENCE { a INTEGER (0..7), b BOOLEAN OPTIONAL, c INTEGER (0..255) }
        Pick ::= CHOICE { x NULL, y INTEGER (0..15), z BOOLEAN }
        Color ::= ENUMERATED { red(0), green(1), blue(2) }
        Open ::= INTEGER
        Low ::= INTEGER (10..MAX)
        Name ::= IA5String (SIZE (2..4))
        Digits ::= NumericString (SIZE (3))
        Bits ::= BIT STRING (SIZE (5))
        Blob ::= OCTET STRING (SIZE (1..3))
        List ::= SEQUENCE SIZE (1..3) OF INTEGER (0..3)
        END
        """)
        func bits(_ bytes: [UInt8]) -> String { bytes.map { String($0, radix: 2).leftPad(8) }.joined() }
        // INTEGER (0..7) = 5: three bits 101, padded.
        #expect(bits(try s.encode("Int7", .integer(5))) == "10100000")
        #expect(try s.decode("Int7", [0b10100000]) == .integer(5))
        // A range of one takes no bits; the empty encoding is one zero octet.
        #expect(try s.encode("Fixed", .integer(5)) == [0])
        #expect(bits(try s.encode("Neg", .integer(-3))) == "00000000")
        #expect(bits(try s.encode("Neg", .integer(3))) == "11000000")
        #expect(try s.encode("Flag", .boolean(true)) == [0x80])
        // SEQUENCE { a 3, b absent, c 0xA5 }: preamble 0 (b absent), a = 011, c = 10100101.
        #expect(bits(try s.encode("Seq", .sequence([ASN1Field(name: "a", value: .integer(3)), ASN1Field(name: "c", value: .integer(0xA5))]))) == "00111010" + "01010000")
        // Without tags PER indexes the alternatives by their types' universal tags: BOOLEAN (1), INTEGER (2), NULL (5). z is
        // index 0 (two bits 00) and then the BOOLEAN 1; y is index 1 (01) and then 1001.
        #expect(bits(try s.encode("Pick", .choice(name: "z", .boolean(true)))) == "00100000")
        #expect(bits(try s.encode("Pick", .choice(name: "y", .integer(9)))) == "01100100")
        #expect(bits(try s.encode("Pick", .choice(name: "x", .null))) == "10000000")
        #expect(bits(try s.encode("Color", .enumerated(name: "blue", value: 2))) == "10000000")
        // Unconstrained INTEGER: length 1 then the octet; 128 needs two octets; -1 is 0xFF.
        #expect(try s.encode("Open", .integer(5)) == [0x01, 0x05])
        #expect(try s.encode("Open", .integer(128)) == [0x02, 0x00, 0x80])
        #expect(try s.encode("Open", .integer(-1)) == [0x01, 0xFF])
        #expect(try s.decode("Open", [0x02, 0xFF, 0x7F]) == .integer(-129))
        // Semi-constrained (10..MAX): 10 is length 1 and octet 0.
        #expect(try s.encode("Low", .integer(10)) == [0x01, 0x00])
        // IA5String (SIZE 2..4): length in two bits (n-2), characters in seven bits each.
        #expect(bits(try s.encode("Name", .string("AB"))) == "00" + "1000001" + "1000010")
        // NumericString (SIZE 3): no length, four bits each as the index in " 0123456789": "1 2" is 0010 0000 0011? ('1'=2, ' '=0, '2'=3).
        #expect(bits(try s.encode("Digits", .string("1 2"))) == "0010" + "0000" + "0011" + "0000")
        #expect(bits(try s.encode("Bits", .bitString([1, 0, 1, 1, 0]))) == "10110000")
        #expect(bits(try s.encode("Blob", .octetString([0xAA, 0xBB]))) == "01" + "10101010" + "10111011" + "000000")
        #expect(bits(try s.encode("List", .list([.integer(1), .integer(2)]))) == "01" + "01" + "10" + "00")
    }

    @Test func extensionsAreEncodedAndSkipped() throws {
        let s = try schema("""
        M DEFINITIONS ::= BEGIN
        Old ::= SEQUENCE { a INTEGER (0..3), ... }
        New ::= SEQUENCE { a INTEGER (0..3), ..., b INTEGER (0..255) OPTIONAL, c BOOLEAN OPTIONAL }
        Kind ::= CHOICE { one NULL, two NULL, ..., three INTEGER (0..7) }
        Old2 ::= CHOICE { one NULL, two NULL, ... }
        Colour ::= ENUMERATED { red, green, ..., blue }
        END
        """)
        // A sender that knows b and c; a receiver that knows neither keeps them as opaque extensions.
        let sent = try s.encode("New", .sequence([ASN1Field(name: "a", value: .integer(2)), ASN1Field(name: "b", value: .integer(200)), ASN1Field(name: "c", value: .boolean(true))]))
        let old = try s.decode("Old", sent)
        guard case .sequence(let fields) = old else { Issue.record("not a sequence"); return }
        #expect(fields.first == ASN1Field(name: "a", value: .integer(2)) && fields.count == 3)
        if case .opaque(let bytes) = fields[1].value { #expect(bytes == [200]) } else { Issue.record("b should be opaque: \(fields[1])") }
        #expect(try s.decode("New", sent) == .sequence([ASN1Field(name: "a", value: .integer(2)), ASN1Field(name: "b", value: .integer(200)), ASN1Field(name: "c", value: .boolean(true))]))
        // A root alternative has the extension bit 0; an extension alternative is an open type.
        let three = try s.encode("Kind", .choice(name: "three", .integer(5)))
        #expect(try s.decode("Kind", three) == .choice(name: "three", .integer(5)))
        guard case .choice(let name, _) = try s.decode("Old2", three) else { Issue.record("not a choice"); return }
        #expect(name == "extension#0")
        #expect(try s.decode("Colour", s.encode("Colour", .enumerated(name: "blue", value: 2))) == .enumerated(name: "blue", value: 2))
    }

    @Test func choiceAlternativesAreIndexedByTagUnlessTheyAreAutomatic() throws {
        let explicit = try schema("""
        M DEFINITIONS ::= BEGIN
        C ::= CHOICE { late [5] NULL, early [1] NULL }
        END
        """)
        let automatic = try schema("""
        M DEFINITIONS AUTOMATIC TAGS ::= BEGIN
        C ::= CHOICE { late NULL, early NULL }
        END
        """)
        // With explicit tags the alternative with the lower tag is index 0; with automatic tags, the first declared is.
        #expect(try explicit.encode("C", .choice(name: "early", .null)) == [0x00])
        #expect(try explicit.encode("C", .choice(name: "late", .null)) == [0x80])
        #expect(try automatic.encode("C", .choice(name: "late", .null)) == [0x00])
    }

    @Test func truncatedInputIsRefusedNotTrapped() throws {
        let s = try schema("""
        M DEFINITIONS ::= BEGIN
        S ::= SEQUENCE { a IA5String (SIZE (1..20)), b INTEGER (0..1000) }
        END
        """)
        let good = try s.encode("S", .sequence([ASN1Field(name: "a", value: .string("HELLO WORLD")), ASN1Field(name: "b", value: .integer(777))]))
        for cut in 0..<good.count { #expect(throws: ASN1Failure.self) { try s.decode("S", Array(good.prefix(cut))) } }
        var generator = Seeded(state: 5)
        for _ in 0..<500 {
            let junk = (0..<Int.random(in: 0...12, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = try? s.decode("S", junk)
        }
    }

    @Test func objectIdentifiersRoundTrip() throws {
        let s = try schema("""
        M DEFINITIONS ::= BEGIN
        Id ::= OBJECT IDENTIFIER
        Rel ::= RELATIVE-OID
        END
        """)
        let id = ASN1Value.objectIdentifier([1, 3, 27, 1, 128, 16_384], relative: false)
        #expect(try s.decode("Id", s.encode("Id", id)) == id)
        // 2.100.3 is 0x81 0x34 0x03 (the first two arcs make 180 = 0x81 0x34).
        #expect(try s.encode("Id", .objectIdentifier([2, 100, 3], relative: false)) == [0x03, 0x81, 0x34, 0x03])
        let rel = ASN1Value.objectIdentifier([9, 300], relative: true)
        #expect(try s.decode("Rel", s.encode("Rel", rel)) == rel)
    }
}

extension String {
    func leftPad(_ width: Int) -> String { String(repeating: "0", count: max(0, width - count)) + self }
}

struct ATNSchemaTests {
    static let schema = try! ASN1Schema(modules: ATNModules.all)

    @Test func theModulesParseAndHaveTheirMessageSets() throws {
        let s = Self.schema
        for name in ["ATCUplinkMessage", "ATCDownlinkMessage", "GroundPDUs", "AircraftPDUs", "CMAircraftMessage", "CMGroundMessage",
                     "ATCUplinkMsgElementId", "ATCDownlinkMsgElementId", "ProtectedGroundPDUs", "ACSE-apdu", "Fully-encoded-data"] {
            _ = try s.type(named: name)
        }
        guard case .choice(let up, let upAdded, _, _) = try s.type(named: "ATCUplinkMsgElementId"),
              case .choice(let down, let downAdded, _, _) = try s.type(named: "ATCDownlinkMsgElementId") else {
            Issue.record("element ids are choices"); return
        }
        // uM0 ... uM236 are in the root and uM237 follows the extension marker; dM0 ... dM113.
        #expect(up.count == 237 && upAdded.count == 1 && down.count == 114 && downAdded.isEmpty)
        #expect(up[0].comment.contains { $0.contains("UNABLE") })
    }

    @Test func randomMessagesRoundTripThroughTheirEncoding() throws {
        let s = Self.schema
        var values = ASN1RandomValues(schema: s, seed: 17)
        for name in ["ATCUplinkMessage", "ATCDownlinkMessage", "GroundPDUs", "AircraftPDUs", "CMAircraftMessage", "CMGroundMessage", "ProtectedGroundPDUs",
                     "ProtectedAircraftPDUs", "ACSE-apdu", "Fully-encoded-data"] {
            for round in 0..<150 {
                let value = try values.value(try s.type(named: name))
                let bytes = try s.encode(name, value)
                let back = try s.decode(name, bytes)
                #expect(back == value, "\(name) round \(round): \(value.dump())\nbecame\n\(back.dump())")
                if back != value { return }
            }
        }
    }
}
