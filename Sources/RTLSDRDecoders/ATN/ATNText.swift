// SPDX-License-Identifier: GPL-2.0-or-later
//
// CPDLC and context management messages as text: each message element with the wording the standard gives it (the schema's
// comments carry it) and its parameters with their units. Written for this package.
import Foundation

extension ASN1Schema {
    /// The first comment line of the alternative `name` of the choice `choice` (a CPDLC message element's wording, like "AT
    /// [position] REQUEST CLIMB TO [level]"), and the urgency/alert/response line after it.
    public func wording(ofAlternative name: String, in choice: String) -> (text: String, attributes: String)? {
        guard case .choice(let root, let additions, _, _)? = types[choice],
              let alternative = (root + additions).first(where: { $0.name == name }) else { return nil }
        let lines = alternative.comment.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let text = lines.first else { return nil }
        var attributes = lines.dropFirst().first ?? ""
        if !attributes.hasPrefix("Urg") { attributes = "" }
        return (text, attributes)
    }

    /// `value` (of `type`) as a short text: integers with their units where the schema says what they mean, the rest by name.
    public func render(_ type: ASN1Type, _ value: ASN1Value) -> String {
        var unit: ASN1Unit?
        if case .reference(let name) = type { unit = units[name] }
        if case .tagged(_, .reference(let name)) = type { unit = units[name] }
        guard let resolved = try? resolve(type) else { return flat(value) }
        switch (resolved, value) {
        case (.integer(let range, _), .integer(let n)):
            guard let unit else { return String(n) }
            let scaled = unit.low + Double(n - (range?.lower ?? 0)) * unit.resolution
            return String(format: "%.\(unit.decimals)f", scaled) + " " + unit.name
        case (.sequence(let root, let additions, _), .sequence(let fields)):
            let components = root + additions
            let parts = fields.map { field -> String in
                let inner = components.first(where: { $0.name == field.name })?.type
                let text = inner.map { render($0, field.value) } ?? flat(field.value)
                return "\(field.name)=\(text)"
            }
            return "{" + parts.joined(separator: ", ") + "}"
        case (.choice(let root, let additions, _, _), .choice(let name, let inner)):
            let component = (root + additions).first(where: { $0.name == name })
            if case .null = inner { return name }
            let text = component.map { render($0.type, inner) } ?? flat(inner)
            return "\(name): \(text)"
        case (.sequenceOf(let element, _), .list(let items)):
            return "[" + items.map { render(element, $0) }.joined(separator: "; ") + "]"
        default:
            return flat(value)
        }
    }

    private func flat(_ value: ASN1Value) -> String {
        switch value {
        case .boolean(let b): return b ? "true" : "false"
        case .integer(let n): return String(n)
        case .enumerated(let name, _): return name
        case .bitString(let bits): return bits.map(String.init).joined()
        case .octetString(let bytes), .opaque(let bytes): return bytes.map { String(format: "%02x", $0) }.joined()
        case .string(let s): return "\"\(s)\""
        case .null: return "-"
        case .objectIdentifier(let arcs, _): return arcs.map(String.init).joined(separator: ".")
        case .sequence(let fields): return "{" + fields.map { "\($0.name)=\(flat($0.value))" }.joined(separator: ", ") + "}"
        case .choice(let name, let inner): if case .null = inner { return name }; return "\(name): \(flat(inner))"
        case .list(let items): return "[" + items.map(flat).joined(separator: "; ") + "]"
        }
    }
}

