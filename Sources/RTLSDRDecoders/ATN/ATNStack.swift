// SPDX-License-Identifier: GPL-2.0-or-later
//
// The ATN's protocol stack as it runs over VDL Mode 2: X.25 packets in AVLC information frames, ISO 8473 CLNP (with the
// compressed header of ICAO Doc 9705 5.7) and ES-IS, ISO 8073 class 4 transport, the ULCS session and presentation
// short forms, ACSE, and the CPDLC and context management applications in PER. Written for this package from the layers'
// formats as dumpvdl2 by Tomasz Lemiech (GPL-3.0) implements them, read for these facts only; the ASN.1 comes from
// Tools/asn1. See PROVENANCE.md.
import Foundation

// MARK: - Layers' headers

/// An X.25 packet (VDL2 uses modulo 8, GFI 1).
public struct X25Packet: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case callRequest, callAccepted, clearRequest, clearConfirm, resetRequest, resetConfirm, restartRequest, restartConfirm
        case data(sent: Int, received: Int, more: Bool)
        case receiveReady(received: Int), reject(received: Int)
        case diagnostic
    }

    public var kind: Kind
    public var logicalChannelGroup: Int, logicalChannel: Int
    /// The called and calling addresses (decimal or hexadecimal digits, one per nibble) of a call packet.
    public var called: String?, calling: String?
    /// Facility bytes, as sent (length octet excluded).
    public var facilities: [UInt8] = []
    /// The SNDCF compression identifier of a call request (the header compression in use), or the byte in a call accepted.
    public var compression: UInt8?
    /// The cause and diagnostic codes of a clear, reset or restart request, and of a diagnostic packet.
    public var cause: UInt8?, diagnostic: UInt8?
    public var userData: [UInt8] = []

    public var name: String {
        switch kind {
        case .callRequest: return "Call Request"
        case .callAccepted: return "Call Accepted"
        case .clearRequest: return "Clear Request"
        case .clearConfirm: return "Clear Confirm"
        case .resetRequest: return "Reset Request"
        case .resetConfirm: return "Reset Confirm"
        case .restartRequest: return "Restart Request"
        case .restartConfirm: return "Restart Confirm"
        case .data: return "Data"
        case .receiveReady: return "Receive Ready"
        case .reject: return "Reject"
        case .diagnostic: return "Diagnostic"
        }
    }

    /// Parses an AVLC information field; nil if it is not an X.25 packet this decoder knows.
    public init?(_ bytes: [UInt8]) {
        guard bytes.count >= 3, bytes[0] >> 4 == 1 else { return nil }
        logicalChannelGroup = Int(bytes[0] & 0xF)
        logicalChannel = Int(bytes[1])
        let type = bytes[2]
        var offset = 3
        func digits(_ block: ArraySlice<UInt8>, count: Int) -> String {
            var out = ""
            for n in 0..<count {
                let byte = block[block.startIndex + n / 2]
                out += String(format: "%x", n & 1 == 0 ? byte >> 4 : byte & 0xF)
            }
            return out
        }
        if type & 1 == 0 {
            kind = .data(sent: Int(type >> 1 & 7), received: Int(type >> 5), more: type & 0x10 != 0)
            userData = Array(bytes[3...])
            return
        }
        // Restart and diagnostic packets have their own identifiers; the others are told apart by their low five bits (a receive
        // ready or reject packet has its P(R) above them).
        switch type {
        case 0xFB:
            kind = .restartRequest
            guard bytes.count > offset else { return nil }
            cause = bytes[offset]
            if bytes.count > offset + 1 { diagnostic = bytes[offset + 1] }
        case 0xFF: kind = .restartConfirm
        case 0xF1:
            kind = .diagnostic
            guard bytes.count > offset else { return nil }
            diagnostic = bytes[offset]
        default:
            switch type & 0x1F {
            case 0x0B, 0x0F:
                kind = type == 0x0B ? .callRequest : .callAccepted
                guard bytes.count > offset else { return nil }
                let calling = Int(bytes[offset] >> 4), called = Int(bytes[offset] & 0xF)
                let total = (calling + called + 1) / 2
                offset += 1
                guard bytes.count >= offset + total else { return nil }
                // The called address comes first, then the calling one, packed nibble by nibble.
                let nibbles = digits(bytes[offset..<(offset + total)], count: calling + called)
                self.called = String(nibbles.prefix(called))
                self.calling = String(nibbles.dropFirst(called))
                offset += total
                guard bytes.count > offset else { return nil }
                let facilityLength = Int(bytes[offset])
                offset += 1
                guard bytes.count >= offset + facilityLength else { return nil }
                facilities = Array(bytes[offset..<(offset + facilityLength)])
                offset += facilityLength
                if type == 0x0B {
                    // The SNDCF field: 0xC1, a length, the version (1), … and the compression identifier four octets in.
                    guard bytes.count >= offset + 2, bytes[offset] == 0xC1 else { return nil }
                    let length = Int(bytes[offset + 1])
                    guard length >= 4, bytes.count >= offset + 2 + length, bytes[offset + 2] == 1 else { return nil }
                    compression = bytes[offset + 5]
                    offset += 2 + length
                } else {
                    guard bytes.count > offset else { return nil }
                    compression = bytes[offset]
                    offset += 1
                }
                userData = Array(bytes[offset...])
            case 0x13, 0x1B:
                kind = type == 0x13 ? .clearRequest : .resetRequest
                guard bytes.count > offset else { return nil }
                cause = bytes[offset]
                if bytes.count > offset + 1 { diagnostic = bytes[offset + 1] }
            case 0x17: kind = .clearConfirm
            case 0x1F: kind = .resetConfirm
            case 0x01: kind = .receiveReady(received: Int(type >> 5))
            case 0x09: kind = .reject(received: Int(type >> 5))
            default: return nil
            }
        }
    }

    /// An X.25 data packet's octets.
    public static func data(group: Int = 0, channel: Int, sent: Int, received: Int, more: Bool = false, _ userData: [UInt8]) -> [UInt8] {
        [0x10 | UInt8(group & 0xF), UInt8(channel), UInt8(received & 7) << 5 | (more ? 0x10 : 0) | UInt8(sent & 7) << 1] + userData
    }

    /// A call request or call accepted packet's octets (a call request with the SNDCF field for `compression`).
    public static func call(accepted: Bool, group: Int = 0, channel: Int, called: String, calling: String, facilities: [UInt8] = [],
                            compression: UInt8 = 0, _ userData: [UInt8] = []) -> [UInt8] {
        var nibbles = Array(called + calling).map { UInt8(String($0), radix: 16)! }
        if nibbles.count % 2 == 1 { nibbles.append(0) }
        var addresses: [UInt8] = []
        for k in stride(from: 0, to: nibbles.count, by: 2) { addresses.append(nibbles[k] << 4 | nibbles[k + 1]) }
        var out: [UInt8] = [0x10 | UInt8(group & 0xF), UInt8(channel), accepted ? 0x0F : 0x0B,
                            UInt8(calling.count) << 4 | UInt8(called.count)] + addresses + [UInt8(facilities.count)] + facilities
        out += accepted ? [compression] : [0xC1, 4, 1, 0, 0, compression]
        return out + userData
    }
}

