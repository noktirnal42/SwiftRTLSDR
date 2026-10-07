// SPDX-License-Identifier: GPL-2.0-or-later
//
// AIS, the ships' Automatic Identification System of ITU-R Recommendation M.1371: the bits of a message, the six-bit
// armour and NMEA sentences that carry them, and what the common messages say. Written for this package from the
// recommendation's message tables as gpsd's AIVDM documentation (Eric S. Raymond) lays them out; pyais (MIT) is the oracle.
// See PROVENANCE.md.
import Foundation

public enum AIS {
    /// The two channels: 161.975 MHz (A, "87B") and 162.025 MHz (B, "88B").
    public static let channelA = 161_975_000.0, channelB = 162_025_000.0
    public static let baud = 9600.0
}

/// A message's bits, in the order they were sent (the first bit of the first field first; fields are read most significant
/// bit first).
public struct AISBits: Sendable, Equatable {
    public var bits: [UInt8]

    public init(bits: [UInt8]) { self.bits = bits }

    public var count: Int { bits.count }

    /// The unsigned value of `count` bits from `start` (zeros where the message ends: messages are allowed to be short).
    public func unsigned(_ start: Int, _ count: Int) -> Int {
        var value = 0
        for k in 0..<count { value = value << 1 | (start + k < bits.count ? Int(bits[start + k]) : 0) }
        return value
    }

    public func signed(_ start: Int, _ count: Int) -> Int {
        let value = unsigned(start, count)
        return value >= 1 << (count - 1) ? value - 1 << count : value
    }

    public func flag(_ at: Int) -> Bool { unsigned(at, 1) == 1 }

    /// `count` characters of six-bit ASCII from `start` (padding `@` at the end removed, trailing spaces too).
    public func text(_ start: Int, characters: Int) -> String {
        var out = ""
        for k in 0..<characters {
            let v = unsigned(start + 6 * k, 6)
            out.unicodeScalars.append(Unicode.Scalar(UInt8(v < 32 ? v + 64 : v)))
        }
        while let last = out.last, last == "@" || last == " " { out.removeLast() }
        // A name's padding is `@`s; anything after the first `@` is padding too.
        if let cut = out.firstIndex(of: "@") { out = String(out[..<cut]).trimmingCharacters(in: .whitespaces) }
        return out
    }

    /// The six-bit armour of NMEA's `!AIVDM`: each six bits as a character, and how many bits of padding the last one has.
    public var armoured: (payload: String, fillBits: Int) {
        var out = ""
        var k = 0
        while k < bits.count {
            var v = 0
            for j in 0..<6 { v = v << 1 | (k + j < bits.count ? Int(bits[k + j]) : 0) }
            out.unicodeScalars.append(Unicode.Scalar(UInt8(v < 40 ? v + 48 : v + 56)))
            k += 6
        }
        return (out, (6 - bits.count % 6) % 6)
    }

    /// The bits of an armoured payload.
    public init?(armoured payload: String, fillBits: Int = 0) {
        var bits: [UInt8] = []
        for scalar in payload.unicodeScalars {
            guard scalar.value >= 48, scalar.value <= 119, !(scalar.value > 87 && scalar.value < 96) else { return nil }
            let v = Int(scalar.value) - (scalar.value < 88 ? 48 : 56)
            for j in 0..<6 { bits.append(UInt8(v >> (5 - j) & 1)) }
        }
        guard fillBits >= 0, fillBits <= 5, bits.count >= fillBits else { return nil }
        self.bits = Array(bits.dropLast(fillBits))
    }
}

/// An `!AIVDM` sentence's checksum: the XOR of the characters between `!` and `*`.
func nmeaChecksum(_ body: String) -> String {
    String(format: "%02X", body.utf8.reduce(0) { $0 ^ $1 })
}

/// What an AIS message says (the fields of the commonly sent types; others give the type and MMSI only).
public struct AISMessage: Sendable, Equatable {
    public var type: Int
    public var repeatIndicator: Int
    public var mmsi: Int

    // Position reports (1, 2, 3, 18, 19), base stations (4, 11) and aids to navigation (21).
    public var navigationStatus: Int?
    public var rateOfTurn: Int?
    public var speedKnots: Double?
    public var positionAccurate: Bool?
    public var longitude: Double?
    public var latitude: Double?
    public var courseDegrees: Double?
    public var heading: Int?
    public var second: Int?
    // Base station time.
    public var year: Int?, month: Int?, day: Int?, hour: Int?, minute: Int?

