// SPDX-License-Identifier: GPL-2.0-or-later
//
// What an M10 or M20 frame says, in the units people use. The field positions, scales and the thermistor circuit
// follow rs1729's m10m20mod (GPL-3.0, read for these facts only; no code taken). The thermistor curve is a
// least-squares fit of the datasheet table. Written for this package. See PROVENANCE.md.
import Foundation

/// One position report from an M10 or M20.
public struct M10Report: Sendable {
    public var kind: M10Frame.Kind
    /// The sonde's frame counter, one a second (wraps at 256).
    public var counter: Int
    /// GPS seconds (leap seconds not applied) of the frame: the number the JSON uses as the frame number.
    public var gpsSeconds: Int
    /// "913-2-05678" style: the serial the way radiosonde_auto_rx shows it.
    public var serial: String
    /// The serial bytes in hexadecimal, as `rawid` carries them.
    public var rawSerial: String
    /// The date and time the JSON gives: UTC for the M10 (the sonde sends GPS time and the offset) and the M10+ (which
    /// sends UTC), GPS time for the others.
    public var year: Int, month: Int, day: Int, hour: Int, minute: Int
    public var second: Double
    public var latitude: Double
    public var longitude: Double
    /// Height above the WGS84 ellipsoid, metres.
    public var altitude: Double
    public var horizontalSpeed: Double
    /// Direction of travel, degrees from north.
    public var heading: Double
    public var verticalSpeed: Double
    /// Satellites in the solution (M10 only).
    public var satellites: Int?
    public var batteryVolts: Double
    /// °C, when the sensor's reading is plausible.
    public var temperature: Double?
    /// GPS time minus UTC, seconds (M10 only).
    public var leapSeconds: Int?
    /// The APRS-style identifier derived from the serial (M10 and M10+ only), "ME" and 7 hexadecimal digits.
    public var aprsID: String?

    /// "M10" or "M20".
    public var model: String { kind == .m20 ? "M20" : "M10" }
    public var referenceTime: String { kind == .m10 || kind == .m10Plus ? "UTC" : "GPS" }
    public var isoTime: String {
        String(format: "%04d-%02d-%02dT%02d:%02d:%06.3fZ", year, month, day, hour, minute, second)
    }

    /// The JSON line m10m20mod writes with `--json` (the form radiosonde_auto_rx reads).
    public func json(frequencyKHz: Int? = nil) -> String {
        let name = kind == .m20 ? "M20-" + serial : "M10-" + serial.replacingOccurrences(of: " ", with: "-")
        var text = "{ \"type\": \"\(model)\", \"frame\": \(gpsSeconds), \"id\": \"\(name)\", \"datetime\": \"\(isoTime)\", "
        text += String(format: "\"lat\": %.5f, \"lon\": %.5f, \"alt\": %.5f, \"vel_h\": %.5f, \"heading\": %.5f, \"vel_v\": %.5f",
                       latitude, longitude, altitude, horizontalSpeed, heading, verticalSpeed)
        if kind == .m10, let satellites { text += ", \"sats\": \(satellites)" }
        if let aprsID { text += ", \"aprsid\": \"\(aprsID)\"" }
        text += String(format: ", \"batt\": %.2f", batteryVolts)
        if let temperature { text += String(format: ", \"temp\": %.1f", temperature) }
        text += ", \"rawid\": \"\(model)_\(rawSerial)\""
        text += String(format: ", \"subtype\": \"0x%02X\"", kind.rawValue)
        if let frequencyKHz { text += ", \"freq\": \(frequencyKHz)" }
        text += ", \"ref_datetime\": \"\(referenceTime)\", \"ref_position\": \"GPS\""
        if let leapSeconds { text += ", \"gpsutc_leapsec\": \(leapSeconds)" }
        return text + " }"
    }

    /// A one-line summary like m10m20mod's.
    public var line: String {
        var text = String(format: "%04d-%02d-%02d %02d:%02d:%06.3f  lat: %.5f  lon: %.5f  alt: %.2f  vH: %4.1f  D: %5.1f  vV: %3.1f  SN: %@-%@",
                          year, month, day, hour, minute, second, latitude, longitude, altitude, horizontalSpeed, heading,
                          verticalSpeed, model, serial)
        if let temperature { text += String(format: "  T:%.1fC", temperature) }
        return text
    }
}

/// Turns M10 and M20 frames with a good checksum into reports.
public struct M10Decoder: Sendable {
    public init() {}

    /// The report a frame gives, if its checksum holds and it is a kind with a position.
    public func report(_ frame: M10Frame) -> M10Report? {
        guard frame.isValid, let kind = frame.kind, kind != .doubleFrame, frame.length > 0x24 else { return nil }
        switch kind {
        case .m20: return trimbleStyle(frame, kind: kind)
        case .m10, .m2k2: return trimbleStyle(frame, kind: kind)
        case .m10Plus: return gtop(frame)
        case .doubleFrame: return nil
        }
    }