/// An X.233 CLNP header, full or compressed.
public struct CLNPHeader: Sendable, Equatable {
    public var compressed: Bool
    public var lifetimeSeconds: Double
    /// Full headers: the NSAP addresses. Compressed ones carry none.
    public var destination: [UInt8] = [], source: [UInt8] = []
    public var segmentationPermitted = false
    public var moreSegments = false
    public var pduID: Int?
    public var offset: Int?, totalLength: Int?
    public var priority: Int?, flags: Int?, localReference: Int?
    public var typeName: String
    public var errorReport = false
}

public struct ESISPDU: Sendable, Equatable {
    public var type: Int
    public var holdTime: Int
    public var name: String { type == 2 ? "ES Hello" : type == 4 ? "IS Hello" : "ES-IS type \(type)" }
}

public struct COTPTPDU: Sendable, Equatable {
    public var code: UInt8
    public var sourceReference: Int?
    public var destinationReference: Int
    public var sequence: Int?
    public var endOfTSDU = false
    public var credit: Int?
    public var classOrReason: Int?
    public var parameters: [(code: UInt8, value: [UInt8])] = []
    public var extended = false

    public init(code: UInt8, destinationReference: Int) { self.code = code; self.destinationReference = destinationReference }

    public static func == (a: COTPTPDU, b: COTPTPDU) -> Bool {
        a.code == b.code && a.sourceReference == b.sourceReference && a.destinationReference == b.destinationReference && a.sequence == b.sequence
            && a.endOfTSDU == b.endOfTSDU && a.credit == b.credit && a.classOrReason == b.classOrReason && a.extended == b.extended
            && a.parameters.elementsEqual(b.parameters, by: { $0.code == $1.code && $0.value == $1.value })
    }

