// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A decoded Mode S reply or ADS-B extended squitter.
///
/// Field layouts follow ICAO Annex 10 Vol. IV and the openly published description in Junzi Sun, *The 1090 MHz Riddle*
/// (2nd ed., TU Delft OPEN, 2021). Bit numbers in comments count from 1 at the first bit of the message, as those do.
public struct ModeSMessage: Sendable, Equatable {
    public let bytes: [UInt8]
    public let downlinkFormat: Int
    /// The aircraft's 24-bit ICAO address: from the address field (DF11/17/18) or recovered from the parity (others).
    public let address: UInt32
    public let content: Content

    public enum Content: Sendable, Equatable {
        /// DF0, DF4, DF16, DF20: barometric altitude, feet (nil if not available or metric).
        case altitude(Int?)
        /// DF5, DF21: the squawk, as four octal digits.
        case identity(String)
        /// DF11: reply to an all-call; `capability` is the CA field.
        case allCall(capability: Int)
        /// DF17, DF18 (CF 0): ADS-B.
        case extendedSquitter(ExtendedSquitter)
        /// Anything else (DF24 Comm-D, TIS-B, reserved formats).
        case other
    }

    /// Parses a message whose parity has already been checked. `address` must be supplied for address/parity formats.
    public init(bytes: [UInt8], address recovered: UInt32? = nil) {
        self.bytes = bytes
        let format = Int(bytes[0] >> 3)
        downlinkFormat = format >= 24 ? 24 : format
        let bits = BitReader(bytes)
        switch downlinkFormat {
        case 11, 17, 18:
            address = UInt32(bits.value(9, 32))
        default:
            address = recovered ?? ModeSCRC.syndrome(bytes)
        }
        switch downlinkFormat {
        case 0, 4, 16, 20:
            content = .altitude(ModeSMessage.altitudeFromAC13(Int(bits.value(20, 32))))
        case 5, 21:
            content = .identity(ModeSMessage.squawk(fromID13: Int(bits.value(20, 32))))
        case 11:
            content = .allCall(capability: Int(bits.value(6, 8)))
        case 17:
            content = .extendedSquitter(ExtendedSquitter(bits))
        case 18 where bits.value(6, 8) == 0:
            content = .extendedSquitter(ExtendedSquitter(bits))
        default:
            content = .other
        }
    }

    public var hex: String { bytes.map { String(format: "%02X", $0) }.joined() }

    // MARK: Altitude and identity codes

    /// The 13-bit altitude code of surveillance replies: M (bit 7 of the field) selects metres, Q (bit 9) 25-ft steps.
    static func altitudeFromAC13(_ code: Int) -> Int? {
        guard code != 0 else { return nil }
        let metric = code & 0x40 != 0
        guard !metric else { return nil }
        if code & 0x10 != 0 {
            // Remove M and Q: the 11 remaining bits count 25 ft steps from -1000 ft.
            let n = ((code & 0x1f80) >> 2) | ((code & 0x20) >> 1) | (code & 0x0f)
            return n * 25 - 1000
        }
        return gillhamAltitude(code)
    }

    /// The 12-bit altitude field of airborne position squitters (the AC13 code without its M bit).
    static func altitudeFromAC12(_ code: Int) -> Int? {
        guard code != 0 else { return nil }
        let ac13 = ((code & 0xfc0) << 1) | (code & 0x3f)
        return altitudeFromAC13(ac13)
    }

    /// Gillham (Mode C) coded altitude, 100 ft steps, used when Q = 0. Bits of the 13-bit field, most significant first:
    /// C1 A1 C2 A2 C4 A4 M B1 Q B2 D2 B4 D4.
    static func gillhamAltitude(_ code: Int) -> Int? {
        func bit(_ position: Int) -> Int { (code >> (12 - position)) & 1 }       // position 0 = first (C1)
        let c1 = bit(0), a1 = bit(1), c2 = bit(2), a2 = bit(3), c4 = bit(4), a4 = bit(5)
        let b1 = bit(7), b2 = bit(9), d2 = bit(10), b4 = bit(11), d4 = bit(12)
        // The 500 ft code is a Gray code over D2 D4 A1 A2 A4 B1 B2 B4 (D1 is never used for altitude).
        let gray500 = [d2, d4, a1, a2, a4, b1, b2, b4].reduce(0) { $0 << 1 | $1 }
        var n500 = 0
        var shifted = gray500
        while shifted != 0 { n500 ^= shifted; shifted >>= 1 }
        // The 100 ft code is a five-state Gray code over C1 C2 C4, counting down on odd 500 ft steps.
        let gray100 = c1 << 2 | c2 << 1 | c4
        let states: [Int: Int] = [0b001: 1, 0b011: 2, 0b010: 3, 0b110: 4, 0b100: 5]
        guard var n100 = states[gray100] else { return nil }
        if n500 % 2 == 1 { n100 = 6 - n100 }
        return n500 * 500 + n100 * 100 - 1300
    }

    /// Four octal digits from the 13-bit identity code: C1 A1 C2 A2 C4 A4 X B1 D1 B2 D2 B4 D4.
    static func squawk(fromID13 code: Int) -> String {
        func bit(_ position: Int) -> Int { (code >> (12 - position)) & 1 }
        let a = bit(5) << 2 | bit(3) << 1 | bit(1)
        let b = bit(11) << 2 | bit(9) << 1 | bit(7)
        let c = bit(4) << 2 | bit(2) << 1 | bit(0)
        let d = bit(12) << 2 | bit(10) << 1 | bit(8)
        return "\(a)\(b)\(c)\(d)"
    }
}

