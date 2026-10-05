// SPDX-License-Identifier: GPL-2.0-or-later
//
// Meshtastic over the air: the modem presets and regional band plans that decide where a mesh transmits, the 16-byte
// packet header, channel keys and their one-byte hash, AES counter-mode decryption, and the protobuf messages of the
// common applications (text, position, node info, telemetry, routing, traceroute, neighbour info).
// Written for this package. The layouts, constants and field numbers are interoperability facts read from the
// Meshtastic firmware and protobuf definitions (GPL-3.0); none of their code is used.
import Foundation

// MARK: Presets and regions

/// A Meshtastic modem preset; the raw value is the name the firmware hashes to pick a frequency slot.
public enum MeshtasticPreset: String, CaseIterable, Sendable {
    case shortTurbo = "ShortTurbo", shortFast = "ShortFast", shortSlow = "ShortSlow"
    case mediumFast = "MediumFast", mediumSlow = "MediumSlow", mediumTurbo = "MediumTurbo"
    case longTurbo = "LongTurbo", longFast = "LongFast", longModerate = "LongMod", longSlow = "LongSlow"
    case liteFast = "LiteFast", liteSlow = "LiteSlow", narrowFast = "NarrowFast", narrowSlow = "NarrowSlow"

    /// Looks a preset up by its name, ignoring case, `_` and `-` ("LONG_FAST", "longfast", "LongModerate").
    public init?(name: String) {
        let key = name.lowercased().filter { $0 != "_" && $0 != "-" }
        guard let preset = Self.allCases.first(where: {
            $0.rawValue.lowercased() == key || ($0 == .longModerate && key == "longmoderate")
        }) else { return nil }
        self = preset
    }

    /// Bandwidth in hertz, spreading factor and coding rate (1-4 for 4/5 … 4/8).
    public var modulation: (bandwidth: Double, spreadingFactor: Int, codingRate: Int) {
        switch self {
        case .shortTurbo: return (500_000, 7, 1)
        case .shortFast: return (250_000, 7, 1)
        case .shortSlow: return (250_000, 8, 1)
        case .mediumFast: return (250_000, 9, 1)
        case .mediumSlow: return (250_000, 10, 1)
        case .mediumTurbo: return (500_000, 9, 1)
        case .longTurbo: return (500_000, 11, 4)
        case .longFast: return (250_000, 11, 1)
        case .longModerate: return (125_000, 11, 4)
        case .longSlow: return (125_000, 12, 4)
        case .liteFast: return (125_000, 9, 1)
        case .liteSlow: return (125_000, 10, 1)
        case .narrowFast: return (62_500, 7, 2)
        case .narrowSlow: return (62_500, 8, 2)
        }
    }

    /// The LoRa settings: sync word 0x2B, a 16-symbol preamble, low data rate optimisation when a symbol lasts 16 ms or
    /// more (as the radios decide it).
    public var parameters: LoRaParameters {
        let m = modulation
        return LoRaParameters(spreadingFactor: m.spreadingFactor, bandwidth: m.bandwidth, codingRate: m.codingRate,
                              syncWord: Meshtastic.syncWord, preambleLength: Meshtastic.preambleLength)
    }
}

/// A regional band plan: the band, and how it is cut into frequency slots one preset's bandwidth wide.
public struct MeshtasticRegion: Sendable {
    public let name: String
    /// Band edges, MHz.
    public let start: Double, end: Double
    /// Gap between slots and padding either side of each, MHz.
    public let spacing: Double, padding: Double
    /// A fixed default slot (1-based), where the region has one instead of the channel-name hash.
    public let fixedSlot: Int?

    init(_ name: String, _ start: Double, _ end: Double, spacing: Double = 0, padding: Double = 0, fixedSlot: Int? = nil) {
        self.name = name; self.start = start; self.end = end; self.spacing = spacing; self.padding = padding
        self.fixedSlot = fixedSlot
    }