    public var name: String {
        switch code & 0xF0 {
        case 0xE0: return "Connect Request"
        case 0xD0: return "Connect Confirm"
        case 0x80: return "Disconnect Request"
        case 0xC0: return "Disconnect Confirm"
        case 0xF0: return "Data"
        case 0x10: return "Expedited Data"
        case 0x60: return "Data Ack"
        case 0x20: return "Expedited Data Ack"
        case 0x50: return "Reject"
        case 0x70: return "Error"
        default: return String(format: "TPDU 0x%02x", code)
        }
    }
}

// MARK: - Decoded result

public enum ATNApplication: Sendable, Equatable {
    case cpdlc, contextManagement
    public var name: String { self == .cpdlc ? "CPDLC" : "Context Management" }
}

/// What one AVLC information field turned out to be.
public struct ATNMessage: Sendable {
    public var x25: X25Packet?
    public var clnp: CLNPHeader?
    public var esis: ESISPDU?
    public var transport: [COTPTPDU] = []
    /// The X.225 short-form SPDU's name, if there was one.
    public var session: String?
    /// ACSE (ISO 8650) APDU, as decoded.
    public var acse: ASN1Value?
    /// The application's PDU, as decoded, and which one it is; and its name in the schema.
    public var application: ASN1Value?
    public var applicationType: ATNApplication?
    public var applicationPDU: String?
    /// The outermost layer reached when something above could not be read (reassembly pending, an unknown protocol, damage).
    public var note: String?
    /// The data a layer could not read.
    public var undecoded: [UInt8] = []

    /// One line per layer.
    public var lines: [String] {
        var out: [String] = []
        if let x25 {
            var line = "X.25 \(x25.name)"
            switch x25.kind {
            case .data(let s, let r, let more): line += " s\(s) r\(r)" + (more ? " more" : "")
            case .receiveReady(let r), .reject(let r): line += " r\(r)"
            default: break
            }
            if let called = x25.called, let calling = x25.calling { line += "  \(calling) → \(called)" }
            if let cause = x25.cause { line += String(format: "  cause %02x", cause) }
            out.append(line)
        }
        if let clnp {
            var line = clnp.compressed ? "CLNP (compressed) \(clnp.typeName)" : "CLNP \(clnp.typeName)"
            if let reference = clnp.localReference { line += String(format: " lref %04x", reference) }
            if let id = clnp.pduID { line += String(format: " id %04x", id) }
            if let offset = clnp.offset { line += " offset \(offset)" + (clnp.moreSegments ? " more" : "") }
            if !clnp.destination.isEmpty { line += "  \(Self.hex(clnp.source)) → \(Self.hex(clnp.destination))" }
            out.append(line)
        }
        if let esis { out.append("ES-IS \(esis.name), hold time \(esis.holdTime) s") }
        for tpdu in transport {
            var line = "COTP \(tpdu.name)"
            if tpdu.code & 0xF0 == 0xF0 { line += " seq \(tpdu.sequence ?? 0)" + (tpdu.endOfTSDU ? " EOT" : "") }
            line += " dst-ref \(tpdu.destinationReference)"
            if let source = tpdu.sourceReference { line += " src-ref \(source)" }
            out.append(line)
        }
        if let session { out.append("X.225 session: \(session)") }
        if let acse, case .choice(let name, _) = acse { out.append("ACSE \(name.uppercased())") }
        if let application, let applicationType {
            out.append("\(applicationType.name) \(applicationPDU ?? ""):")
            out.append(contentsOf: Self.describe(application, indent: 1))
        }
        if let note { out.append("(\(note))") }
        return out
    }

