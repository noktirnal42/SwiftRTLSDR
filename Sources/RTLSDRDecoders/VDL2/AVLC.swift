// SPDX-License-Identifier: GPL-2.0-or-later
//
// AVLC, VDL Mode 2's link layer (HDLC with 4-octet addresses), and what it most often carries: ACARS and XID frames.
// Written for this package from the format as dumpvdl2 by Tomasz Lemiech (GPL-3.0) implements it, read for these facts
// only; see PROVENANCE.md.
import Foundation

/// An AVLC address: a 24-bit address (an aircraft's ICAO address, or a ground station's), its type and a status bit.
public struct AVLCAddress: Sendable, Equatable {
    public var address: UInt32
    /// 1 aircraft, 4 and 5 ground station, 7 all stations.
    public var type: Int
    /// In a destination: the aircraft is on the ground. In a source: the frame is a response (not a command).
    public var status: Bool

    public init(address: UInt32, type: Int, status: Bool = false) {
        self.address = address
        self.type = type
        self.status = status
    }

    /// Seven bits an octet (the lowest is the extension bit), the status bit first, then the type, then the address.
    init(octets o: ArraySlice<UInt8>) {
        let b = Array(o)
        let raw = UInt32(b[0] >> 1) | UInt32(b[1] >> 1) << 7 | UInt32(b[2] >> 1) << 14 | UInt32(b[3] >> 1) << 21
        var value: UInt32 = 0
        for i in 0..<28 where raw >> UInt32(i) & 1 == 1 { value |= 1 << UInt32(27 - i) }
        address = value & 0xFF_FFFF
        type = Int(value >> 24 & 7)
        status = value >> 27 & 1 == 1
    }

    func octets(last: Bool = false) -> [UInt8] {
        let value = (status ? 1 << 27 : 0) | UInt32(type & 7) << 24 | address & 0xFF_FFFF
        var raw: UInt32 = 0
        for i in 0..<28 where value >> UInt32(i) & 1 == 1 { raw |= 1 << UInt32(27 - i) }
        var out = (0..<4).map { UInt8(raw >> UInt32(7 * $0) & 0x7F) << 1 }
        if last { out[3] |= 1 }
        return out
    }

    public var hex: String { String(format: "%06X", address) }

    public var typeName: String {
        switch type {
        case 1: return "Aircraft"
        case 4, 5: return "Ground station"
        case 7: return "All stations"
        default: return "reserved"
        }
    }
}

/// An XID frame's parameters (link management): the ones worth showing are decoded, the rest kept as bytes.
public struct VDL2XID: Sendable {
    public struct Frequency: Sendable, Equatable {
        public var megahertz: Double
        public var groundStation: AVLCAddress?
    }

    /// GSIF (a ground station's information frame), XID_CMD_LE (link establishment), XID_CMD_HO (handoff), … .
    public var name: String
    public var description: String
    /// The aircraft's position as it reports it (0.1° steps) and altitude (thousands of feet).
    public var latitude: Double?, longitude: Double?, altitudeFeet: Int?
    public var destinationAirport: String?
    public var airportCoverage: String?
    public var nearestAirport: String?
    public var frequencies: [Frequency] = []
    public var autotuneMegahertz: Double?
    public var alternateGroundStations: [AVLCAddress] = []
    /// Every VDL parameter (group 0xF0) as received: type and value.
    public var parameters: [(type: UInt8, value: [UInt8])] = []

    /// Names by (C/R, P/F, the connection management parameter's h and r bits), as ICAO 9776 tabulates them.
    private static let names: [Int: (String, String)] = [
        1: ("XID_CMD_LCR", "Link Connection Refused"), 2: ("XID_CMD_HO", "Handoff Request / Broadcast Handoff"),
        3: ("GSIF", "Ground Station Information Frame"), 4: ("XID_CMD_LE", "Link Establishment"),
        6: ("XID_CMD_HO", "Handoff Initiation"), 7: ("XID_CMD_LPM", "Link Parameter Modification"),
        12: ("XID_RSP_LE", "Link Establishment Response"), 13: ("XID_RSP_LCR", "Link Connection Refused Response"),
        14: ("XID_RSP_HO", "Handoff Response"), 15: ("XID_RSP_LPM", "Link Parameter Modification Response"),
    ]