    /// The sub-GHz regions (the 2.4 GHz band and the amateur-radio band plans are left out).
    public static let all: [MeshtasticRegion] = [
        .init("US", 902, 928), .init("EU_433", 433, 434), .init("EU_868", 869.4, 869.65),
        .init("EU_866", 865.6, 867.6, spacing: 0.4, padding: 0.0375), .init("EU_N_868", 869.4, 869.65, padding: 0.0104, fixedSlot: 1),
        .init("CN", 470, 510), .init("JP", 920.5, 923.5), .init("ANZ", 915, 928), .init("ANZ_433", 433.05, 434.79),
        .init("RU", 868.7, 869.2), .init("KR", 920, 923), .init("TW", 920, 925), .init("IN", 865, 867),
        .init("NZ_865", 864, 868), .init("TH", 920, 925), .init("UA_433", 433, 434.7), .init("MY_433", 433, 435),
        .init("MY_919", 919, 924), .init("SG_923", 917, 925), .init("PH_433", 433, 434.7), .init("PH_868", 868, 869.4),
        .init("PH_915", 915, 918), .init("KZ_433", 433.075, 434.775), .init("KZ_863", 863, 868), .init("NP_865", 865, 868),
        .init("BR_902", 902, 907.5),
    ]

    public static func named(_ name: String) -> MeshtasticRegion? {
        let key = name.uppercased().replacingOccurrences(of: "-", with: "_")
        return all.first { $0.name == key }
    }

    /// How many slots of `bandwidth` hertz the band holds.
    public func slotCount(bandwidth: Double) -> Int {
        let width = spacing + 2 * padding + bandwidth / 1e6
        return Int(((end - start + spacing) / width).rounded())
    }

    /// The slot (0-based) a channel of this name uses by default: the name's djb2 hash modulo the slot count, unless
    /// the region fixes the slot.
    public func defaultSlot(channelName: String, bandwidth: Double) -> Int {
        if let fixedSlot { return fixedSlot - 1 }
        let count = slotCount(bandwidth: bandwidth)
        return count > 0 ? Int(Meshtastic.djb2(channelName) % UInt32(count)) : 0
    }

    /// The centre frequency of `slot` (0-based), hertz.
    public func frequency(slot: Int, bandwidth: Double) -> Double {
        let width = spacing + 2 * padding + bandwidth / 1e6
        return (start + bandwidth / 2e6 + padding + Double(slot) * width) * 1e6
    }
}

// MARK: Channels

/// A channel: its name (as it is hashed: the preset's name if the channel has none) and its expanded key.
public struct MeshtasticChannel: Sendable {
    public let name: String
    /// Empty (no encryption), 16 bytes (AES-128) or 32 bytes (AES-256).
    public let key: [UInt8]
    /// The byte every packet on the channel carries: the XOR of the name's bytes and the key's.
    public let hash: UInt8

    /// - Parameter psk: the pre-shared key as configured: one byte picks a well-known key (0 none, 1 the default,
    ///   n the default with n − 1 added to its last byte); a shorter key is zero-padded to 16 bytes, one between 16 and
    ///   32 to 32.
    public init(name: String, psk: [UInt8]) {
        var key = psk
        if psk.count == 1 {
            key = psk[0] == 0 ? [] : Meshtastic.defaultKey
            if !key.isEmpty { key[15] &+= psk[0] - 1 }
        } else if !psk.isEmpty && psk.count < 16 {
            key += [UInt8](repeating: 0, count: 16 - psk.count)
        } else if psk.count > 16 && psk.count < 32 {
            key += [UInt8](repeating: 0, count: 32 - psk.count)
        }
        self.name = name
        self.key = Array(key.prefix(32))
        hash = name.utf8.reduce(0, ^) ^ self.key.reduce(0, ^)
    }

    /// A preset's primary channel as a node ships: no name (so the preset's), the default key.
    public static func primary(_ preset: MeshtasticPreset) -> MeshtasticChannel {
        MeshtasticChannel(name: preset.rawValue, psk: [1])
    }
}

public enum Meshtastic {
    public static let syncWord: UInt8 = 0x2b
    public static let preambleLength = 16
    public static let broadcast: UInt32 = 0xffff_ffff
    /// The well-known key a one-byte PSK of 1 stands for (base64 "AQ==" in the apps).
    public static let defaultKey: [UInt8] = [0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59,
                                             0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69, 0x01]

    /// Dan Bernstein's string hash: 5381, then × 33 + each byte.
    public static func djb2(_ text: String) -> UInt32 {
        text.utf8.reduce(UInt32(5381)) { $0 &* 33 &+ UInt32($1) }
    }