    /// The message as one JSON object (the layers that were reached).
    public func json(frequencyHz: Double? = nil) -> String {
        func quote(_ s: String) -> String { ASN1Value.string(s).json }
        var parts: [String] = []
        if let x25 {
            var text = "\"x25\": {\"type\": \(quote(x25.name)), \"channel\": \(x25.logicalChannel)"
            if case .data(let s, let r, let more) = x25.kind { text += ", \"sseq\": \(s), \"rseq\": \(r), \"more\": \(more)" }
            if let called = x25.called, let calling = x25.calling { text += ", \"called\": \(quote(called)), \"calling\": \(quote(calling))" }
            if let cause = x25.cause { text += ", \"cause\": \(cause)" }
            parts.append(text + "}")
        }
        if let clnp {
            var text = "\"clnp\": {\"compressed\": \(clnp.compressed), \"type\": \(quote(clnp.typeName))"
            if let reference = clnp.localReference { text += ", \"local_reference\": \(reference)" }
            if let id = clnp.pduID { text += ", \"pdu_id\": \(id)" }
            if let offset = clnp.offset { text += ", \"offset\": \(offset), \"more\": \(clnp.moreSegments)" }
            if !clnp.destination.isEmpty { text += ", \"src\": \(quote(Self.hex(clnp.source))), \"dst\": \(quote(Self.hex(clnp.destination)))" }
            parts.append(text + "}")
        }
        if let esis { parts.append("\"esis\": {\"type\": \(quote(esis.name)), \"hold_time\": \(esis.holdTime)}") }
        if !transport.isEmpty {
            parts.append("\"cotp\": [" + transport.map { t in
                var text = "{\"type\": \(quote(t.name)), \"dst_ref\": \(t.destinationReference)"
                if let source = t.sourceReference { text += ", \"src_ref\": \(source)" }
                if let sequence = t.sequence { text += ", \"seq\": \(sequence), \"eot\": \(t.endOfTSDU)" }
                return text + "}"
            }.joined(separator: ", ") + "]")
        }
        if let session { parts.append("\"x225_spdu\": \(quote(session))") }
        if let acse { parts.append("\"acse\": \(acse.json)") }
        if let application, let applicationType, let applicationPDU {
            parts.append("\"\(applicationType == .cpdlc ? "cpdlc" : "context_mgmt")\": {\"pdu\": \(quote(applicationPDU)), \"message\": \(application.json)}")
        }
        if let note { parts.append("\"note\": \(quote(note))") }
        if let frequencyHz { parts.append("\"freq\": \(frequencyHz / 1e6)") }
        return "{" + parts.joined(separator: ", ") + "}"
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func describe(_ value: ASN1Value, indent: Int) -> [String] {
        value.dump(indent: indent).split(separator: "\n").map(String.init)
    }
}

// MARK: - Decoder

/// Decodes the ATN traffic of VDL2 frames, remembering what reassembly needs between them.
public final class ATNDecoder {
    /// A message's layers as lines, the application's message in words.
    public func lines(for message: ATNMessage) -> [String] {
        var lines = message.lines
        if message.application != nil {
            // The generic dump of the application value is replaced by its text.
            if let start = lines.firstIndex(where: { $0.hasPrefix("CPDLC ") || $0.hasPrefix("Context Management ") }) {
                var end = start + 1
                while end < lines.count, lines[end].hasPrefix(" ") { end += 1 }
                lines.replaceSubrange(start..<end, with: text(of: message))
            }
        }
        return lines
    }

    public let schema: ASN1Schema
    private var x25Fragments: [String: [UInt8]] = [:]
    private var clnpFragments: [String: (total: Int, pieces: [Int: [UInt8]])] = [:]
    private var cotpFragments: [String: [UInt8]] = [:]
    /// The application a transport connection is for (the AE-qualifier of its association request), by the two stations and a
    /// transport reference of either end.
    private var qualifiers: [String: Int] = [:]

    public init(schema: ASN1Schema) { self.schema = schema }

    /// The decoder with the packaged modules.
    public convenience init() throws { self.init(schema: try ATNSchema.make()) }

    private func trim<T>(_ dictionary: inout [String: T]) { if dictionary.count > 64 { dictionary.removeAll() } }

    /// Decodes an information field sent from `source` to `destination` (AVLC addresses), by an aircraft or by the ground.
    /// nil if the field is not X.25 (ACARS and the like are decoded elsewhere).
    public func decode(information: [UInt8], source: UInt32, destination: UInt32, fromAircraft: Bool) -> ATNMessage? {
        guard let packet = X25Packet(information) else { return nil }
        var message = ATNMessage()
        message.x25 = packet
        let pair = "\(source)>\(destination)"
        let stations = "\(min(source, destination))-\(max(source, destination))"
        var payload = packet.userData
        if case .data(_, _, let more) = packet.kind {
            // Packets are joined while the more bit is set, in the order they arrive.
            let key = pair + "/\(packet.logicalChannelGroup).\(packet.logicalChannel)"
            let joined = (x25Fragments[key] ?? []) + payload
            if more {
                x25Fragments[key] = joined
                trim(&x25Fragments)
                message.note = "X.25 packet \(payload.count) bytes, more to come"
                return message
            }
            x25Fragments[key] = nil
            payload = joined
        }
        guard !payload.isEmpty else { return message }
        decodeNetwork(payload, into: &message, pair: pair, stations: stations, fromAircraft: fromAircraft)
        return message
    }

