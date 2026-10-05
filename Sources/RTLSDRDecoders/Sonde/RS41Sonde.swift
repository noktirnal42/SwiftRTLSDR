// SPDX-License-Identifier: GPL-2.0-or-later
//
// What an RS41 frame says, in the units people use: WGS84 position, velocity over ground, GPS time, temperature from
// the calibration table the sonde sends a piece at a time. The calibration layout and the temperature model follow
// rs1729's rs41mod (GPL-3.0, read for these facts only; no code taken). See PROVENANCE.md.
import Foundation

/// One position report from an RS41, as radiosonde trackers show it.
public struct RS41Report: Sendable {
    public var frame: Int
    public var serial: String
    /// GPS time (no leap seconds applied), as the sonde reports it.
    public var gpsWeek: Int
    public var gpsMilliseconds: Int
    public var latitude: Double
    public var longitude: Double
    /// Height above the WGS84 ellipsoid, metres.
    public var altitude: Double
    public var horizontalSpeed: Double
    /// Direction of travel, degrees from north.
    public var heading: Double
    public var verticalSpeed: Double
    public var satellites: Int
    public var batteryVolts: Double
    /// °C, once the calibration pieces it needs have arrived.
    public var temperature: Double?
    /// "RS41-SG", "RS41-SGP" (with pressure sensor) and so on, once known; "RS41" before.
    public var subtype: String
    /// The transmit frequency the sonde was set to, kHz, once known.
    public var frequencyKHz: Int?
    /// The burst-kill countdown, seconds (65535 until known or when off).
    public var countdown: Int
    /// How many calibration pieces (of 51) have arrived.
    public var calibrationPieces: Int

    /// Year, month, day, hour, minute and seconds of the GPS time.
    public var dateTime: (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Double) {
        let days = gpsWeek * 7 + gpsMilliseconds / 86_400_000 + 3657       // 1980-01-06 is day 3657 of 1970
        // Days since 1970-01-01 to a civil date (the proleptic Gregorian calendar, era by era).
        let z = days + 719_468, era = (z >= 0 ? z : z - 146_096) / 146_097, dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1, month = mp < 10 ? mp + 3 : mp - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        let ms = gpsMilliseconds % 86_400_000
        return (year, month, day, ms / 3_600_000, ms / 60_000 % 60, Double(ms % 60_000) / 1000)
    }

    public var isoTime: String {
        let t = dateTime
        return String(format: "%04d-%02d-%02dT%02d:%02d:%06.3fZ", t.year, t.month, t.day, t.hour, t.minute, t.second)
    }

    /// The JSON line rs41mod writes with `--json` (the form radiosonde_auto_rx reads), with `temp` when known.
    public func json() -> String {
        var text = "{ \"type\": \"RS41\", \"frame\": \(frame), \"id\": \"\(serial)\", \"datetime\": \"\(isoTime)\", "
        text += String(format: "\"lat\": %.5f, \"lon\": %.5f, \"alt\": %.5f, \"vel_h\": %.5f, \"heading\": %.5f, \"vel_v\": %.5f, ",
                       latitude, longitude, altitude, horizontalSpeed, heading, verticalSpeed)
        text += String(format: "\"sats\": %d, \"bt\": %d, \"batt\": %.2f", satellites, countdown, batteryVolts)
        if let temperature { text += String(format: ", \"temp\": %.1f", temperature) }
        text += ", \"subtype\": \"\(subtype)\""
        if let frequencyKHz { text += ", \"tx_frequency\": \(frequencyKHz)" }
        return text + ", \"ref_datetime\": \"GPS\", \"ref_position\": \"GPS\" }"
    }

    /// A one-line summary like rs41mod's.
    public var line: String {
        let t = dateTime
        var text = String(format: "[%5d] (%@)  %04d-%02d-%02d %02d:%02d:%06.3f  lat: %.5f  lon: %.5f  alt: %.2f  vH: %.1f  D: %.1f  vV: %.1f",
                          frame, serial, t.year, t.month, t.day, t.hour, t.minute, t.second,
                          latitude, longitude, altitude, horizontalSpeed, heading, verticalSpeed)
        if let temperature { text += String(format: "  T=%.1fC", temperature) }
        return text
    }
}

/// Turns RS41 frames into reports, keeping each sonde's calibration table as its pieces arrive.
public final class RS41Decoder {
    /// The calibration table: 51 pieces of 16 bytes, one sent with every frame.
    final class Calibration {
        var bytes = [UInt8](repeating: 0, count: 51 * 16)
        var have = [Bool](repeating: false, count: 51)
        var countdown = 0xffff

        func float(_ offset: Int) -> Float {
            Float(bitPattern: UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24)
        }
        func has(_ pieces: Int...) -> Bool { pieces.allSatisfy { have[$0] } }
    }

    private var calibrations: [String: Calibration] = [:]

    public init() {}