    /// Counter-mode encryption and decryption as the firmware does it: the nonce is the packet id (8 bytes, little
    /// endian), the sender (4 bytes, little endian) and four zero bytes that count the blocks (big endian).
    public static func crypt(_ data: [UInt8], key: [UInt8], from: UInt32, packetID: UInt32) -> [UInt8] {
        guard !key.isEmpty, let aes = AES(key: key) else { return data }
        var nonce = [UInt8](repeating: 0, count: 16)
        for k in 0..<4 {
            nonce[k] = UInt8(truncatingIfNeeded: packetID >> (8 * UInt32(k)))
            nonce[8 + k] = UInt8(truncatingIfNeeded: from >> (8 * UInt32(k)))
        }
        return aes.ctr(data, iv: nonce, counterBytes: 4)
    }

    /// "!a1b2c3d4", the way Meshtastic writes node numbers; "^all" for the broadcast address.
    public static func nodeName(_ node: UInt32) -> String {
        node == broadcast ? "^all" : String(format: "!%08x", node)
    }

    static let portNames: [Int: String] = [
        1: "TEXT", 2: "REMOTE_HARDWARE", 3: "POSITION", 4: "NODEINFO", 5: "ROUTING", 6: "ADMIN", 7: "TEXT_COMPRESSED",
        8: "WAYPOINT", 9: "AUDIO", 10: "DETECTION_SENSOR", 11: "ALERT", 12: "KEY_VERIFICATION", 32: "REPLY",
        33: "IP_TUNNEL", 34: "PAXCOUNTER", 64: "SERIAL", 65: "STORE_FORWARD", 66: "RANGE_TEST", 67: "TELEMETRY",
        68: "ZPS", 69: "SIMULATOR", 70: "TRACEROUTE", 71: "NEIGHBORINFO", 72: "ATAK_PLUGIN", 73: "MAP_REPORT",
        74: "POWERSTRESS", 256: "PRIVATE", 257: "ATAK_FORWARDER",
    ]

    static let roleNames = ["CLIENT", "CLIENT_MUTE", "ROUTER", "ROUTER_CLIENT", "REPEATER", "TRACKER", "SENSOR", "TAK",
                            "CLIENT_HIDDEN", "LOST_AND_FOUND", "TAK_TRACKER", "ROUTER_LATE", "CLIENT_BASE"]

    static let routingErrors: [Int: String] = [
        0: "NONE", 1: "NO_ROUTE", 2: "GOT_NAK", 3: "TIMEOUT", 4: "NO_INTERFACE", 5: "MAX_RETRANSMIT", 6: "NO_CHANNEL",
        7: "TOO_LARGE", 8: "NO_RESPONSE", 9: "DUTY_CYCLE_LIMIT", 32: "BAD_REQUEST", 33: "NOT_AUTHORIZED", 34: "PKI_FAILED",
        35: "PKI_UNKNOWN_PUBKEY", 36: "ADMIN_BAD_SESSION_KEY", 37: "ADMIN_PUBLIC_KEY_UNAUTHORIZED", 38: "RATE_LIMIT_EXCEEDED",
    ]

    public static func portName(_ port: Int) -> String { portNames[port] ?? "PORT_\(port)" }
}

// MARK: Packets

/// The unencrypted 16-byte header every Meshtastic packet starts with (little-endian fields).
public struct MeshtasticHeader: Sendable, Equatable {
    public var to: UInt32
    public var from: UInt32
    public var id: UInt32
    public var flags: UInt8
    public var channelHash: UInt8
    /// The last byte of the next hop's node number (0: none chosen), and of the node that relayed this copy.
    public var nextHop: UInt8
    public var relayNode: UInt8

    public init?(_ bytes: [UInt8]) {
        guard bytes.count >= 16 else { return nil }
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) } }
        to = u32(0); from = u32(4); id = u32(8)
        flags = bytes[12]; channelHash = bytes[13]; nextHop = bytes[14]; relayNode = bytes[15]
    }

    public var hopLimit: Int { Int(flags & 0x07) }
    public var hopStart: Int { Int(flags >> 5) }
    public var wantAck: Bool { flags & 0x08 != 0 }
    public var viaMQTT: Bool { flags & 0x10 != 0 }
    public var isBroadcast: Bool { to == Meshtastic.broadcast }
}