    private func decodeNetwork(_ data: [UInt8], into message: inout ATNMessage, pair: String, stations: String, fromAircraft: Bool) {
        var payload = data
        switch data[0] {
        case 0x81:
            guard let (header, rest) = Self.fullCLNP(data) else { message.undecoded = data; message.note = "an unreadable CLNP header"; return }
            message.clnp = header
            payload = rest
            if header.errorReport { message.note = "CLNP error report"; message.undecoded = rest; return }
        case 0x82:
            guard data.count >= 9, data[2] == 1 else { message.undecoded = data; message.note = "an unreadable ES-IS PDU"; return }
            message.esis = ESISPDU(type: Int(data[4] & 0x1F), holdTime: Int(data[5]) << 8 | Int(data[6]))
            return
        case 0x85:
            message.note = "IDRP, not decoded"
            message.undecoded = data
            return
        default:
            let type = data[0] >> 4
            guard type < 4 || [6, 7, 9, 0xA].contains(type) else {
                message.note = "an unknown protocol (first octet \(String(format: "%02x", data[0])))"
                message.undecoded = data
                return
            }
            guard let (header, rest) = Self.compressedCLNP(data) else { message.undecoded = data; message.note = "an unreadable compressed CLNP header"; return }
            message.clnp = header
            payload = rest
        }
        if let header = message.clnp, header.offset != nil || header.moreSegments {
            // A segment of a longer PDU: collect them by offset.
            let key = pair + "/\(header.pduID ?? 0)"
            var entry = clnpFragments[key] ?? (total: header.totalLength ?? 0, pieces: [:])
            entry.pieces[header.offset ?? 0] = payload
            clnpFragments[key] = entry
            trim(&clnpFragments)
            var joined: [UInt8] = []
            var cursor = 0
            while let piece = entry.pieces[cursor] { joined += piece; cursor += piece.count }
            guard entry.total > 0, joined.count >= entry.total else {
                message.note = "CLNP segment \(payload.count) bytes at offset \(header.offset ?? 0) of \(entry.total)"
                return
            }
            clnpFragments[key] = nil
            payload = Array(joined.prefix(entry.total))
        }
        guard !payload.isEmpty else { return }
        if payload[0] == 0x82 || payload[0] == 0x85 || payload[0] == 0x81 {
            message.note = payload[0] == 0x82 ? "ES-IS in CLNP" : payload[0] == 0x85 ? "IDRP, not decoded" : "CLNP in CLNP"
            message.undecoded = payload
            return
        }
        decodeTransport(payload, into: &message, pair: pair, stations: stations, fromAircraft: fromAircraft)
    }

    // MARK: CLNP headers

    static func fullCLNP(_ b: [UInt8]) -> (CLNPHeader, [UInt8])? {
        guard b.count >= 9, b[0] == 0x81 else { return nil }
        let length = Int(b[1])
        guard length != 255, b.count >= length, b[2] == 1, length >= 9 else { return nil }
        let flags = b[4]
        let type = flags & 0x1F
        var header = CLNPHeader(compressed: false, lifetimeSeconds: Double(b[3]) / 2, typeName: "")
        header.segmentationPermitted = flags & 0x80 != 0
        header.moreSegments = flags & 0x40 != 0
        header.errorReport = type == 0x01
        header.typeName = [0x1C: "Data", 0x1D: "Multicast Data", 0x01: "Error Report", 0x1E: "Echo Request", 0x1F: "Echo Reply"][type] ?? "type \(type)"
        var at = 9
        guard at < length else { return nil }
        let destinationLength = Int(b[at]); at += 1
        guard at + destinationLength < length else { return nil }
        header.destination = Array(b[at..<(at + destinationLength)]); at += destinationLength
        let sourceLength = Int(b[at]); at += 1
        guard at + sourceLength <= length else { return nil }
        header.source = Array(b[at..<(at + sourceLength)]); at += sourceLength
        if header.segmentationPermitted {
            guard at + 6 <= length else { return nil }
            header.pduID = Int(b[at]) << 8 | Int(b[at + 1])
            header.offset = Int(b[at + 2]) << 8 | Int(b[at + 3])
            header.totalLength = Int(b[at + 4]) << 8 | Int(b[at + 5])
            at += 6
        }
        return (header, Array(b[length...]))
    }