/// The ADS-B payload (the 56-bit ME field, message bits 33-88), by type code.
public enum ExtendedSquitter: Sendable, Equatable {
    /// Type codes 1-4.
    case identification(Identification)
    /// Type codes 9-18 (barometric altitude) and 20-22 (GNSS height).
    case airbornePosition(AirbornePosition)
    /// Type code 19.
    case velocity(Velocity)
    /// Type code 28, subtype 1.
    case emergency(state: Int, squawk: String)
    case other(typeCode: Int)

    public struct Identification: Sendable, Equatable {
        public var typeCode: Int
        public var category: Int
        public var callsign: String
    }

    public struct AirbornePosition: Sendable, Equatable {
        public var typeCode: Int
        /// Feet; barometric for type codes 9-18, GNSS height for 20-22.
        public var altitudeFeet: Int?
        public var altitudeIsGNSS: Bool
        public var surveillanceStatus: Int
        public var cpr: CPRPosition
    }

    public struct Velocity: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// Over the ground (subtypes 1 and 2): speed in knots, track in degrees true.
            case ground(speedKnots: Double, trackDegrees: Double)
            /// Through the air (subtypes 3 and 4): heading in degrees (if available), airspeed in knots.
            case air(headingDegrees: Double?, airspeedKnots: Int?, isTrueAirspeed: Bool)
        }
        public var subtype: Int
        public var kind: Kind?
        /// Feet per minute (negative: descending).
        public var verticalRateFPM: Int?
        public var verticalRateIsGNSS: Bool
        /// GNSS height minus barometric altitude, feet.
        public var gnssMinusBaroFeet: Int?
    }

    static let callsignCharacters = Array("#ABCDEFGHIJKLMNOPQRSTUVWXYZ##### ###############0123456789######")

    init(_ bits: BitReader) {
        let typeCode = Int(bits.value(33, 37))
        switch typeCode {
        case 1...4:
            let characters = (0..<8).map { Self.callsignCharacters[Int(bits.value(41 + 6 * $0, 46 + 6 * $0))] }
            let callsign = String(characters).trimmingCharacters(in: CharacterSet(charactersIn: " #"))
            self = .identification(Identification(typeCode: typeCode, category: Int(bits.value(38, 40)), callsign: callsign))
        case 9...18, 20...22:
            let gnss = typeCode >= 20
            let code = Int(bits.value(41, 52))
            // Barometric altitude uses the altitude code; GNSS height is a plain count of metres (reported here in feet).
            let altitude = gnss ? (code == 0 ? nil : Int(Double(code) * 3.28084)) : ModeSMessage.altitudeFromAC12(code)
            let cpr = CPRPosition(isOdd: bits.value(54, 54) == 1, latitude: Int(bits.value(55, 71)), longitude: Int(bits.value(72, 88)))
            self = .airbornePosition(AirbornePosition(typeCode: typeCode, altitudeFeet: altitude, altitudeIsGNSS: gnss,
                                                      surveillanceStatus: Int(bits.value(38, 39)), cpr: cpr))
        case 19:
            self = .velocity(Self.velocity(bits))
        case 28 where bits.value(38, 40) == 1:
            self = .emergency(state: Int(bits.value(41, 43)), squawk: ModeSMessage.squawk(fromID13: Int(bits.value(44, 56))))
        default:
            self = .other(typeCode: typeCode)
        }
    }

    private static func velocity(_ bits: BitReader) -> Velocity {
        let subtype = Int(bits.value(38, 40))
        let factor = subtype == 2 || subtype == 4 ? 4 : 1
        var kind: Velocity.Kind?
        switch subtype {
        case 1, 2:
            let east = Int(bits.value(47, 56)), north = Int(bits.value(58, 67))
            if east != 0 && north != 0 {
                let vx = Double((east - 1) * factor) * (bits.value(46, 46) == 1 ? -1 : 1)     // west is negative
                let vy = Double((north - 1) * factor) * (bits.value(57, 57) == 1 ? -1 : 1)    // south is negative
                var track = atan2(vx, vy) * 180 / .pi
                if track < 0 { track += 360 }
                kind = .ground(speedKnots: (vx * vx + vy * vy).squareRoot(), trackDegrees: track)
            }
        case 3, 4:
            let heading = bits.value(46, 46) == 1 ? Double(bits.value(47, 56)) * 360 / 1024 : nil
            let raw = Int(bits.value(58, 67))
            kind = .air(headingDegrees: heading, airspeedKnots: raw == 0 ? nil : (raw - 1) * factor, isTrueAirspeed: bits.value(57, 57) == 1)
        default:
            break
        }
        let rate = Int(bits.value(70, 78))
        let verticalRate = rate == 0 ? nil : (rate - 1) * 64 * (bits.value(69, 69) == 1 ? -1 : 1)
        let difference = Int(bits.value(82, 88))
        let gnssMinusBaro = difference == 0 ? nil : (difference - 1) * 25 * (bits.value(81, 81) == 1 ? -1 : 1)
        return Velocity(subtype: subtype, kind: kind, verticalRateFPM: verticalRate, verticalRateIsGNSS: bits.value(68, 68) == 0,
                        gnssMinusBaroFeet: gnssMinusBaro)
    }
}

/// Reads bit ranges, numbered from 1 at the first bit of the message.
struct BitReader {
    let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// Bits `first` through `last` inclusive, as an unsigned number.
    func value(_ first: Int, _ last: Int) -> UInt64 {
        var result: UInt64 = 0
        for position in first...last {
            let index = position - 1
            result = result << 1 | UInt64((bytes[index / 8] >> UInt8(7 - index % 8)) & 1)
        }
        return result
    }
}
