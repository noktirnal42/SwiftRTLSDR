// SPDX-License-Identifier: GPL-2.0-or-later
//
// UAT downlink (ADS-B) message decoding, ported from uat_decode.c in dump978 by Oliver Jowett (GPL-2.0-or-later,
// https://github.com/mutability/dump978). The aircraft size table is the DO-282B table as used by FlightAware's
// dump978 (BSD-2-Clause); the original dump978 read the length from the wrong bits. See PROVENANCE.md.
import Foundation

/// An ADS-B message sent on UAT (by aircraft, ground vehicles, or relayed as TIS-B/ADS-R by ground stations).
public struct UATADSBMessage: Sendable, Equatable {
    public enum AddressQualifier: Int, Sendable {
        case adsbICAO = 0, national, tisbICAO, tisbTrackFile, vehicle, fixedBeacon, reserved6, reserved7
    }
    public enum AltitudeType: Int, Sendable { case barometric = 1, geometric = 2 }
    public enum AirGround: Int, Sendable { case subsonic = 0, supersonic, onGround, reserved }
    public enum TrackType: Int, Sendable { case track = 1, magneticHeading, trueHeading }

    public struct Altitude: Sendable, Equatable {
        public var feet: Int
        public var type: AltitudeType
    }

    public struct StateVector: Sendable, Equatable {
        public var nic: Int
        public var latitude: Double?
        public var longitude: Double?
        public var altitude: Altitude?
        public var airGround: AirGround
        /// Knots, positive north / east.
        public var northVelocity: Int?
        public var eastVelocity: Int?
        public var track: (degrees: Int, type: TrackType)?
        public var speedKnots: Int?
        /// Feet per minute, and which altitude it is derived from.
        public var verticalRate: (feetPerMinute: Int, source: AltitudeType)?
        /// Length and width in metres (on the ground only), and whether the position has the antenna offset applied.
        public var dimensions: (length: Double, width: Double)?
        public var positionOffsetApplied: Bool
        public var utcCoupled: Bool
        public var tisbSiteID: Int

        public static func == (a: StateVector, b: StateVector) -> Bool {
            a.nic == b.nic && a.latitude == b.latitude && a.longitude == b.longitude && a.altitude == b.altitude
                && a.airGround == b.airGround && a.northVelocity == b.northVelocity && a.eastVelocity == b.eastVelocity
                && a.track?.degrees == b.track?.degrees && a.track?.type == b.track?.type && a.speedKnots == b.speedKnots
                && a.verticalRate?.feetPerMinute == b.verticalRate?.feetPerMinute && a.verticalRate?.source == b.verticalRate?.source
                && a.dimensions?.length == b.dimensions?.length && a.dimensions?.width == b.dimensions?.width
                && a.positionOffsetApplied == b.positionOffsetApplied && a.utcCoupled == b.utcCoupled && a.tisbSiteID == b.tisbSiteID
        }
    }

    public struct ModeStatus: Sendable, Equatable {
        public var emitterCategory: Int
        /// nil when blank. `callsignIsSquawk` says whether it holds a flight ID or a Mode 3/A code.
        public var callsign: String?
        public var callsignIsSquawk: Bool
        public var emergency: Int
        public var uatVersion: Int
        public var sil: Int
        public var transmitMSO: Int
        public var nacP: Int
        public var nacV: Int
        public var nicBaro: Int
        public var hasCDTI: Bool
        public var hasACAS: Bool
        public var acasResolutionActive: Bool
        public var identActive: Bool
        public var atcServices: Bool
        public var headingIsMagnetic: Bool
    }

    public let payloadType: Int
    public let addressQualifier: AddressQualifier
    public let address: UInt32
    public let stateVector: StateVector?
    public let modeStatus: ModeStatus?
    /// The other altitude (geometric if the state vector's is barometric, and vice versa), from the AUXSV element.
    public let secondaryAltitude: Altitude?

    public var addressHex: String { String(format: "%06X", address) }

    public init(payload frame: [UInt8]) {
        precondition(frame.count >= UAT.basicPayloadBytes, "a UAT downlink payload is 18 or 34 bytes")
        payloadType = Int(frame[0] >> 3) & 0x1f
        addressQualifier = AddressQualifier(rawValue: Int(frame[0] & 0x07))!
        address = UInt32(frame[1]) << 16 | UInt32(frame[2]) << 8 | UInt32(frame[3])
        let long = frame.count >= UAT.longPayloadBytes
        let (sv, ms, aux): (Bool, Bool, Bool)
        switch payloadType {
        case 0, 4, 7, 8, 9, 10: (sv, ms, aux) = (true, false, false)
        case 1: (sv, ms, aux) = (true, true, true)
        case 2, 5, 6: (sv, ms, aux) = (true, false, true)
        case 3: (sv, ms, aux) = (true, true, false)
        default: (sv, ms, aux) = (false, false, false)
        }
        stateVector = sv ? Self.stateVector(frame) : nil
        modeStatus = ms && long ? Self.modeStatus(frame) : nil
        secondaryAltitude = aux && long ? Self.auxiliaryAltitude(frame) : nil
    }

    private static let sizes: [(length: Double, width: Double)] = [
        (0, 0), (15, 23), (25, 28.5), (25, 34), (35, 33), (35, 38), (45, 39.5), (45, 45),
        (55, 45), (55, 52), (65, 59.5), (65, 67), (75, 72.5), (75, 80), (85, 80), (85, 90),
    ]