    /// A frame with a good checksum can still be noise that happened to pass a 16-bit check; one whose position is off the
    /// globe is not a sonde. (The DFM decoder has always refused these.)
    static func isPlausible(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }

    // MARK: M10 (Trimble) and M20

    private func trimbleStyle(_ frame: M10Frame, kind: M10Frame.Kind) -> M10Report? {
        let isM20 = kind == .m20
        // GPS week and time of week.
        var week = frame.unsigned(isM20 ? 0x1a : 0x20, 2)
        if week > 4000 { return nil }
        if week < 1304 { week += 1024 }                         // the receiver's week number rolled over in 2019
        var milliseconds: Int
        if isM20 {
            milliseconds = frame.unsigned(0x0f, 3) * 1000
        } else {
            milliseconds = frame.unsigned(0x0a, 4)
        }
        let gpsSeconds = milliseconds / 1000
        let day = gpsSeconds / 86_400
        guard (0...6).contains(day) else { return nil }
        let counter = frame.byte(isM20 ? 0x15 : 0x62)
        let frameNumber = Int((Double(week) * 604_800 + Double(milliseconds) / 1000 + 0.5).rounded(.down))

        // Time to report: UTC for the M10 (GPS time less the offset it sends), GPS time otherwise.
        let utcOffset = isM20 ? 0 : frame.byte(0x1f)
        var seconds = gpsSeconds, reportWeek = week
        if kind == .m10 {
            seconds -= utcOffset
            if seconds < 0 { reportWeek -= 1; seconds += 604_800 }
        }
        let date = GPSTime.date(daysSince1980: reportWeek * 7 + seconds / 86_400)
        let ofDay = seconds % 86_400

        // Position and velocity.
        let latitude: Double, longitude: Double, altitude: Double
        if isM20 {
            latitude = Double(frame.signed(0x1c, 4)) / 1e6
            longitude = Double(frame.signed(0x20, 4)) / 1e6
            altitude = Double(frame.unsigned(0x08, 3)) / 100
        } else {
            let scale = Double(1 << 30) / 90                 // 2^32 / 360
            latitude = Double(frame.signed(0x0e, 4)) / scale
            longitude = Double(frame.signed(0x12, 4)) / scale
            altitude = Double(frame.signed(0x16, 4)) / 1000
        }
        guard Self.isPlausible(latitude: latitude, longitude: longitude) else { return nil }
        let velocityScale = isM20 ? 100.0 : 200.0
        let east = Double(frame.signed(isM20 ? 0x0b : 0x04, 2)) / velocityScale
        let north = Double(frame.signed(isM20 ? 0x0d : 0x06, 2)) / velocityScale
        let up = Double(frame.signed(isM20 ? 0x18 : 0x08, 2)) / velocityScale
        var heading = atan2(east, north) * 180 / .pi
        if heading < 0 { heading += 360 }

        let serial = isM20 ? Self.m20Serial(frame, counterDifference: (frameNumber - counter) & 0xff) : Self.m10Serial(frame)
        let rawStart = isM20 ? 0x12 : 0x5d, rawCount = isM20 ? 3 : 5
        let rawSerial = (0..<rawCount).map { String(format: "%02X", frame.byte(rawStart + $0)) }.joined()
        let aprsID = isM20 ? nil : String(format: "ME%02X%1X%02X%02X", frame.byte(0x5d + 2), frame.byte(0x5d) & 0xf,
                                          frame.byte(0x5d + 4), frame.byte(0x5d + 3))
        return M10Report(
            kind: kind, counter: counter, gpsSeconds: frameNumber, serial: serial, rawSerial: rawSerial,
            year: date.year, month: date.month, day: date.day, hour: ofDay / 3600, minute: ofDay % 3600 / 60,
            second: Double(ofDay % 60) + Double(milliseconds % 1000) / 1000,
            latitude: latitude, longitude: longitude, altitude: altitude,
            horizontalSpeed: (east * east + north * north).squareRoot(), heading: heading, verticalSpeed: up,
            satellites: isM20 ? nil : frame.byte(0x1e), batteryVolts: Self.battery(frame, isM20: isM20),
            temperature: Self.temperature(frame, isM20: isM20), leapSeconds: isM20 ? nil : utcOffset, aprsID: aprsID)
    }

    // MARK: M10+ (Gtop)

