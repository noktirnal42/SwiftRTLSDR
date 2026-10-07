// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRDecoders

private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

private func strings(in value: ASN1Value) -> [String] {
    switch value {
    case .string(let s): return [s]
    case .sequence(let fields): return fields.flatMap { strings(in: $0.value) }
    case .choice(_, let inner): return strings(in: inner)
    case .list(let items): return items.flatMap { strings(in: $0) }
    default: return []
    }
}

private func elementIDs(in value: ASN1Value) -> [String] {
    guard case .sequence(let top) = value, let data = top.first(where: { $0.name == "messageData" }), case .sequence(let fields) = data.value,
          let ids = fields.first(where: { $0.name == "elementIds" }), case .list(let list) = ids.value else { return [] }
    return list.compactMap { if case .choice(let name, _) = $0 { return name }; return nil }
}

/// `atn-sample` (for development): random ATN traffic as AVLC frames, to compare with another decoder (Tools/atn-oracle-compare.py).
/// One JSON object a line: the frame in hexadecimal with its FCS, who sent it, and what is in it.
func atnSample(_ arguments: Arguments) {
    let count = arguments.int("count", default: 40)
    var rng = SplitMix64(state: UInt64(arguments.int("seed", default: 1)))
    let extensions = arguments.flag("extensions")
    let schema: ASN1Schema
    do { schema = try ATNSchema.make() } catch { fail("\(error)") }
    var values = ASN1RandomValues(schema: schema, seed: UInt64(arguments.int("seed", default: 1)) &+ 1000)
    values.useExtensions = extensions
    let aircraft = AVLCAddress(address: 0x4B1A2C, type: 1, status: false), ground = AVLCAddress(address: 0x1A0000 + UInt32(arguments.int("ground", default: 0x2A1)), type: 4)

    func pick(_ n: Int) -> Int { Int.random(in: 0..<n, using: &rng) }
    let kinds = (arguments.option("kinds") ?? "0,1,2,3,4,5").split(separator: ",").compactMap { Int($0) }
    let split = !arguments.flag("no-split")
    for index in 0..<count {
        do {
            let kind = kinds[pick(kinds.count)]
            let fromAircraft = kind == 0 || kind == 2 || kind == 4 || kind == 5
            var transport: [UInt8]
            var prelude: [(fromAircraft: Bool, transport: [UInt8])] = []
            var description: [String: Any] = [:]
            let reference = 100 + index                                     // a connection's own, as live ones have
            switch kind {
            case 0, 1:
                let uplink = kind == 1
                let message = try values.value(try schema.type(named: uplink ? "ATCUplinkMessage" : "ATCDownlinkMessage"))
                let pdu = try ATNBuilder.protectedCPDLC(schema: schema, uplink: uplink, message: message)
                let user = try ATNBuilder.fullyEncodedData(schema: schema, context: 3, pdu)
                transport = ATNBuilder.cotpData(destinationReference: reference, sequence: index & 0x7F, user)
                description = ["app": "cpdlc", "pdu": uplink ? "ATCUplinkMessage" : "ATCDownlinkMessage", "strings": strings(in: message)]
                if case .sequence(let top) = message, case .sequence(let header)? = top.first(where: { $0.name == "header" })?.value {
                    description["header"] = header.compactMap { f -> [String: Any]? in if case .integer(let n) = f.value { return ["name": f.name, "value": n] }; return nil }
                }
                description["elements"] = elementIDs(in: message)
            case 2, 3:
                let aircraftSide = kind == 2
                let message = try values.value(try schema.type(named: aircraftSide ? "CMAircraftMessage" : "CMGroundMessage"))
                let pdu = try schema.encode(aircraftSide ? "CMAircraftMessage" : "CMGroundMessage", message)
                description = ["app": "cm", "pdu": aircraftSide ? "CMAircraftMessage" : "CMGroundMessage", "strings": strings(in: message)]
                if aircraftSide {
                    let apdu = try ATNBuilder.associationRequest(schema: schema, qualifier: 1, userData: pdu)
                    transport = ATNBuilder.cotpConnect(confirm: false, destinationReference: 0, sourceReference: reference, ATNBuilder.shortSession(0xE8, apdu))
                } else {
                    // A ground message in plain data is only known as context management from the connection's request and
                    // confirm: they come first (an aircraft's request for CM, and the ground's confirm).
                    let request = try ATNBuilder.associationRequest(schema: schema, qualifier: 1,
                        userData: try schema.encode("CMAircraftMessage", .choice(name: "cmAbortReason", .enumerated(name: "undefined", value: 0))))
                    prelude = [(true, ATNBuilder.cotpConnect(confirm: false, destinationReference: 0, sourceReference: reference, ATNBuilder.shortSession(0xE8, request))),
                               (false, ATNBuilder.cotpConnect(confirm: true, destinationReference: reference, sourceReference: reference + 5_000))]
                    let user = try ATNBuilder.fullyEncodedData(schema: schema, context: 3, pdu)
                    transport = ATNBuilder.cotpData(destinationReference: reference, sequence: index & 0x7F, user)
                }
            case 4:
                var chosen = try values.value(try schema.type(named: "ProtectedAircraftPDUs"))
                while true {
                    if case .choice(let name, _) = chosen, name == "abortUser" || name == "abortProvider" { break }
                    chosen = try values.value(try schema.type(named: "ProtectedAircraftPDUs"))
                }
                let pdu = try schema.encode("ProtectedAircraftPDUs", chosen)
                let apdu = try ATNBuilder.abort(schema: schema, userData: pdu)
                transport = ATNBuilder.cotpDisconnect(destinationReference: reference, sourceReference: 7, reason: 0, apdu)
                description = ["app": "cpdlc", "pdu": "ProtectedAircraftPDUs", "strings": [String]()]
            default:
                let message = try values.value(try schema.type(named: "ATCDownlinkMessage"))
                let pdu = try ATNBuilder.protectedCPDLC(schema: schema, uplink: false, message: message)
                let apdu = try ATNBuilder.associationRequest(schema: schema, qualifier: 22, userData: pdu)
                transport = ATNBuilder.cotpConnect(confirm: false, destinationReference: 0, sourceReference: reference, ATNBuilder.shortSession(0xE8, apdu))
                description = ["app": "cpdlc", "pdu": "ATCDownlinkMessage", "strings": strings(in: message)]
            }
            func emit(_ packet: [UInt8], fromAircraft: Bool, number: Int = 0, complete: Bool, extra: [String: Any]) throws {
                let source = fromAircraft ? aircraft : ground, destination = fromAircraft ? ground : aircraft
                let frame = AVLCFrame.build(destination: AVLCAddress(address: destination.address, type: destination.type, status: !fromAircraft),
                                            source: AVLCAddress(address: source.address, type: source.type, status: false), control: UInt8(number << 1), info: packet)
                var object = extra
                object["frame"] = hex(frame)
                object["from_aircraft"] = fromAircraft
                object["complete"] = complete
                object["index"] = index
                print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
            }
            for item in prelude {
                let network = ATNBuilder.compressedCLNP(type: 0, priority: 0, reference: reference, item.transport)
                try emit(X25Packet.data(channel: 1, sent: 0, received: 0, network), fromAircraft: item.fromAircraft, complete: false, extra: ["app": "setup", "pdu": "connection"])
            }
            let network: [UInt8]
            if pick(3) == 0 {
                network = ATNBuilder.fullCLNP(destination: [0x47, 0x00, 0x27, 0x81, 0x01, 0x02], source: [0x47, 0x00, 0x27, 0x81, 0x03, 0x04], transport)
            } else {
                network = ATNBuilder.compressedCLNP(type: pick(2) == 0 ? 0 : 1, priority: pick(8), reference: reference, pduID: index, transport)
            }
            let source = fromAircraft ? aircraft : ground, destination = fromAircraft ? ground : aircraft
            var packets: [[UInt8]]
            if split, network.count > 8, pick(3) == 0 {
                let cut = 1 + pick(network.count - 1)
                packets = [X25Packet.data(channel: 1, sent: 0, received: 0, more: true, Array(network[..<cut])),
                           X25Packet.data(channel: 1, sent: 1, received: 0, more: false, Array(network[cut...]))]
            } else {
                packets = [X25Packet.data(channel: 1, sent: 0, received: 0, network)]
            }
            for (number, packet) in packets.enumerated() {
                let control = UInt8(number << 1)                                  // an I frame: send sequence, no poll
                let frame = AVLCFrame.build(destination: AVLCAddress(address: destination.address, type: destination.type, status: !fromAircraft),
                                            source: AVLCAddress(address: source.address, type: source.type, status: false), control: control, info: packet)
                var object = description
                object["frame"] = hex(frame)
                object["from_aircraft"] = fromAircraft
                object["complete"] = number == packets.count - 1
                object["index"] = index
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            }
        } catch { fail("sample \(index): \(error)") }
    }
}