public struct MeshtasticPosition: Sendable {
    public var latitude: Double?, longitude: Double?     // degrees
    public var altitude: Int?                            // metres above mean sea level
    public var time: UInt32?                             // Unix seconds
    public var groundSpeed: Int?                         // km/h
    public var groundTrack: UInt32?                      // as sent (the scale is not settled between senders)
    public var satellites: Int?
    public var precisionBits: Int?

    init(_ m: ProtobufMessage) {
        latitude = m.signed(1).map { Double($0) / 1e7 }
        longitude = m.signed(2).map { Double($0) / 1e7 }
        altitude = m.signed(3).map { Int(Int32(truncatingIfNeeded: $0)) }
        time = m.unsigned(4).map { UInt32(truncatingIfNeeded: $0) }
        groundSpeed = m.unsigned(15).map { Int($0) }
        groundTrack = m.unsigned(16).map { UInt32(truncatingIfNeeded: $0) }
        satellites = m.unsigned(19).map { Int($0) }
        precisionBits = m.unsigned(23).map { Int($0) }
    }
}

public struct MeshtasticUser: Sendable {
    public var id: String?, longName: String?, shortName: String?
    public var hardwareModel: Int?, role: Int?
    public var publicKey: [UInt8]?

    init(_ m: ProtobufMessage) {
        id = m.string(1); longName = m.string(2); shortName = m.string(3)
        hardwareModel = m.unsigned(5).map { Int($0) }
        role = m.unsigned(7).map { Int($0) }
        publicKey = m.bytes(8)
    }
}

/// Device and environment telemetry (other kinds are reported by name only).
public struct MeshtasticTelemetry: Sendable {
    public var time: UInt32?
    public var batteryLevel: Int?, voltage: Float?, channelUtilization: Float?, airUtilTx: Float?, uptime: Int?
    public var temperature: Float?, relativeHumidity: Float?, barometricPressure: Float?
    /// Which kind it is: device, environment, air quality, power, local stats, health, host.
    public var kind: String

    init(_ m: ProtobufMessage) {
        time = m.unsigned(1).map { UInt32(truncatingIfNeeded: $0) }
        let kinds = [2: "device", 3: "environment", 4: "air_quality", 5: "power", 6: "local_stats", 7: "health", 8: "host",
                     9: "traffic", 11: "soil_water"]
        kind = m.fields.lazy.compactMap { kinds[$0.number] }.first ?? "unknown"
        if let d = m.message(2) {
            batteryLevel = d.unsigned(1).map { Int($0) }
            voltage = d.float(2); channelUtilization = d.float(3); airUtilTx = d.float(4)
            uptime = d.unsigned(5).map { Int($0) }
        }
        if let e = m.message(3) {
            temperature = e.float(1); relativeHumidity = e.float(2); barometricPressure = e.float(3)
        }
        if let s = m.message(6) {                         // local stats: uptime and air time too
            uptime = s.unsigned(1).map { Int($0) }
            channelUtilization = s.float(2); airUtilTx = s.float(3)
        }
    }
}

/// What a decrypted packet carries, by application.
public enum MeshtasticContent: Sendable {
    case text(String)
    case position(MeshtasticPosition)
    case nodeInfo(MeshtasticUser)
    case telemetry(MeshtasticTelemetry)
    /// An acknowledgement (error NONE) or failure report, or a route request/reply.
    case routing(error: Int?)
    case traceroute(route: [UInt32], routeBack: [UInt32])
    case neighborInfo(node: UInt32?, neighbors: [(node: UInt32, snr: Float?)])
    case waypoint(name: String?, latitude: Double?, longitude: Double?)
    /// A payload this decoder does not interpret (or could not parse).
    case payload([UInt8])
}

/// The `Data` message inside a decrypted packet.
public struct MeshtasticData: Sendable {
    public var port: Int
    public var payload: [UInt8]
    public var wantResponse: Bool
    public var requestID: UInt32?, replyID: UInt32?
    public var emoji: Bool
    public var content: MeshtasticContent