extension ATNDecoder {
    /// A CPDLC or context management message as lines of text.
    public func text(of message: ATNMessage) -> [String] {
        guard let value = message.application, let pdu = message.applicationPDU else { return [] }
        switch pdu {
        case "ATCUplinkMessage", "ATCDownlinkMessage":
            return atcMessage(value, uplink: pdu == "ATCUplinkMessage")
        case "CMAircraftMessage", "CMGroundMessage":
            guard case .choice(let name, let inner) = value, let type = try? schema.type(named: "CMMessageSetVersion1." + pdu),
                  case .choice(let root, let additions, _, _) = type, let component = (root + additions).first(where: { $0.name == name }) else { return [] }
            var out = ["\(pdu == "CMAircraftMessage" ? "CM downlink" : "CM uplink"): \(Self.words(name))"]
            if case .null = inner {} else { out.append("  " + schema.render(component.type, inner)) }
            return out
        default:
            // The protected-mode PDUs without a message of their own (aborts) and anything else: the value, by name.
            return [pdu + ": " + schema.render(.reference(pdu), value)]
        }
    }

    /// "cmLogonRequest" as "logon request".
    static func words(_ name: String) -> String {
        var out = ""
        for (index, character) in name.enumerated() {
            if character.isUppercase && index > 0 { out += " " }
            out += character.lowercased()
        }
        return out.hasPrefix("cm ") ? String(out.dropFirst(3)) : out
    }

    private func atcMessage(_ value: ASN1Value, uplink: Bool) -> [String] {
        guard case .sequence(let top) = value, case .sequence(let header)? = top.first(where: { $0.name == "header" })?.value,
              case .sequence(let data)? = top.first(where: { $0.name == "messageData" })?.value else { return [] }
        func integer(_ name: String, in fields: [ASN1Field]) -> Int? { if case .integer(let n)? = fields.first(where: { $0.name == name })?.value { return n }; return nil }
        var line = uplink ? "CPDLC uplink" : "CPDLC downlink"
        if let id = integer("messageIdNumber", in: header) { line += " \(id)" }
        if let reference = integer("messageRefNumber", in: header) { line += " (reply to \(reference))" }
        if case .sequence(let time)? = header.first(where: { $0.name == "dateTime" })?.value,
           case .sequence(let date)? = time.first(where: { $0.name == "date" })?.value,
           case .sequence(let clock)? = time.first(where: { $0.name == "timehhmmss" })?.value,
           case .sequence(let hm)? = clock.first(where: { $0.name == "hoursminutes" })?.value,
           let year = integer("year", in: date), let month = integer("month", in: date), let day = integer("day", in: date),
           let hours = integer("hours", in: hm), let minutes = integer("minutes", in: hm), let seconds = integer("seconds", in: clock) {
            line += String(format: "  %04d-%02d-%02d %02d:%02d:%02dZ", year, month, day, hours, minutes, seconds)
        }
        if case .enumerated("required", _)? = header.first(where: { $0.name == "logicalAck" })?.value { line += "  (acknowledgement required)" }
        var out = [line]
        let choiceType = uplink ? "PMCPDLCMessageSetVersion1.ATCUplinkMsgElementId" : "PMCPDLCMessageSetVersion1.ATCDownlinkMsgElementId"
        if case .list(let elements)? = data.first(where: { $0.name == "elementIds" })?.value,
           let type = try? schema.type(named: choiceType), case .choice(let root, let additions, _, _) = type {
            for element in elements {
                guard case .choice(let name, let inner) = element else { continue }
                let number = name.drop { $0.isLetter }.prefix { $0.isNumber }
                var text = "  \(name.prefix { $0.isLetter })\(number)"
                if let wording = schema.wording(ofAlternative: name, in: choiceType) { text += " " + wording.text }
                if case .null = inner {} else if let component = (root + additions).first(where: { $0.name == name }) {
                    text += ": " + schema.render(component.type, inner)
                }
                out.append(text)
            }
        }
        if case .sequence(let fields)? = data.first(where: { $0.name == "constrainedData" })?.value,
           case .list(let routes)? = fields.first(where: { $0.name == "routeClearanceData" })?.value {
            out.append("  route clearance: " + routes.map { schema.render(.reference("PMCPDLCMessageSetVersion1.RouteClearance"), $0) }.joined(separator: "; "))
        }
        return out
    }
}
