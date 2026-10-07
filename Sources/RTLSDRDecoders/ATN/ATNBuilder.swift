// SPDX-License-Identifier: GPL-2.0-or-later
//
// ATN traffic made from values: the inverse of `ATNDecoder`, for tests and for the tool that makes traffic to compare with
// another decoder. Written for this package.
import Foundation

public enum ATNBuilder {
    /// A CLNP data PDU with a compressed header (Doc 9705 5.7): `type` is its type nibble (1 or 3: segmentation permitted,
    /// 6, 7, 9 or 0xA: a segment, with `offset` and `total`).
    public static func compressedCLNP(type: Int = 0, priority: Int = 0, lifetime: Int = 60, flags: Int = 0, reference: Int = 5, pduID: Int = 0,
                                      offset: Int = 0, total: Int = 0, _ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [UInt8(type << 4 | priority & 0xF), UInt8(lifetime), UInt8(flags)]
        let extended = reference > 0x7F
        out.append(UInt8(extended ? 0x80 | reference >> 8 & 0x7F : reference & 0x7F))
        if extended { out.append(UInt8(reference & 0xFF)) }
        if type == 1 || type == 3 || [6, 7, 9, 0xA].contains(type) { out += [UInt8(pduID >> 8 & 0xFF), UInt8(pduID & 0xFF)] }
        if [6, 7, 9, 0xA].contains(type) { out += [UInt8(offset >> 8 & 0xFF), UInt8(offset & 0xFF), UInt8(total >> 8 & 0xFF), UInt8(total & 0xFF)] }
        return out + payload
    }

    /// A CLNP data PDU with the full header.
    public static func fullCLNP(destination: [UInt8], source: [UInt8], lifetime: Int = 60, segmentation: (id: Int, offset: Int, total: Int, more: Bool)? = nil,
                                _ payload: [UInt8]) -> [UInt8] {
        var header: [UInt8] = [0x81, 0, 1, UInt8(lifetime), 0x1C | (segmentation != nil ? 0x80 : 0) | (segmentation?.more == true ? 0x40 : 0), 0, 0, 0, 0]
        header += [UInt8(destination.count)] + destination + [UInt8(source.count)] + source
        if let s = segmentation { header += [UInt8(s.id >> 8 & 0xFF), UInt8(s.id & 0xFF), UInt8(s.offset >> 8 & 0xFF), UInt8(s.offset & 0xFF), UInt8(s.total >> 8 & 0xFF), UInt8(s.total & 0xFF)] }
        header[1] = UInt8(header.count)
        let total = header.count + payload.count
        header[5] = UInt8(total >> 8 & 0xFF); header[6] = UInt8(total & 0xFF)
        return header + payload
    }

    /// A class 4 data TPDU in the normal format.
    public static func cotpData(destinationReference: Int, sequence: Int, endOfTSDU: Bool = true, _ payload: [UInt8]) -> [UInt8] {
        [4, 0xF0, UInt8(destinationReference >> 8 & 0xFF), UInt8(destinationReference & 0xFF), (endOfTSDU ? 0x80 : 0) | UInt8(sequence & 0x7F)] + payload
    }

    /// A connect request or confirm TPDU (class 4, no options besides `parameters`), with user data.
    public static func cotpConnect(confirm: Bool, destinationReference: Int, sourceReference: Int, parameters: [(UInt8, [UInt8])] = [], _ payload: [UInt8] = []) -> [UInt8] {
        var body: [UInt8] = [confirm ? 0xD0 : 0xE0, UInt8(destinationReference >> 8 & 0xFF), UInt8(destinationReference & 0xFF),
                             UInt8(sourceReference >> 8 & 0xFF), UInt8(sourceReference & 0xFF), 0x40]
        for (code, value) in parameters { body += [code, UInt8(value.count)] + value }
        return [UInt8(body.count)] + body + payload
    }

    /// A disconnect request TPDU with a reason and user data.
    public static func cotpDisconnect(destinationReference: Int, sourceReference: Int, reason: Int, _ payload: [UInt8] = []) -> [UInt8] {
        let body: [UInt8] = [0x80, UInt8(destinationReference >> 8 & 0xFF), UInt8(destinationReference & 0xFF), UInt8(sourceReference >> 8 & 0xFF),
                             UInt8(sourceReference & 0xFF), UInt8(reason)]
        return [UInt8(body.count)] + body + payload
    }

    static func bits(of bytes: [UInt8]) -> [UInt8] { bytes.flatMap { byte in (0..<8).map { UInt8(byte >> UInt8(7 - $0) & 1) } } }

    /// Presentation "fully encoded data" with one PDV list in `context` (1 ACSE, 3 the user ASE).
    public static func fullyEncodedData(schema: ASN1Schema, context: Int, _ payload: [UInt8]) throws -> [UInt8] {
        let list = ASN1Value.list([.sequence([
            ASN1Field(name: "presentation-context-identifier", value: .integer(context)),
            ASN1Field(name: "presentation-data-values", value: .choice(name: "arbitrary", .bitString(bits(of: payload)))),
        ])])
        return try schema.encode("Fully-encoded-data", list)
    }

    /// An ACSE association request (as an aircraft sends it) that carries `userData` and names the application with `qualifier`.
    public static func associationRequest(schema: ASN1Schema, qualifier: Int, userData: [UInt8]) throws -> [UInt8] {
        let external = ASN1Value.sequence([ASN1Field(name: "encoding", value: .choice(name: "arbitrary", .bitString(bits(of: userData))))])
        let apdu = ASN1Value.choice(name: "aarq", .sequence([
            ASN1Field(name: "application-context-name", value: .objectIdentifier([1, 0, 9, 3, 1], relative: false)),
            ASN1Field(name: "calling-AE-qualifier", value: .choice(name: "ae-qualifier-form2", .integer(qualifier))),
            ASN1Field(name: "user-information", value: .list([external])),
        ]))
        return try schema.encode("ACSE-apdu", apdu)
    }

    /// An ACSE abort that carries `userData`.
    public static func abort(schema: ASN1Schema, userData: [UInt8]) throws -> [UInt8] {
        let external = ASN1Value.sequence([ASN1Field(name: "encoding", value: .choice(name: "arbitrary", .bitString(bits(of: userData))))])
        let apdu = ASN1Value.choice(name: "abrt", .sequence([
            ASN1Field(name: "abort-source", value: .integer(0)),
            ASN1Field(name: "user-information", value: .list([external])),
        ]))
        return try schema.encode("ACSE-apdu", apdu)
    }

    /// A protected-mode CPDLC PDU: `send`, with `message` (an ATCUplinkMessage or ATCDownlinkMessage value) PER-encoded inside.
    public static func protectedCPDLC(schema: ASN1Schema, uplink: Bool, message: ASN1Value) throws -> [UInt8] {
        let inner = try schema.encode(uplink ? "ATCUplinkMessage" : "ATCDownlinkMessage", message)
        let wrapper = ASN1Value.sequence([
            ASN1Field(name: "protectedMessage", value: .bitString(bits(of: inner))),
            ASN1Field(name: "integrityCheck", value: .bitString(Array(repeating: 1, count: 32))),
        ])
        return try schema.encode(uplink ? "ProtectedGroundPDUs" : "ProtectedAircraftPDUs", .choice(name: "send", wrapper))
    }

    /// A short-form session PDU, the presentation control octet (PER) and the APDU.
    public static func shortSession(_ identifier: UInt8, _ apdu: [UInt8]) -> [UInt8] { [identifier, 0x02] + apdu }
}