    /// nil unless `bytes` parse as a Data message with a port: what the firmware takes as proof of the right key.
    init?(_ bytes: [UInt8]) {
        guard let m = ProtobufMessage(bytes), case .varint(let port)? = m.value(1), (1...511).contains(port),
              m.fields.allSatisfy({ (1...15).contains($0.number) }) else { return nil }
        if m.has(2) { guard m.bytes(2) != nil else { return nil } }
        self.port = Int(port)
        payload = m.bytes(2) ?? []
        wantResponse = m.unsigned(3).map { $0 != 0 } ?? false
        requestID = m.unsigned(6).map { UInt32(truncatingIfNeeded: $0) }
        replyID = m.unsigned(7).map { UInt32(truncatingIfNeeded: $0) }
        emoji = m.unsigned(8).map { $0 != 0 } ?? false
        content = MeshtasticData.interpret(Int(port), payload)
    }

    static func interpret(_ port: Int, _ payload: [UInt8]) -> MeshtasticContent {
        if port == 1 || port == 66, let text = String(bytes: payload, encoding: .utf8) { return .text(text) }
        guard let m = ProtobufMessage(payload) else { return .payload(payload) }
        switch port {
        case 3: return .position(MeshtasticPosition(m))
        case 4: return .nodeInfo(MeshtasticUser(m))
        case 5: return .routing(error: m.unsigned(3).map { Int($0) })
        case 8:
            return .waypoint(name: m.string(6), latitude: m.signed(2).map { Double($0) / 1e7 },
                             longitude: m.signed(3).map { Double($0) / 1e7 })
        case 67: return .telemetry(MeshtasticTelemetry(m))
        case 70:
            func nodes(_ number: Int) -> [UInt32] {
                m.values(number).flatMap { value -> [UInt32] in
                    switch value {
                    case .fixed32(let v): return [v]
                    case .bytes(let packed):                // packed repeated fixed32
                        return stride(from: 0, to: packed.count - 3, by: 4).map { at in
                            (0..<4).reduce(UInt32(0)) { $0 | UInt32(packed[at + $1]) << (8 * UInt32($1)) }
                        }
                    default: return []
                    }
                }
            }
            return .traceroute(route: nodes(1), routeBack: nodes(3))
        case 71:
            let neighbors = m.values(4).compactMap { value -> (node: UInt32, snr: Float?)? in
                guard case .bytes(let b) = value, let n = ProtobufMessage(b), let node = n.unsigned(1) else { return nil }
                return (UInt32(truncatingIfNeeded: node), n.float(2))
            }
            return .neighborInfo(node: m.unsigned(1).map { UInt32(truncatingIfNeeded: $0) }, neighbors: neighbors)
        default: return .payload(payload)
        }
    }
}

/// A Meshtastic packet from one LoRa frame.
public struct MeshtasticPacket: Sendable {
    public enum Status: Sendable, Equatable {
        /// Decrypted with a channel's key (or sent in the clear on a channel without one).
        case decoded
        /// No configured channel has the packet's hash, or none of their keys gives a valid message.
        case unknownChannel
        /// A direct message encrypted to the recipient's public key: no listener can read it.
        case publicKey
    }

    public var header: MeshtasticHeader
    public var status: Status
    public var channel: String?
    public var data: MeshtasticData?
    /// The encrypted part, as received.
    public var encrypted: [UInt8]
}

/// Decrypts and decodes Meshtastic packets with the channels it knows.
public struct MeshtasticDecoder: Sendable {
    public var channels: [MeshtasticChannel]

    public init(channels: [MeshtasticChannel]) { self.channels = channels }

    /// nil if the frame is too short to be a Meshtastic packet.
    public func decode(_ frame: [UInt8]) -> MeshtasticPacket? {
        guard let header = MeshtasticHeader(frame) else { return nil }
        let body = Array(frame.dropFirst(16))
        for channel in channels where channel.hash == header.channelHash {
            let plain = Meshtastic.crypt(body, key: channel.key, from: header.from, packetID: header.id)
            if let data = MeshtasticData(plain) {
                return MeshtasticPacket(header: header, status: .decoded, channel: channel.name, data: data, encrypted: body)
            }
        }
        let direct = header.channelHash == 0 && !header.isBroadcast
        return MeshtasticPacket(header: header, status: direct ? .publicKey : .unknownChannel, channel: nil, data: nil, encrypted: body)
    }
}