    // Static and voyage data (5, 19, 24, 21).
    public var name: String?
    public var callsign: String?
    public var imo: Int?
    public var shipType: Int?
    public var toBow: Int?, toStern: Int?, toPort: Int?, toStarboard: Int?
    public var draught: Double?
    public var destination: String?
    public var etaMonth: Int?, etaDay: Int?, etaHour: Int?, etaMinute: Int?
    public var aidType: Int?
    /// Type 24: 0 for part A (the name), 1 for part B (the ship's type, call sign and size).
    public var part: Int?
    public var vendorID: String?

    /// How long the message was, bits.
    public var bitCount: Int

    /// Decodes a message's bits; nil if there are too few bits for the fields its type has (a damaged frame can have a
    /// good checksum by chance).
    public init?(_ bits: AISBits) {
        guard bits.count >= 38 else { return nil }
        type = bits.unsigned(0, 6)
        repeatIndicator = bits.unsigned(6, 2)
        mmsi = bits.unsigned(8, 30)
        bitCount = bits.count
        func position(_ lonAt: Int) {
            let lon = bits.signed(lonAt, 28), lat = bits.signed(lonAt + 28, 27)
            longitude = lon == 108_600_000 ? nil : Double(lon) / 600_000
            latitude = lat == 54_600_000 ? nil : Double(lat) / 600_000
        }
        func speed(_ at: Int) { let v = bits.unsigned(at, 10); speedKnots = v == 1023 ? nil : Double(v) / 10 }
        func course(_ at: Int) { let v = bits.unsigned(at, 12); courseDegrees = v == 3600 ? nil : Double(v) / 10 }
        func headingAt(_ at: Int) { let v = bits.unsigned(at, 9); heading = v == 511 ? nil : v }
        switch type {
        case 1, 2, 3:
            guard bits.count >= 168 else { return nil }
            navigationStatus = bits.unsigned(38, 4)
            let rot = bits.signed(42, 8)
            rateOfTurn = rot == -128 ? nil : rot
            speed(50)
            positionAccurate = bits.flag(60)
            position(61)
            course(116)
            headingAt(128)
            second = bits.unsigned(137, 6)
        case 4, 11:
            guard bits.count >= 168 else { return nil }
            year = bits.unsigned(38, 14); month = bits.unsigned(52, 4); day = bits.unsigned(56, 5)
            hour = bits.unsigned(61, 5); minute = bits.unsigned(66, 6); second = bits.unsigned(72, 6)
            positionAccurate = bits.flag(78)
            position(79)
        case 5:
            guard bits.count >= 424 else { return nil }
            imo = bits.unsigned(40, 30)
            callsign = bits.text(70, characters: 7)
            name = bits.text(112, characters: 20)
            shipType = bits.unsigned(232, 8)
            toBow = bits.unsigned(240, 9); toStern = bits.unsigned(249, 9); toPort = bits.unsigned(258, 6); toStarboard = bits.unsigned(264, 6)
            etaMonth = bits.unsigned(274, 4); etaDay = bits.unsigned(278, 5); etaHour = bits.unsigned(283, 5); etaMinute = bits.unsigned(288, 6)
            draught = Double(bits.unsigned(294, 8)) / 10
            destination = bits.text(302, characters: 20)
        case 18:
            guard bits.count >= 168 else { return nil }
            speed(46)
            positionAccurate = bits.flag(56)
            position(57)
            course(112)
            headingAt(124)
            second = bits.unsigned(133, 6)
        case 19:
            guard bits.count >= 312 else { return nil }
            speed(46)
            positionAccurate = bits.flag(56)
            position(57)
            course(112)
            headingAt(124)
            second = bits.unsigned(133, 6)
            name = bits.text(143, characters: 20)
            shipType = bits.unsigned(263, 8)
            toBow = bits.unsigned(271, 9); toStern = bits.unsigned(280, 9); toPort = bits.unsigned(289, 6); toStarboard = bits.unsigned(295, 6)
        case 21:
            guard bits.count >= 272 else { return nil }
            aidType = bits.unsigned(38, 5)
            name = bits.text(43, characters: 20)
            positionAccurate = bits.flag(163)
            position(164)
            toBow = bits.unsigned(219, 9); toStern = bits.unsigned(228, 9); toPort = bits.unsigned(237, 6); toStarboard = bits.unsigned(243, 6)
            second = bits.unsigned(253, 6)
        case 24:
            guard bits.count >= 160 else { return nil }
            part = bits.unsigned(38, 2)
            if part == 0 {
                name = bits.text(40, characters: 20)
            } else if part == 1, bits.count >= 162 {
                shipType = bits.unsigned(40, 8)
                vendorID = bits.text(48, characters: 3)
                callsign = bits.text(90, characters: 7)
                toBow = bits.unsigned(132, 9); toStern = bits.unsigned(141, 9); toPort = bits.unsigned(150, 6); toStarboard = bits.unsigned(156, 6)
            } else { return nil }
        default: break
        }
    }