    private func gtop(_ frame: M10Frame) -> M10Report? {
        let time = frame.unsigned(0x15, 3), date = frame.unsigned(0x18, 3)
        let hour = time / 10_000, minute = time % 10_000 / 100, second = time % 100
        let day = date / 10_000, month = date % 10_000 / 100, year = 2000 + date % 100
        guard hour < 24, minute < 60, second < 61, (1...12).contains(month), (1...31).contains(day) else { return nil }
        let latitude = Double(frame.signed(0x04, 4)) / 1e6, longitude = Double(frame.signed(0x08, 4)) / 1e6
        guard Self.isPlausible(latitude: latitude, longitude: longitude) else { return nil }
        let east = Double(frame.signed(0x0f, 2)) / 100, north = Double(frame.signed(0x11, 2)) / 100
        var heading = atan2(east, north) * 180 / .pi
        if heading < 0 { heading += 360 }
        let counter = frame.byte(0x62)
        let gps = GPSTime.daysSince1980(year: year, month: month, day: day) * 86_400 + hour * 3600 + minute * 60 + second
        return M10Report(
            kind: .m10Plus, counter: counter, gpsSeconds: gps, serial: Self.m10Serial(frame),
            rawSerial: (0..<5).map { String(format: "%02X", frame.byte(0x5d + $0)) }.joined(),
            year: year, month: month, day: day, hour: hour, minute: minute, second: Double(second),
            latitude: latitude, longitude: longitude,
            altitude: Double(frame.signed(0x0c, 3)) / 100, horizontalSpeed: (east * east + north * north).squareRoot(),
            heading: heading, verticalSpeed: Double(frame.signed(0x13, 2)) / 100, satellites: nil,
            batteryVolts: Self.battery(frame, isM20: false), temperature: Self.temperature(frame, isM20: false),
            leapSeconds: 0, aprsID: String(format: "ME%02X%1X%02X%02X", frame.byte(0x5d + 2), frame.byte(0x5d) & 0xf,
                                             frame.byte(0x5d + 4), frame.byte(0x5d + 3)))
    }

    // MARK: Serial numbers

    /// M10: five bytes at 0x5D give "xyy-a-bcccc": a hexadecimal digit and two decimal digits from the third byte,
    /// the first byte's low nibble, and a digit and four decimal digits from the last two bytes.
    static func m10Serial(_ frame: M10Frame) -> String {
        let third = frame.byte(0x5d + 2)
        let word = frame.byte(0x5d + 3) | frame.byte(0x5d + 4) << 8
        return String(format: "%1X%02u-%1X-%1u%04u", (third >> 4) & 0xf, third & 0xf, frame.byte(0x5d) & 0xf, (word >> 13) & 7, word & 0x1fff)
    }

    /// M20: three bytes at 0x12 (the first the least significant) hold the month of manufacture counted from the year
    /// 0 (a number below 120), a batch digit, and a sequence number.
    static func m20Serial(_ frame: M10Frame, counterDifference: Int) -> String {
        let sn = frame.byte(0x12) | frame.byte(0x13) << 8 | frame.byte(0x14) << 16
        if sn == 0 { return String(format: "000-0-00000-%03u", counterDifference) }      // before the sonde has its serial
        let months = sn & 0x7f
        return String(format: "%u%02u-%u-%u%04u", months / 12, months % 12 + 1, ((sn >> 7) & 7) + 1, (sn >> 23) & 1, (sn >> 10) & 0x1fff)
    }

    // MARK: Sensors

    static func battery(_ frame: M10Frame, isM20: Bool) -> Double {
        if isM20 { return Double(frame.byte(0x26)) * (3.3 / 255) }
        // 10-bit ADC against 2.5 V behind a divider of about 2.709.
        let adc = frame.byte(0x45) | frame.byte(0x46) << 8
        return 2.709 * Double(adc) * 2.5 / 1023
    }

    // NTC thermistor (15 kΩ at 0 °C, 5.37 kΩ at 25 °C): 1/T = p0 + p1 ln R + p2 ln² R + p3 ln³ R, a least-squares fit of
    // the datasheet's R/T table for -50...+40 °C (within 0.006 K of it).
    private static let steinhartHart = (1.07170504e-03, 2.41723514e-04, 2.22389636e-06, 6.67047661e-08)
    /// The sensor's voltage divider has three ranges: series and parallel resistors by range.
    private static let seriesOhms = [12.1e3, 36.5e3, 475.0e3]
    private static let parallelOhms = [Double.infinity, 330.0e3, 2000.0e3]

    /// The temperature from the 12-bit reading of the divider the thermistor is in.
    static func temperature(_ frame: M10Frame, isM20: Bool) -> Double? {
        var range: Int, reading: Int
        if isM20 {
            reading = frame.byte(0x04) | frame.byte(0x05) << 8
            if reading > 8191 { range = 2; reading -= 8192 } else if reading > 4095 { range = 1; reading -= 4096 } else { range = 0 }
        } else {
            range = frame.byte(0x3e)
            reading = (frame.byte(0x3f) | frame.byte(0x40) << 8) - 0xa000
            reading &= 0xffff
        }
        guard range < 3, reading > 0 else { return nil }
        let x = (4095.0 - Double(reading)) / Double(reading)               // (Vcc - Vout) / Vout
        let ohms = seriesOhms[range] / (x - seriesOhms[range] / parallelOhms[range])
        guard ohms > 0, ohms.isFinite else { return nil }
        let l = log(ohms)
        let (p0, p1, p2, p3) = steinhartHart
        let celsius = 1 / (p0 + l * (p1 + l * (p2 + l * p3))) - 273.15
        return celsius >= -120 && celsius <= 60 ? celsius : nil
    }
}