// MARK: Output

extension MeshtasticPacket {
    /// One line: sender, recipient, id, hops, channel, then what the packet says.
    public var line: String {
        let h = header
        var text = "\(Meshtastic.nodeName(h.from)) → \(Meshtastic.nodeName(h.to))  id \(String(format: "%08x", h.id))"
        text += "  hops \(h.hopLimit)/\(h.hopStart)"
        if h.wantAck { text += " ack" }
        if h.viaMQTT { text += " mqtt" }
        switch status {
        case .publicKey: return text + "  encrypted direct message (public key), \(encrypted.count) bytes"
        case .unknownChannel: return text + String(format: "  unknown channel 0x%02x, \(encrypted.count) bytes encrypted", h.channelHash)
        case .decoded: break
        }
        guard let data else { return text }
        text += "  [\(channel ?? "")]  \(Meshtastic.portName(data.port))"
        if let reply = data.replyID { text += String(format: " (reply to %08x)", reply) }
        if let request = data.requestID { text += String(format: " (request %08x)", request) }
        return text + "  " + data.content.summary
    }

    /// A JSON object with the header fields and the decoded content.
    public func json(extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = extra
        object["from"] = Meshtastic.nodeName(header.from)
        object["to"] = Meshtastic.nodeName(header.to)
        object["id"] = header.id
        object["hop_limit"] = header.hopLimit
        object["hop_start"] = header.hopStart
        object["want_ack"] = header.wantAck
        object["via_mqtt"] = header.viaMQTT
        object["channel_hash"] = Int(header.channelHash)
        object["next_hop"] = Int(header.nextHop)
        object["relay_node"] = Int(header.relayNode)
        switch status {
        case .decoded: object["status"] = "decoded"
        case .unknownChannel: object["status"] = "unknown_channel"
        case .publicKey: object["status"] = "public_key"
        }
        if status != .decoded { object["encrypted"] = encrypted.map { String(format: "%02x", $0) }.joined() }
        if let channel { object["channel"] = channel }
        if let data {
            object["port"] = Meshtastic.portName(data.port)
            object["portnum"] = data.port
            if data.wantResponse { object["want_response"] = true }
            if let request = data.requestID { object["request_id"] = request }
            if let reply = data.replyID { object["reply_id"] = reply }
            for (key, value) in data.content.fields { object[key] = value }
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: bytes, encoding: .utf8) else { return "{}" }
        return text
    }
}