    init?(_ b: [UInt8], response: Bool, pollFinal: Bool) {
        guard b.count >= 7, b[0] == 0x82 else { return nil }
        var index = 1
        var found = false
        while index + 3 <= b.count {
            let group = b[index], length = Int(b[index + 1]) << 8 | Int(b[index + 2])
            index += 3
            guard index + length <= b.count else { return nil }
            if group == 0xF0 {
                found = true
                var p = index
                while p + 2 <= index + length {
                    let type = b[p], size = Int(b[p + 1])
                    guard size > 0, p + 2 + size <= index + length else { return nil }
                    parameters.append((type, Array(b[(p + 2)..<(p + 2 + size)])))
                    p += 2 + size
                }
            }
            index += length
        }
        guard found else { return nil }
        var h = 1, r = 1
        if let management = parameters.first(where: { $0.type == 0x01 })?.value.first {
            h = Int(management & 1)
            r = Int(management >> 1 & 1)
        }
        let key = (response ? 8 : 0) | (pollFinal ? 4 : 0) | h << 1 | r
        (name, description) = Self.names[key] ?? ("XID", "Unknown XID type")
        for (type, value) in parameters {
            let text = String(decoding: value, as: UTF8.self)
            switch type {
            case 0x83: destinationAirport = text
            case 0xC1: airportCoverage = text
            case 0xC3: nearestAirport = text
            case 0x84 where value.count >= 4:
                (latitude, longitude) = Self.location(value)
                altitudeFeet = Int(value[3]) * 1000
            case 0x40 where value.count >= 2: autotuneMegahertz = Self.frequency(value)
            case 0xC0 where value.count % 6 == 0:
                frequencies = stride(from: 0, to: value.count, by: 6).map {
                    Frequency(megahertz: Self.frequency(Array(value[$0..<($0 + 2)])),
                              groundStation: AVLCAddress(octets: value[($0 + 2)..<($0 + 6)]))
                }
            case 0x82 where value.count % 4 == 0:
                alternateGroundStations = stride(from: 0, to: value.count, by: 4).map { AVLCAddress(octets: value[$0..<($0 + 4)]) }
            default: break
            }
        }
    }

    /// Latitude and longitude, 12-bit two's complement each in tenths of a degree, packed into three octets.
    static func location(_ v: [UInt8]) -> (Double, Double) {
        func signed(_ x: Int) -> Int { x >= 0x800 ? x - 0x1000 : x }
        let lat = signed((Int(v[0]) << 8 | Int(v[1])) >> 4)
        let lon = signed((Int(v[1]) << 8 | Int(v[2])) & 0xFFF)
        return (Double(lat) / 10, Double(lon) / 10)
    }

    /// A VHF channel: 12 bits of (kHz / 10 − 10000), rounded up to the 25 kHz raster; the top four bits name modulations.
    static func frequency(_ v: [UInt8]) -> Double {
        var khz = ((Int(v[0]) << 8 | Int(v[1])) & 0xFFF + 10_000) * 10
        if khz % 25 != 0 { khz += 25 - khz % 25 }
        return Double(khz) / 1000
    }
}

/// One AVLC frame.
public struct AVLCFrame: Sendable {
    public enum Kind: Sendable, Equatable {
        /// Numbered information: the send and receive sequence numbers and the poll bit.
        case information(send: Int, receive: Int, poll: Bool)
        /// Receive Ready, Receive not Ready, Reject, Selective Reject.
        case supervisory(function: Int, receive: Int, pollFinal: Bool)
        /// UI, DM, DISC, UA, FRMR, XID, TEST (the modifier bits, the P/F bit taken out).
        case unnumbered(function: Int, pollFinal: Bool)
    }

    /// The frame as received, FCS included.
    public var bytes: [UInt8]
    public var destination: AVLCAddress
    public var source: AVLCAddress
    public var kind: Kind
    /// The information field.
    public var info: [UInt8]
    /// ACARS carried in an information frame (FF FF 01 first), nil otherwise.
    public var acars: ACARSMessage?
    /// The ACARS block's own CRC held (the frame's FCS already did).
    public var acarsCRCValid = true
    public var xid: VDL2XID?

    public var isResponse: Bool { source.status }
    /// The A/G bit (carried in the destination address): the sending station is on the ground.
    public var onGround: Bool { destination.status }

    /// Parses `bytes` (the frame between flags, FCS included); nil if it is too short or the FCS fails.
    public init?(bytes: [UInt8]) {
        guard bytes.count >= 11, Self.fcsResidue(bytes) == 0xF0B8 else { return nil }
        self.bytes = bytes
        destination = AVLCAddress(octets: bytes[0..<4])
        source = AVLCAddress(octets: bytes[4..<8])
        let control = bytes[8]
        info = Array(bytes[9..<(bytes.count - 2)])
        if control & 1 == 0 {
            kind = .information(send: Int(control >> 1 & 7), receive: Int(control >> 5), poll: control & 0x10 != 0)
            if info.count > 3, info[0] == 0xFF, info[1] == 0xFF, info[2] == 0x01 {
                let block = Array(info[3...])
                if block.count >= 16, block.last == 0x7F {
                    let characters = block.dropLast(3)
                    acarsCRCValid = ACARSFrameDecoder.crc(block.dropLast()) == 0
                    let parity = characters.filter { $0.nonzeroBitCount % 2 == 0 }.count
                    acars = ACARSMessage(characters: characters.map { $0 & 0x7F }, correctedBits: 0, parityErrors: parity)
                }
            }
        } else if control & 3 == 1 {
            kind = .supervisory(function: Int(control >> 2 & 3), receive: Int(control >> 5), pollFinal: control & 0x10 != 0)
        } else {
            let function = Int(control >> 2) & 0x3B
            kind = .unnumbered(function: function, pollFinal: control & 0x10 != 0)
            if function == 0x2B { xid = VDL2XID(info, response: source.status, pollFinal: control & 0x10 != 0) }
        }
    }