    private static func stateVector(_ f: [UInt8]) -> StateVector {
        let nic = Int(f[11] & 15)
        let rawLat = Int(f[4]) << 15 | Int(f[5]) << 7 | Int(f[6]) >> 1
        let rawLon = Int(f[6] & 0x01) << 23 | Int(f[7]) << 15 | Int(f[8]) << 7 | Int(f[9]) >> 1
        var latitude: Double?, longitude: Double?
        if nic != 0 || rawLat != 0 || rawLon != 0 {
            var lat = Double(rawLat) * 360 / 16_777_216
            if lat > 90 { lat -= 180 }
            var lon = Double(rawLon) * 360 / 16_777_216
            if lon > 180 { lon -= 360 }
            latitude = lat
            longitude = lon
        }
        let rawAltitude = Int(f[10]) << 4 | Int(f[11] & 0xf0) >> 4
        let altitude = rawAltitude == 0 ? nil : Altitude(feet: (rawAltitude - 1) * 25 - 1000, type: f[9] & 1 != 0 ? .geometric : .barometric)
        let airGround = AirGround(rawValue: Int(f[12] >> 6) & 0x03)!

        var vector = StateVector(nic: nic, latitude: latitude, longitude: longitude, altitude: altitude, airGround: airGround,
                                 positionOffsetApplied: false, utcCoupled: false, tisbSiteID: 0)
        switch airGround {
        case .subsonic, .supersonic:
            let factor = airGround == .supersonic ? 4 : 1
            let rawNorth = Int(f[12] & 0x1f) << 6 | Int(f[13] & 0xfc) >> 2
            if rawNorth & 0x3ff != 0 {
                vector.northVelocity = ((rawNorth & 0x3ff) - 1) * (rawNorth & 0x400 != 0 ? -1 : 1) * factor
            }
            let rawEast = Int(f[13] & 0x03) << 9 | Int(f[14]) << 1 | Int(f[15] & 0x80) >> 7
            if rawEast & 0x3ff != 0 {
                vector.eastVelocity = ((rawEast & 0x3ff) - 1) * (rawEast & 0x400 != 0 ? -1 : 1) * factor
            }
            if let north = vector.northVelocity, let east = vector.eastVelocity {
                if north != 0 || east != 0 {
                    // Truncated to whole degrees, as dump978 does.
                    vector.track = (Int(360 + 90 - atan2(Double(north), Double(east)) * 180 / .pi) % 360, .track)
                }
                vector.speedKnots = Int(Double(north * north + east * east).squareRoot())
            }
            let rawVertical = Int(f[15] & 0x7f) << 4 | Int(f[16] & 0xf0) >> 4
            if rawVertical & 0x1ff != 0 {
                vector.verticalRate = (((rawVertical & 0x1ff) - 1) * 64 * (rawVertical & 0x200 != 0 ? -1 : 1),
                                       rawVertical & 0x400 != 0 ? .barometric : .geometric)
            }
        case .onGround:
            let rawSpeed = Int(f[12] & 0x1f) << 6 | Int(f[13] & 0xfc) >> 2
            if rawSpeed != 0 { vector.speedKnots = (rawSpeed & 0x3ff) - 1 }
            let rawTrack = Int(f[13] & 0x03) << 9 | Int(f[14]) << 1 | Int(f[15] & 0x80) >> 7
            if let type = TrackType(rawValue: (rawTrack & 0x0600) >> 9) {
                vector.track = ((rawTrack & 0x1ff) * 360 / 512, type)
            }
            let size = sizes[Int(f[15] & 0x78) >> 3]
            vector.dimensions = size.length == 0 ? nil : size
            vector.positionOffsetApplied = f[15] & 0x04 != 0
        case .reserved:
            break
        }
        let qualifier = f[0] & 7
        if qualifier == 2 || qualifier == 3 {
            vector.tisbSiteID = Int(f[16] & 0x0f)
        } else {
            vector.utcCoupled = f[16] & 0x08 != 0
        }
        return vector
    }

    private static let base40 = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ  ..")

    private static func modeStatus(_ f: [UInt8]) -> ModeStatus {
        var characters: [Character] = []
        let first = Int(f[17]) << 8 | Int(f[18])
        characters += [base40[(first / 40) % 40], base40[first % 40]]
        for index in [19, 21] {
            let value = Int(f[index]) << 8 | Int(f[index + 1])
            characters += [base40[(value / 1600) % 40], base40[(value / 40) % 40], base40[value % 40]]
        }
        let callsign = String(characters).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return ModeStatus(
            emitterCategory: (first / 1600) % 40,
            callsign: callsign.isEmpty ? nil : callsign,
            callsignIsSquawk: !callsign.isEmpty && f[26] & 0x02 == 0,
            emergency: Int(f[23] >> 5) & 7, uatVersion: Int(f[23] >> 2) & 7, sil: Int(f[23] & 3),
            transmitMSO: Int(f[24] >> 2) & 0x3f, nacP: Int(f[25] >> 4) & 15, nacV: Int(f[25] >> 1) & 7, nicBaro: Int(f[25] & 1),
            hasCDTI: f[26] & 0x80 != 0, hasACAS: f[26] & 0x40 != 0, acasResolutionActive: f[26] & 0x20 != 0,
            identActive: f[26] & 0x10 != 0, atcServices: f[26] & 0x08 != 0, headingIsMagnetic: f[26] & 0x04 != 0)
    }

    private static func auxiliaryAltitude(_ f: [UInt8]) -> Altitude? {
        let raw = Int(f[29]) << 4 | Int(f[30] & 0xf0) >> 4
        guard raw != 0 else { return nil }
        return Altitude(feet: (raw - 1) * 25 - 1000, type: f[9] & 1 != 0 ? .barometric : .geometric)
    }
}