extension MeshtasticContent {
    public var summary: String {
        switch self {
        case .text(let text): return "\"\(text)\""
        case .position(let p):
            var parts: [String] = []
            if let lat = p.latitude, let lon = p.longitude { parts.append(String(format: "%.5f, %.5f", lat, lon)) }
            if let alt = p.altitude { parts.append("\(alt) m") }
            if let sats = p.satellites { parts.append("\(sats) sats") }
            if let speed = p.groundSpeed { parts.append("\(speed) km/h") }
            if let time = p.time, time > 0 { parts.append(Self.utc(time)) }
            return parts.isEmpty ? "(no fix)" : parts.joined(separator: "  ")
        case .nodeInfo(let u):
            var text = "\"\(u.longName ?? "")\" (\(u.shortName ?? ""))"
            if let id = u.id { text += " \(id)" }
            if let hw = u.hardwareModel { text += "  hw \(hw)" }
            if let role = u.role { text += "  " + (role < Meshtastic.roleNames.count ? Meshtastic.roleNames[role] : "role \(role)") }
            if let key = u.publicKey, !key.isEmpty { text += "  public key" }
            return text
        case .telemetry(let t):
            var parts = [t.kind]
            if let b = t.batteryLevel { parts.append(b > 100 ? "powered" : "battery \(b) %") }
            if let v = t.voltage { parts.append(String(format: "%.2f V", v)) }
            if let c = t.channelUtilization { parts.append(String(format: "channel %.1f %%", c)) }
            if let a = t.airUtilTx { parts.append(String(format: "air tx %.1f %%", a)) }
            if let u = t.uptime { parts.append("up \(u / 3600) h \(u / 60 % 60) min") }
            if let temperature = t.temperature { parts.append(String(format: "%.1f °C", temperature)) }
            if let humidity = t.relativeHumidity { parts.append(String(format: "%.0f %%RH", humidity)) }
            if let pressure = t.barometricPressure { parts.append(String(format: "%.1f hPa", pressure)) }
            return parts.joined(separator: "  ")
        case .routing(let error):
            guard let error, error != 0 else { return "ack" }
            return "error " + (Meshtastic.routingErrors[error] ?? "\(error)")
        case .traceroute(let route, let back):
            var text = "route " + (route.isEmpty ? "(direct)" : route.map(Meshtastic.nodeName).joined(separator: " → "))
            if !back.isEmpty { text += "  back " + back.map(Meshtastic.nodeName).joined(separator: " → ") }
            return text
        case .neighborInfo(let node, let neighbors):
            let list = neighbors.map { n in Meshtastic.nodeName(n.node) + (n.snr.map { String(format: " %.1f dB", $0) } ?? "") }
            return (node.map(Meshtastic.nodeName).map { "\($0): " } ?? "") + (list.isEmpty ? "no neighbours" : list.joined(separator: ", "))
        case .waypoint(let name, let lat, let lon):
            var text = "\"\(name ?? "")\""
            if let lat, let lon { text += String(format: " %.5f, %.5f", lat, lon) }
            return text
        case .payload(let bytes): return "\(bytes.count) bytes " + bytes.prefix(32).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Fields for the JSON line.
    var fields: [String: Any] {
        var f: [String: Any] = [:]
        switch self {
        case .text(let text): f["text"] = text
        case .position(let p):
            if let v = p.latitude { f["latitude"] = v }
            if let v = p.longitude { f["longitude"] = v }
            if let v = p.altitude { f["altitude"] = v }
            if let v = p.time { f["time"] = v }
            if let v = p.satellites { f["sats_in_view"] = v }
            if let v = p.groundSpeed { f["ground_speed"] = v }
            if let v = p.groundTrack { f["ground_track"] = v }
            if let v = p.precisionBits { f["precision_bits"] = v }
        case .nodeInfo(let u):
            if let v = u.id { f["user_id"] = v }
            if let v = u.longName { f["long_name"] = v }
            if let v = u.shortName { f["short_name"] = v }
            if let v = u.hardwareModel { f["hw_model"] = v }
            if let v = u.role { f["role"] = v < Meshtastic.roleNames.count ? Meshtastic.roleNames[v] : "\(v)" }
            if let v = u.publicKey, !v.isEmpty { f["public_key"] = Data(v).base64EncodedString() }
        case .telemetry(let t):
            f["telemetry"] = t.kind
            if let v = t.time { f["time"] = v }
            if let v = t.batteryLevel { f["battery_level"] = v }
            if let v = t.voltage { f["voltage"] = Double(v) }
            if let v = t.channelUtilization { f["channel_utilization"] = Double(v) }
            if let v = t.airUtilTx { f["air_util_tx"] = Double(v) }
            if let v = t.uptime { f["uptime_seconds"] = v }
            if let v = t.temperature { f["temperature"] = Double(v) }
            if let v = t.relativeHumidity { f["relative_humidity"] = Double(v) }
            if let v = t.barometricPressure { f["barometric_pressure"] = Double(v) }
        case .routing(let error): f["routing_error"] = Meshtastic.routingErrors[error ?? 0] ?? "\(error ?? 0)"
        case .traceroute(let route, let back):
            f["route"] = route.map(Meshtastic.nodeName)
            f["route_back"] = back.map(Meshtastic.nodeName)
        case .neighborInfo(let node, let neighbors):
            if let node { f["node"] = Meshtastic.nodeName(node) }
            f["neighbors"] = neighbors.map { n -> [String: Any] in
                var entry: [String: Any] = ["node": Meshtastic.nodeName(n.node)]
                if let snr = n.snr { entry["snr"] = Double(snr) }
                return entry
            }
        case .waypoint(let name, let lat, let lon):
            if let name { f["name"] = name }
            if let lat { f["latitude"] = lat }
            if let lon { f["longitude"] = lon }
        case .payload(let bytes): f["payload"] = bytes.map { String(format: "%02x", $0) }.joined()
        }
        return f
    }

    static func utc(_ seconds: UInt32) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss'Z'"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}