    static func compressedCLNP(_ b: [UInt8]) -> (CLNPHeader, [UInt8])? {
        guard b.count >= 4 else { return nil }
        let type = Int(b[0] >> 4)
        let derived = [6, 7, 9, 0xA].contains(type)
        let extended = b[3] & 0x80 != 0
        let permitted = type == 1 || type == 3 || derived
        var length = 4 + (extended ? 1 : 0) + (permitted ? 2 : 0) + (derived ? 4 : 0)
        guard b.count >= length else { return nil }
        var header = CLNPHeader(compressed: true, lifetimeSeconds: Double(b[1]) / 2, typeName: derived ? "Data segment" : "Data")
        header.priority = Int(b[0] & 0xF)
        header.flags = Int(b[2])
        var at = 4
        header.localReference = Int(b[3] & 0x7F)
        if extended { header.localReference = header.localReference! << 8 | Int(b[at]); at += 1 }
        header.segmentationPermitted = permitted
        header.moreSegments = type == 7 || type == 0xA
        if permitted { header.pduID = Int(b[at]) << 8 | Int(b[at + 1]); at += 2 }
        if derived {
            header.offset = Int(b[at]) << 8 | Int(b[at + 1])
            header.totalLength = Int(b[at + 2]) << 8 | Int(b[at + 3])
            at += 4
            let rest = b.count - at
            // A derived PDU that does not fit its own total length is not one (an incompletely reassembled packet can look like it).
            guard header.offset! + rest <= header.totalLength!, rest >= 1 else { return nil }
        }
        length = at
        return (header, Array(b[length...]))
    }

    // MARK: Transport

    private func decodeTransport(_ data: [UInt8], into message: inout ATNMessage, pair: String, stations: String, fromAircraft: Bool) {
        var rest = data[...]
        while !rest.isEmpty {
            guard let (tpdu, consumed, final) = Self.cotp(Array(rest)) else {
                message.note = "an unreadable transport PDU"
                message.undecoded = Array(rest)
                return
            }
            message.transport.append(tpdu)
            if final {
                let user = Array(rest.dropFirst(consumed))
                let known = qualifiers["\(stations)/\(tpdu.destinationReference)"]
                defer {
                    // A connect request names the application; its confirm (from the other end) carries it on to the other reference.
                    if tpdu.code & 0xF0 == 0xE0, let source = tpdu.sourceReference {
                        qualifiers["\(stations)/\(source)"] = Self.qualifier(of: message.acse)       // a new connection: forget the old one
                        trim(&qualifiers)
                    } else if tpdu.code & 0xF0 == 0x80 || tpdu.code & 0xF0 == 0xC0 {
                        qualifiers["\(stations)/\(tpdu.destinationReference)"] = nil
                        if let source = tpdu.sourceReference { qualifiers["\(stations)/\(source)"] = nil }
                    } else if tpdu.code & 0xF0 == 0xD0, let source = tpdu.sourceReference, let known {
                        qualifiers["\(stations)/\(source)"] = known
                    }
                }
                if user.isEmpty { return }
                if tpdu.code & 0xFE == 0xF0 || tpdu.code & 0xF0 == 0x10 {
                    let key = pair + "/\(tpdu.destinationReference)"
                    let joined = (cotpFragments[key] ?? []) + user
                    guard tpdu.endOfTSDU else {
                        cotpFragments[key] = joined
                        trim(&cotpFragments)
                        message.note = "transport data \(user.count) bytes, more to come"
                        return
                    }
                    cotpFragments[key] = nil
                    decodeUpper(joined, into: &message, fromAircraft: fromAircraft, qualifier: known)
                } else if tpdu.code & 0xF0 == 0x80, user.count == 1 {
                    message.note = String(format: "session disconnect reason %d", user[0])
                } else {
                    decodeUpper(user, into: &message, fromAircraft: fromAircraft, qualifier: known)
                }
                return
            }
            rest = rest.dropFirst(consumed)
        }
    }

