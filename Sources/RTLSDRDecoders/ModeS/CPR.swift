// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// One Compact Position Reporting fix: 17-bit fractions of a latitude and a longitude zone, in one of two zone
/// layouts (even or odd). A position needs either an even/odd pair or a nearby reference to resolve.
public struct CPRPosition: Sendable, Equatable {
    public var isOdd: Bool
    public var latitude: Int
    public var longitude: Int

    public init(isOdd: Bool, latitude: Int, longitude: Int) {
        self.isOdd = isOdd
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Airborne CPR decoding (NZ = 15 latitude zones per quadrant), as in ICAO Annex 10 Vol. IV / DO-260B.
public enum CPR {
    static let scale = 131_072.0                                    // 2^17

    /// NL: how many longitude zones a latitude band has (59 at the equator, 1 at the poles).
    public static func longitudeZones(_ latitude: Double) -> Int {
        let magnitude = abs(latitude)
        if magnitude == 0 { return 59 }
        if magnitude == 87 { return 2 }
        if magnitude > 87 { return 1 }
        let nz = 15.0
        let a = 1 - cos(.pi / (2 * nz))
        let b = pow(cos(.pi / 180 * magnitude), 2)
        return Int(floor(2 * .pi / acos(1 - a / b)))
    }

    private static func modulo(_ x: Double, _ y: Double) -> Double { x - y * floor(x / y) }

    /// A position from an even and an odd fix taken close together (under 10 s apart for airborne targets); the
    /// result uses the newer fix. nil when the two straddle a longitude-zone boundary or resolve to an impossible latitude.
    public static func global(even: CPRPosition, odd: CPRPosition, newestIsOdd: Bool) -> (latitude: Double, longitude: Double)? {
        let latEven = Double(even.latitude) / scale, latOdd = Double(odd.latitude) / scale
        let lonEven = Double(even.longitude) / scale, lonOdd = Double(odd.longitude) / scale
        let j = floor(59 * latEven - 60 * latOdd + 0.5)
        var resolvedEven = 360.0 / 60 * (modulo(j, 60) + latEven)
        var resolvedOdd = 360.0 / 59 * (modulo(j, 59) + latOdd)
        if resolvedEven >= 270 { resolvedEven -= 360 }
        if resolvedOdd >= 270 { resolvedOdd -= 360 }
        // A corrupt or mismatched pair can land outside the globe, or straddle a longitude-zone boundary.
        guard abs(resolvedEven) <= 90, abs(resolvedOdd) <= 90,
              longitudeZones(resolvedEven) == longitudeZones(resolvedOdd) else { return nil }

        let latitude = newestIsOdd ? resolvedOdd : resolvedEven
        let nl = longitudeZones(latitude)
        let zones = max(nl - (newestIsOdd ? 1 : 0), 1)
        let m = floor(lonEven * Double(nl - 1) - lonOdd * Double(nl) + 0.5)
        var longitude = 360.0 / Double(zones) * (modulo(m, Double(zones)) + (newestIsOdd ? lonOdd : lonEven))
        if longitude >= 180 { longitude -= 360 }
        return (latitude, longitude)
    }

    /// A position from one fix and a reference within about 180 NM (the receiver, or the aircraft's last position).
    public static func local(_ fix: CPRPosition, reference: (latitude: Double, longitude: Double)) -> (latitude: Double, longitude: Double) {
        let latFraction = Double(fix.latitude) / scale, lonFraction = Double(fix.longitude) / scale
        let latZone = 360.0 / (fix.isOdd ? 59 : 60)
        let j = floor(reference.latitude / latZone) + floor(modulo(reference.latitude, latZone) / latZone - latFraction + 0.5)
        let latitude = latZone * (j + latFraction)
        let lonZone = 360.0 / Double(max(longitudeZones(latitude) - (fix.isOdd ? 1 : 0), 1))
        let m = floor(reference.longitude / lonZone) + floor(modulo(reference.longitude, lonZone) / lonZone - lonFraction + 0.5)
        var longitude = lonZone * (m + lonFraction)
        if longitude >= 180 { longitude -= 360 } else if longitude < -180 { longitude += 360 }
        return (latitude, longitude)
    }
}