    /// What a type is called.
    public var typeName: String {
        switch type {
        case 1, 2, 3: return "Position report (class A)"
        case 4: return "Base station report"
        case 5: return "Static and voyage data (class A)"
        case 11: return "UTC and date response"
        case 18: return "Position report (class B)"
        case 19: return "Extended position report (class B)"
        case 21: return "Aid to navigation"
        case 24: return "Static data (class B)" + (part.map { $0 == 0 ? ", part A" : ", part B" } ?? "")
        default: return "Message type \(type)"
        }
    }

    /// One line.
    public var line: String {
        var text = String(format: "MMSI %09d  %@", mmsi, typeName)
        if let name { text += "  \"\(name)\"" }
        if let callsign, !callsign.isEmpty { text += "  call \(callsign)" }
        if let latitude, let longitude { text += String(format: "  %.5f %.5f", latitude, longitude) }
        if let speedKnots { text += String(format: "  %.1f kn", speedKnots) }
        if let courseDegrees { text += String(format: "  %.1f°", courseDegrees) }
        if let destination, !destination.isEmpty { text += "  to \(destination)" }
        return text
    }

    /// A JSON object with the fields that are present, named as pyais names them.
    public func json(channel: String? = nil, frequencyHz: Double? = nil) -> String {
        var parts: [String] = ["\"type\": \(type)", "\"repeat\": \(repeatIndicator)", String(format: "\"mmsi\": %d", mmsi)]
        func add(_ key: String, _ value: Int?) { if let value { parts.append("\"\(key)\": \(value)") } }
        func add(_ key: String, _ value: Double?, _ digits: Int = 1) {
            if let value { parts.append("\"\(key)\": " + String(format: "%.\(digits)f", value)) }
        }
        func add(_ key: String, _ value: String?) {
            guard let value else { return }
            var s = ""
            for scalar in value.unicodeScalars { s += scalar == "\"" || scalar == "\\" ? "\\" + String(scalar) : String(scalar) }
            parts.append("\"\(key)\": \"\(s)\"")
        }
        add("status", navigationStatus); add("rot", rateOfTurn); add("speed", speedKnots)
        if let positionAccurate { parts.append("\"accuracy\": \(positionAccurate)") }
        add("lon", longitude, 6); add("lat", latitude, 6); add("course", courseDegrees); add("heading", heading); add("second", second)
        add("year", year); add("month", month); add("day", day); add("hour", hour); add("minute", minute)
        add("shipname", name); add("callsign", callsign); add("imo", imo); add("ship_type", shipType); add("aid_type", aidType)
        add("to_bow", toBow); add("to_stern", toStern); add("to_port", toPort); add("to_starboard", toStarboard)
        add("draught", draught); add("destination", destination); add("partno", part); add("vendorid", vendorID)
        if type == 5 { add("month", etaMonth); add("day", etaDay); add("hour", etaHour); add("minute", etaMinute) }
        if let channel { add("channel", channel) }
        if let frequencyHz { add("freq", (frequencyHz / 1e3).rounded() / 1e3, 3) }
        return "{" + parts.joined(separator: ", ") + "}"
    }
}

/// A frame received: the message's bits and the sentences that carry them.
public struct AISPacket: Sendable {
    public var bits: AISBits
    public var message: AISMessage?
    /// "A" for 161.975 MHz, "B" for 162.025 MHz (nil if the receiver does not know).
    public var channel: String?

    /// The `!AIVDM` sentences (more than one for a long message), 60 characters of payload at most each.
    public func sentences(sequentialID: Int = 0) -> [String] {
        let (payload, fill) = bits.armoured
        let chunks = stride(from: 0, to: payload.count, by: 60).map { start -> String in
            let from = payload.index(payload.startIndex, offsetBy: start), to = payload.index(from, offsetBy: min(60, payload.count - start))
            return String(payload[from..<to])
        }
        return chunks.enumerated().map { index, chunk in
            let body = "AIVDM,\(chunks.count),\(index + 1),\(chunks.count > 1 ? String(sequentialID % 10) : ""),\(channel ?? ""),\(chunk),\(index == chunks.count - 1 ? fill : 0)"
            return "!\(body)*\(nmeaChecksum(body))"
        }
    }
}