    /// One TPDU; also how much of the buffer it took and whether it may carry user data.
    static func cotp(_ b: [UInt8]) -> (COTPTPDU, Int, Bool)? {
        guard b.count >= 4 else { return nil }
        let li = Int(b[0])
        guard li != 0, li != 255, b.count >= 1 + li else { return nil }
        let p = Array(b[1...])                                   // p[0] is the TPDU code
        let code = p[0]
        var tpdu = COTPTPDU(code: code, destinationReference: Int(p[1]) << 8 | Int(p[2]))
        var offset = 0
        var final = false
        switch code & 0xF0 {
        case 0xE0, 0xD0, 0x80:
            guard li >= 6 else { return nil }
            tpdu.sourceReference = Int(p[3]) << 8 | Int(p[4])
            if code & 0xF0 == 0x80 { tpdu.classOrReason = Int(p[5]) } else { tpdu.classOrReason = Int(p[5] >> 4) }
            offset = 6
            final = true
            if code & 0xF0 == 0xE0 || code & 0xF0 == 0xD0 { tpdu.credit = Int(code & 0xF) }
        case 0x70:
            guard li >= 4 else { return nil }
            tpdu.classOrReason = Int(p[3])
            offset = 4
        case 0xF0, 0x10:
            tpdu.code = code & 0xFE
            if li & 1 == 1 {
                guard li >= 7 else { return nil }
                tpdu.extended = true
                tpdu.endOfTSDU = p[3] & 0x80 != 0
                tpdu.sequence = (Int(p[3]) << 24 | Int(p[4]) << 16 | Int(p[5]) << 8 | Int(p[6])) & 0x7FFF_FFFF
                offset = 7
            } else {
                guard li >= 4 else { return nil }
                tpdu.endOfTSDU = p[3] & 0x80 != 0
                tpdu.sequence = Int(p[3] & 0x7F)
                offset = 4
            }
            final = true
        case 0xC0:
            guard li >= 5 else { return nil }
            tpdu.sourceReference = Int(p[3]) << 8 | Int(p[4])
            offset = 5
        case 0x60, 0x20, 0x50:
            if code & 0xF0 == 0x60 || code & 0xF0 == 0x50 { tpdu.credit = Int(code & 0xF) }
            if li & 1 == 1 {
                guard li >= (code & 0xF0 == 0x20 ? 7 : 9) else { return nil }
                tpdu.extended = true
                tpdu.sequence = (Int(p[3]) << 24 | Int(p[4]) << 16 | Int(p[5]) << 8 | Int(p[6])) & 0x7FFF_FFFF
                offset = code & 0xF0 == 0x20 ? 7 : 9
            } else {
                guard li >= 4 else { return nil }
                tpdu.sequence = Int(p[3] & 0x7F)
                offset = 4
            }
        default: return nil
        }
        // The variable part: code, length, value.
        var at = offset
        while at + 2 <= li {
            let parameter = p[at], length = Int(p[at + 1])
            guard at + 2 + length <= li else { return nil }
            tpdu.parameters.append((parameter, Array(p[(at + 2)..<(at + 2 + length)])))
            at += 2 + length
        }
        return (tpdu, final ? 1 + li : 1 + li, final)
    }

    // MARK: Session, presentation, ACSE and the applications

    private func decodeUpper(_ data: [UInt8], into message: inout ATNMessage, fromAircraft: Bool, qualifier: Int? = nil) {
        guard !data.isEmpty else { return }
        if data[0] & 0x80 != 0 {
            // A short-form session PDU: the SI octet, the presentation control octet, then the ACSE APDU in PER.
            let id = data[0] & 0xF8
            guard let name = [0xE8: "Short Connect", 0xF0: "Short Accept", 0xD8: "Short Accept Continue", 0xE0: "Short Refuse", 0xA0: "Short Refuse Continue"][Int(id)],
                  data[0] & 4 == 0 else { message.undecoded = data; message.note = "an unknown session PDU"; return }
            message.session = name
            guard data.count >= 2 else { return }
            guard data[1] & 3 == 2 else { message.undecoded = data; message.note = "an unknown presentation encoding"; return }
            let body = Array(data.dropFirst(2))
            if !body.isEmpty { decodeACSE(body, into: &message, fromAircraft: fromAircraft, qualifier: qualifier) }
            return
        }
        // No session or presentation header: the user data alone, as presentation "fully encoded data", or an ACSE APDU.
        if let value = try? schema.decode("Fully-encoded-data", data), case .list(let lists) = value, case .sequence(let fields)? = lists.first {
            let identifier = fields.first { $0.name == "presentation-context-identifier" }
            let values = fields.first { $0.name == "presentation-data-values" }
            if case .choice("arbitrary", .bitString(let bits))? = values?.value, bits.count % 8 == 0 {
                let bytes = Self.bytes(of: bits)
                if case .integer(1)? = identifier?.value { decodeACSE(bytes, into: &message, fromAircraft: fromAircraft, qualifier: qualifier); return }
                if case .integer(3)? = identifier?.value { decodeApplication(bytes, qualifier: qualifier, aborting: false, into: &message, fromAircraft: fromAircraft); return }
            }
        }
        decodeACSE(data, into: &message, fromAircraft: fromAircraft, qualifier: qualifier)
    }