    /// The report a frame gives, if its status, time and position blocks are intact.
    public func report(_ frame: RS41Frame) -> RS41Report? {
        guard let number = frame.frameNumber, let serial = frame.serial, let time = frame.gpsTime, let fix = frame.ecef else {
            return nil
        }
        let calibration = calibrations[serial] ?? Calibration()
        calibrations[serial] = calibration
        if let piece = frame.calibration, piece.index < 51 {
            // Piece 0x32 changes (it carries the countdown); the others are constant.
            for (offset, byte) in piece.bytes.enumerated() { calibration.bytes[piece.index * 16 + offset] = byte }
            calibration.have[piece.index] = true
            if piece.index == 0x32 { calibration.countdown = Int(piece.bytes[0]) | Int(piece.bytes[1]) << 8 }
        }

        let (latitude, longitude, altitude) = Self.geodetic(fix.position)
        let (east, north, up) = Self.enu(fix.velocity, latitude: latitude, longitude: longitude)
        var heading = atan2(east, north) * 180 / .pi
        if heading < 0 { heading += 360 }
        return RS41Report(
            frame: number, serial: serial, gpsWeek: time.week, gpsMilliseconds: time.milliseconds,
            latitude: latitude, longitude: longitude, altitude: altitude,
            horizontalSpeed: (east * east + north * north).squareRoot(), heading: heading, verticalSpeed: up,
            satellites: fix.satellites, batteryVolts: frame.batteryVolts ?? 0,
            temperature: frame.measurements.flatMap { Self.temperature($0, calibration) },
            subtype: Self.subtype(calibration), frequencyKHz: Self.frequency(calibration),
            countdown: calibration.countdown, calibrationPieces: calibration.have.filter { $0 }.count)
    }

    /// Temperature from the main sensor's count and its two reference counts. The counts are linear in resistance,
    /// so the references (resistors of known value from the table) give gain and offset; the sensor's resistance,
    /// scaled by a per-sonde factor, goes through a quadratic, then an additive and a relative correction.
    static func temperature(_ counts: [Int], _ table: Calibration) -> Double? {
        guard table.has(3, 4, 5, 6), counts[2] != counts[1] else { return nil }
        let r1 = table.float(61), r2 = table.float(65)
        let a = (table.float(77), table.float(81), table.float(85))
        let correction = (table.float(89), table.float(93), table.float(97))
        let f = Float(counts[0]), f1 = Float(counts[1]), f2 = Float(counts[2])
        let countsPerOhm = (f2 - f1) / (r2 - r1)
        let offsetOhms = (f1 * r2 - f2 * r1) / (f2 - f1)
        let resistance = (f / countsPerOhm - offsetOhms) * correction.0
        let celsius = (a.0 + resistance * (a.1 + resistance * a.2) + correction.1) * (1 + correction.2)
        return celsius.isFinite && celsius > -120 && celsius < 80 ? Double(celsius) : nil
    }

    /// The model string: the last 8 bytes of piece 0x21 and the first of 0x22 ("RS41-SG", "RS41-SGP", "RS41-SGPE" …).
    static func subtype(_ table: Calibration) -> String {
        guard table.has(0x21, 0x22) else { return "RS41" }
        let bytes = table.bytes[(0x21 * 16 + 8)..<(0x21 * 16 + 16)] + [table.bytes[0x22 * 16]]
        let text = bytes.prefix { $0 != 0 }.filter { $0 >= 0x20 && $0 < 0x7f }
        return text.isEmpty ? "RS41" : String(decoding: text, as: UTF8.self)
    }

    /// The transmit frequency in piece 0: 400 MHz plus 40 kHz steps, and quarter steps in the top bits of the byte
    /// before.
    static func frequency(_ table: Calibration) -> Int? {
        guard table.has(0) else { return nil }
        return 400_000 + 40 * Int(table.bytes[3]) + 10 * Int(table.bytes[2] >> 6)
    }

    /// WGS84 latitude and longitude (degrees) and ellipsoidal height (metres) from ECEF metres, by Bowring's method.
    static func geodetic(_ p: (Double, Double, Double)) -> (Double, Double, Double) {
        let a = 6_378_137.0, b = 6_356_752.314_245_18
        let e2 = (a * a - b * b) / (a * a), ep2 = (a * a - b * b) / (b * b)
        let (x, y, z) = p
        let horizontal = (x * x + y * y).squareRoot()
        let theta = atan2(z * a, horizontal * b)
        let latitude = atan2(z + ep2 * b * pow(sin(theta), 3), horizontal - e2 * a * pow(cos(theta), 3))
        let n = a / (1 - e2 * sin(latitude) * sin(latitude)).squareRoot()
        return (latitude * 180 / .pi, atan2(y, x) * 180 / .pi, horizontal / cos(latitude) - n)
    }

    /// ECEF velocity to east, north, up at a place.
    static func enu(_ v: (Double, Double, Double), latitude: Double, longitude: Double) -> (Double, Double, Double) {
        let phi = latitude * .pi / 180, lambda = longitude * .pi / 180
        let (x, y, z) = v
        let east = -sin(lambda) * x + cos(lambda) * y
        let north = -sin(phi) * cos(lambda) * x - sin(phi) * sin(lambda) * y + cos(phi) * z
        let up = cos(phi) * cos(lambda) * x + cos(phi) * sin(lambda) * y + sin(phi) * z
        return (east, north, up)
    }
}