    /// The X.25 FCS run over a frame and its FCS leaves 0xF0B8.
    static func fcsResidue(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? crc >> 1 ^ 0x8408 : crc >> 1 }
        }
        return crc
    }

    /// The frame's octets with its FCS (for tests and the oracle).
    public static func build(destination: AVLCAddress, source: AVLCAddress, control: UInt8, info: [UInt8] = []) -> [UInt8] {
        var bytes = destination.octets() + source.octets(last: true) + [control] + info
        let crc = fcsResidue(bytes) ^ 0xFFFF
        bytes += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        return bytes
    }

    public var typeName: String {
        switch kind {
        case .information: return "I"
        case .supervisory(let function, _, _): return ["RR", "RNR", "REJ", "SREJ"][function]
        case .unnumbered(let function, _):
            return [0x00: "UI", 0x03: "DM", 0x10: "DISC", 0x18: "UA", 0x21: "FRMR", 0x2B: "XID", 0x38: "TEST"][function]
                ?? String(format: "U(0x%02x)", function)
        }
    }

    /// One line: source → destination, the frame type, and what it carries.
    public var line: String {
        var line = "\(source.hex) \(source.typeName)" + (onGround ? " (on ground)" : "")
        line += " → \(destination.hex) \(destination.typeName)" + (isResponse ? "  response" : "")
        switch kind {
        case .information(let send, let receive, let poll): line += "  I s\(send) r\(receive)\(poll ? " P" : "")"
        case .supervisory(_, let receive, let pf): line += "  \(typeName) r\(receive)\(pf ? " P/F" : "")"
        case .unnumbered(_, let pf): line += "  \(typeName)\(pf ? " P/F" : "")"
        }
        if let acars {
            line += "  ACARS " + acars.line + (acarsCRCValid ? "" : "  (ACARS CRC bad)")
        } else if let xid {
            line += "  \(xid.name)"
            if let latitude = xid.latitude, let longitude = xid.longitude {
                line += String(format: "  %.1f %.1f", latitude, longitude) + (xid.altitudeFeet.map { " \($0) ft" } ?? "")
            }
            if let airport = xid.destinationAirport { line += "  to \(airport)" }
            if let coverage = xid.airportCoverage { line += "  covers \(coverage)" }
            if !xid.frequencies.isEmpty { line += "  " + xid.frequencies.map { String(format: "%.3f MHz", $0.megahertz) }.joined(separator: ", ") }
        } else if !info.isEmpty {
            line += "  \(info.count) bytes"
        }
        return line
    }

    /// The frame as dumpvdl2's JSON has it under "avlc" (the fields this decoder knows).
    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "src": ["addr": source.hex, "type": source.typeName, "status": onGround ? "On ground" : "Airborne"],
            "dst": ["addr": destination.hex, "type": destination.typeName],
            "cr": isResponse ? "Response" : "Command",
            "frame_type": { switch kind { case .information: "I"; case .supervisory: "S"; case .unnumbered: "U" } }(),
        ]
        switch kind {
        case .information(let send, let receive, let poll):
            object["sseq"] = send
            object["rseq"] = receive
            object["poll"] = poll
        case .supervisory(let function, let receive, let pf):
            object["cmd"] = ["Receive Ready", "Receive not Ready", "Reject", "Selective Reject"][function]
            object["rseq"] = receive
            object["pf"] = pf
        case .unnumbered(_, let pf):
            object["cmd"] = typeName
            object["pf"] = pf
        }
        if let acars {
            var a: [String: Any] = ["err": false, "crc_ok": acarsCRCValid, "more": acars.moreBlocks, "reg": acars.registration,
                                    "mode": String(acars.mode), "label": acars.label, "blk_id": String(acars.blockID),
                                    "ack": acars.acknowledgement.map(String.init) ?? "!", "msg_text": acars.text]
            if let flight = acars.flightID { a["flight"] = flight }
            if let number = acars.messageNumber { a["msg_num"] = number }
            object["acars"] = a
        } else if let xid {
            var x: [String: Any] = ["type": xid.name, "type_descr": xid.description]
            if let lat = xid.latitude, let lon = xid.longitude {
                x["ac_location"] = ["loc": ["lat": lat, "lon": lon], "alt": xid.altitudeFeet ?? 0]
            }
            if let v = xid.destinationAirport { x["dst_airport"] = v }
            if let v = xid.airportCoverage { x["airport_coverage"] = v }
            if let v = xid.nearestAirport { x["nearest_airport_id"] = v }
            if let v = xid.autotuneMegahertz { x["autotune_freq"] = v }
            if !xid.frequencies.isEmpty {
                x["freq_support_list"] = xid.frequencies.map { ["freq": $0.megahertz, "gs_addr": $0.groundStation?.hex ?? ""] }
            }
            object["xid"] = x
        } else if !info.isEmpty {
            object["data"] = info.map { String(format: "%02x", $0) }.joined()
        }
        return object
    }
}