    /// The AE-qualifier an ACSE association request calls itself by.
    static func qualifier(of acse: ASN1Value?) -> Int? {
        guard case .choice("aarq", .sequence(let fields))? = acse, let calling = fields.first(where: { $0.name == "calling-AE-qualifier" }),
              case .choice("ae-qualifier-form2", .integer(let n)) = calling.value else { return nil }
        return n
    }

    static func bytes(of bits: [UInt8]) -> [UInt8] {
        stride(from: 0, to: bits.count, by: 8).map { start in bits[start..<min(bits.count, start + 8)].reduce(0) { $0 << 1 | $1 } }
    }

    private func decodeACSE(_ data: [UInt8], into message: inout ATNMessage, fromAircraft: Bool, qualifier known: Int? = nil) {
        guard let value = try? schema.decode("ACSE-apdu", data), case .choice(let kind, let apdu) = value else {
            message.undecoded = data
            message.note = "not decodable as ACSE or presentation data"
            return
        }
        message.acse = value
        guard case .sequence(let fields) = apdu, let information = fields.first(where: { $0.name == "user-information" }),
              case .list(let externals) = information.value, case .sequence(let external)? = externals.first,
              let encoding = external.first(where: { $0.name == "encoding" }), case .choice("arbitrary", .bitString(let bits)) = encoding.value,
              bits.count % 8 == 0 else { return }
        let qualifier = Self.qualifier(of: value) ?? known
        decodeApplication(Self.bytes(of: bits), qualifier: qualifier, aborting: kind == "abrt", into: &message, fromAircraft: fromAircraft)
    }

    /// The application PDU in `bytes`: CPDLC (the ATN's protected-mode PDUs, whose PER-encoded messages sit in bit strings) or
    /// context management, as the AE-qualifier of the connect request says (22 and 1), or whichever reads when it is not known.
    private func decodeApplication(_ bytes: [UInt8], qualifier: Int?, aborting: Bool, into message: inout ATNMessage, fromAircraft: Bool) {
        // The application the connection is for is tried first; if the bytes do not read as it (a stale or missing record), the
        // other, and for an unknown one CPDLC then context management, as dumpvdl2 does.
        let order: [ATNApplication] = qualifier == 1 ? [.contextManagement, .cpdlc] : [.cpdlc, .contextManagement]
        for application in order {
            switch application {
            case .cpdlc:
                if let (pdu, name) = decodeProtectedCPDLC(bytes, fromAircraft: fromAircraft, aborting: aborting) {
                    message.application = pdu; message.applicationType = .cpdlc; message.applicationPDU = name
                    return
                }
            case .contextManagement:
                let type = fromAircraft ? "CMAircraftMessage" : "CMGroundMessage"
                if let value = try? schema.decode(type, bytes) {
                    message.application = value; message.applicationType = .contextManagement; message.applicationPDU = type
                    return
                }
            }
        }
        message.undecoded = bytes
        message.note = "an application PDU this decoder does not read"
    }

    private func decodeProtectedCPDLC(_ bytes: [UInt8], fromAircraft: Bool, aborting: Bool) -> (ASN1Value, String)? {
        let outer = fromAircraft ? "ProtectedAircraftPDUs" : "ProtectedGroundPDUs"
        let inner = fromAircraft ? "ATCDownlinkMessage" : "ATCUplinkMessage"
        guard let value = try? schema.decode(outer, bytes), case .choice(let kind, let body) = value else { return nil }
        switch kind {
        case "abortUser", "abortProvider":
            return (value, outer)
        case "startdown", "startup", "send":
            // The message is a PER-encoded ATC message inside a bit string; an absent one is a valid empty message.
            var wrapper = body
            if case .sequence(let fields) = body, let start = fields.first(where: { $0.name == "startDownlinkMessage" }) { wrapper = start.value }
            guard case .sequence(let fields) = wrapper else { return nil }
            guard let protected = fields.first(where: { $0.name == "protectedMessage" }) else { return (value, outer) }
            guard case .bitString(let bits) = protected.value, bits.count % 8 == 0,
                  let message = try? schema.decode(inner, Self.bytes(of: bits)) else { return nil }
            return (message, inner)
        default:
            return nil
        }
    }
}
