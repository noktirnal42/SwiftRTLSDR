// SPDX-License-Identifier: GPL-2.0-or-later
//
// What a DFM frame says, in the units people use. The packet layout, the serial number channels and the temperature
// model follow rs1729's dfm09mod (GPL-3.0, read for these facts only; no code taken). The thermistor curve is a
// least-squares fit of the datasheet table. Written for this package. See PROVENANCE.md.
import Foundation

/// One position report from a DFM radiosonde.
public struct DFMReport: Sendable {
    /// The sonde's frame counter, one a second (wraps at 256).
    public var frameCounter: Int
    /// Seconds from 1980-01-06 to the time the sonde gives (UTC, leap seconds not applied): the number rs41mod-style
    /// JSON uses as the frame number.
    public var gpsSeconds: Int
    /// The serial number, once its channel has come round (6 hex digits on a DFM-06, a number on the others).
    public var serial: String?
    /// The serial channel's number: 6 for a DFM-06, 0xA..0xD for the later ones, 0 until known.
    public var typeCode: Int
    /// "DFM06", "DFM09", "DFM09P", "DFM17", "DFM17P", "PS15", "DFMxX" once the type is known.
    public var model: String
    public var year: Int, month: Int, day: Int, hour: Int, minute: Int
    public var second: Double
    public var latitude: Double
    public var longitude: Double
    /// Height above the WGS84 ellipsoid (the GPS modes) or above sea level (the other modes), metres.
    public var altitude: Double
    public var horizontalSpeed: Double
    /// Direction of travel, degrees from north.
    public var heading: Double
    public var verticalSpeed: Double
    public var satellites: Int
    public var batteryVolts: Double?
    /// °C, once the six to nine measurement channels it needs have come round.
    public var temperature: Double?
    /// Mean sea level minus the ellipsoid height, metres, in the GPS mode.
    public var geoidHeight: Double?
    /// 2 (ellipsoid heights), 3 (two positions) or 4 (extra data).
    public var positionMode: Int
    /// The extra data bytes some payloads send (an ozonesonde's, for example), in mode 4.
    public var aux: [UInt8]?

    public var isoTime: String {
        String(format: "%04d-%02d-%02dT%02d:%02d:%06.3fZ", year, month, day, hour, minute, second)
    }

    /// The JSON line dfm09mod writes with `--json` (the form radiosonde_auto_rx reads).
    public func json(frequencyKHz: Int? = nil) -> String {
        var text = "{ \"type\": \"DFM\", \"frame\": \(gpsSeconds), \"id\": \"DFM-\(serial ?? "xxxxxxxx")\", \"datetime\": \"\(isoTime)\", "
        text += String(format: "\"lat\": %.5f, \"lon\": %.5f, \"alt\": %.5f, \"vel_h\": %.5f, \"heading\": %.5f, \"vel_v\": %.5f, ",
                       latitude, longitude, altitude, horizontalSpeed, heading, verticalSpeed)
        text += "\"sats\": \(satellites)"
        if let batteryVolts { text += String(format: ", \"batt\": %.2f", batteryVolts) }
        if let temperature { text += String(format: ", \"temp\": %.1f", temperature) }
        if let aux { text += ", \"aux\": \"" + aux.map { String(format: "%02X", $0) }.joined() + "\"" }
        if typeCode > 0 {
            text += String(format: ", \"subtype\": \"0x%X", typeCode)
            if !model.isEmpty { text += ":" + model }
            text += "\""
        }
        if let frequencyKHz { text += ", \"freq\": \(frequencyKHz)" }
        text += ", \"ref_datetime\": \"UTC\""
        if let geoidHeight {
            text += ", \"ref_position\": \"GPS\""
            text += String(format: ", \"diff_GPS_MSL\": %.2f", -geoidHeight)
        } else {
            text += ", \"ref_position\": \"MSL\""
        }
        return text + " }"
    }

    /// A one-line summary like dfm09mod's.
    public var line: String {
        var text = String(format: "[%3d] %04d-%02d-%02d %02d:%02d:%04.1f  lat: %.5f  lon: %.5f  alt: %.1f  vH: %5.2f  D: %5.1f  vV: %5.2f",
                          frameCounter, year, month, day, hour, minute, second, latitude, longitude, altitude,
                          horizontalSpeed, heading, verticalSpeed)
        if let temperature { text += String(format: "  T=%.1fC", temperature) }
        if let serial { text += "  (DFM-\(serial)" + (model.isEmpty ? ")" : ":\(model))") }
        return text
    }
}

/// Turns DFM frames into reports, keeping what the configuration channels say (serial number, sensor values) as
/// they come round.
///
/// Nine data packets (numbered 0 to 8) make a second of data and arrive two a frame; packet 8 closes a second. A
/// report is made when 0, 1, 2, 3, 4 and 8 have all arrived within six frames of 8 without a codeword beyond repair.
/// Two further checks stand in for the CRC the frames lack: the frame counter must stay in step with the time (the
/// counter minus the seconds, modulo 256, is constant within a flight), and the numbers must be plausible.
public final class DFMDecoder {
    // Configuration channels.
    private var nullChannel = 0               // the first byte of the last channel whose value was all zero
    private var maxChannel = 0
    private var serialChannel = 0
    private var halves = [0, 0]
    private var halvesSeen = 0
    private var lastSerial = 0
    private var shortSerial = 0
    private var serialNumber = 0
    private var sondeType = 0                 // the serial channel's number once the serial is confirmed
    private var sensorChannels = 0            // 6 on a DFM-06, the serial channel's number on the later ones: how many measurement channels to expect
    private var serialText: String?
    private var measurementKnown = [Bool](repeating: false, count: 9)
    private var measurements = [Double](repeating: 0, count: 9)
    private var measurementsComplete = false
    private var sensorIsPressure = false
    private var referenceOhms = 220e3
    private var battery = 0.0

    // Data packets: when each last arrived (frame count and a running number, nil if not yet), and what they said.
    private var arrived = [Double?](repeating: nil, count: 9)
    private var arrivedNumber = [Int?](repeating: nil, count: 9)
    private var packetsSeen = 0
    private var previousClose: Int?                // the number of the last packet 8 (the one that closed the second before)
    private var mode = -1
    private var counter = 0
    private var seconds = 0.0
    private var satelliteMask = 0
    private var satelliteCount = 0
    private var latitude = 0.0, longitude = 0.0, altitude = 0.0
    private var horizontalSpeed = 0.0, heading = 0.0, verticalSpeed = 0.0
    private var geoid = 0.0
    private var year = 0, month = 0, day = 0, hour = 0, minute = 0
    private var aux = [UInt8](repeating: 0, count: 26)

    // Counter against time.
    private var counterOffset: Int?
    private var pendingOffset: Int?

    public init() {}

    /// The report this frame completes, if it does. `frameCount` counts frames (it may be fractional, and gaps are
    /// fine); it dates the packets.
    public func ingest(_ frame: DFMFrame, frameCount: Double) -> DFMReport? {
        if frame.config.isIntact { configuration(frame.config) }
        var report: DFMReport?
        for block in frame.data where block.isIntact && block.corrected <= 4 {
            if let made = data(block, frameCount: frameCount) { report = made }
        }
        return report
    }

    // MARK: Configuration channels

    private func configuration(_ block: DFMFrame.Block) {
        let bits = block.bits
        let id = bits.field(0, 4), value = bits.field(4, 24), first = bits.field(0, 8)
        let second = bits.field(4, 4)
        let clean = block.corrected == 0

        if id > 4 && value & 0xfffff == 0 { nullChannel = first }
        let isDFM06 = (nullChannel & 0xf0) == 0x50 && (nullChannel & 0x0f) != 0
        if isDFM06 { sensorChannels = 6 }
        if isDFM06 && sondeType > 6 {
            sondeType = 0
            maxChannel = id
            resetMeasurements()
        }
        if id > 5 && id > maxChannel && clean && second == 0xc { maxChannel = id }

        // The serial number channel is the last one: the one after the all-zero channel, or the highest seen.
        if id > 5 && (id == (nullChannel >> 4) + 1 || id == maxChannel) {
            if (nullChannel & 0x58) == 0x58 {
                // DFM-06: the serial is the channel's six hexadecimal digits, which must come round twice alike.
                if value == shortSerial && value != 0 {
                    sondeType = id
                    sensorChannels = 6
                    serialText = String(format: "%06X", value)
                } else {
                    sondeType = 0
                    resetMeasurements()
                }
                shortSerial = value
            } else if second == 0xc || second == 0x0 {
                // 0xsCaaaab: the serial in two 16-bit halves, the last digit saying which.
                let payload = value & 0xfffff, half = payload & 0xf
                if half < 2 {
                    if serialChannel != id {
                        halves = [0, 0]
                        halvesSeen = 0
                        resetMeasurements()
                    }
                    serialChannel = id
                    halves[half] = (payload >> 4) & 0xffff
                    halvesSeen |= 1 << half
                    if halvesSeen == 3 {
                        let number = halves[0] << 16 | halves[1]
                        if number == lastSerial || lastSerial == 0 {
                            sondeType = id
                            serialNumber = number
                            sensorChannels = (0xa...0xd).contains(id) ? id : 0
                            if shortSerial == 0 || sondeType >= 0xa { serialText = String(number) }
                        } else {
                            sondeType = 0
                            resetMeasurements()
                        }
                        lastSerial = number
                        halvesSeen = 0
                    }
                }
            }
        }

        // The measurement channels, 24-bit floats; the sensor values need all of the ones the model sends.
        if id <= 8 && clean {
            measurementKnown[id] = true
            measurements[id] = Self.float24(value)
            var complete = sensorChannels >= 5
            if sensorChannels >= 5 { for k in 0..<6 where !measurementKnown[k] { complete = false } }
            if sensorChannels >= 7 { for k in 6..<8 where !measurementKnown[k] { complete = false } }
            if sensorChannels >= 8 { if !measurementKnown[8] { complete = false } }
            measurementsComplete = complete
        }

        referenceOhms = 220e3
        sensorIsPressure = false
        guard measurementsComplete else { return }
        // The first sensor of a pressure-sensing model (09P, 17P) sits in channels 1, 5 and 6 instead of 0, 3 and 4.
        if sensorChannels >= 0xd || (sensorChannels >= 0xc && measurements[6] < 220e3) { sensorIsPressure = true }
        if ((sensorChannels == 0xb || sensorChannels == 0xc) && !sensorIsPressure) || sensorChannels >= 0xd { referenceOhms = 332e3 }
        if sensorChannels == 0xa && !sensorIsPressure && isDFM17ByNumber { referenceOhms = 332e3 }
        if sensorChannels == 6 && sondeType == 8 { sensorIsPressure = true }
        if sensorChannels >= 0xa {
            // The battery voltage is in the 16 bits after the id's nibble and the next one, in channel 5 (7 with pressure).
            if id == (sensorIsPressure ? 7 : 5) { battery = Double((value >> 4) & 0xffff) / 1000 }
        } else {
            battery = 0
        }
    }

    /// A DFM-17 with serial channel 0xA is told from a DFM-09 by its serial number (23000000 and up).
    private var isDFM17ByNumber: Bool { serialNumber >= 23_000_000 }

    private func resetMeasurements() {
        measurementKnown = [Bool](repeating: false, count: 9)
        measurementsComplete = false
        sensorChannels = 0
        serialText = nil
    }

    /// A 24-bit float: a 4-bit exponent over a 20-bit mantissa, the value being mantissa / 2^exponent.
    static func float24(_ value: Int) -> Double {
        Double(value & 0xfffff) / Double(1 << ((value >> 20) & 0xf))
    }

    /// Model name from the serial channel's number.
    private var modelName: String {
        switch sondeType {
        case 0: return ""
        case 6: return "DFM06"
        case 7, 8: return shortSerial != 0 ? "DFM06P" : "PS15"
        case 0xa: return isDFM17ByNumber ? "DFM17" : "DFM09"
        case 0xb: return "DFM17"
        case 0xc: return sensorIsPressure ? "DFM09P" : "DFM17"
        case 0xd: return "DFM17P"
        default: return "DFMxX"
        }
    }

    // NTC thermistor EPCOS B57540G0502 (5 kΩ at 25 °C): 1/T = p0 + p1 ln R + p2 ln² R + p3 ln³ R, R in ohms, T in
    // kelvin, a least-squares fit of the datasheet's R/T table for -55...+40 °C (about 0.002 K from the table).
    private static let steinhartHart = (1.09698417e-03, 2.39564629e-04, 2.48821437e-06, 5.84354921e-08)

    /// The temperature from the main sensor's count and the two reference counts: the references (resistors of known
    /// value) give the gain, the thermistor's resistance follows.
    private var temperature: Double? {
        guard measurementsComplete, sensorChannels != 0 else { return nil }
        let (f, f1, f2): (Double, Double, Double) = sensorIsPressure
            ? (measurements[1], measurements[5], measurements[6]) : (measurements[0], measurements[3], measurements[4])
        guard f * f1 * f2 != 0 else { return nil }
        let gain = f2 / referenceOhms
        let ohms = (f - f1) / gain
        guard ohms > 0 else { return nil }
        let l = log(ohms)
        let (p0, p1, p2, p3) = Self.steinhartHart
        let kelvin = 1 / (p0 + l * (p1 + l * (p2 + l * p3)))
        let celsius = kelvin - 273.15
        return celsius > -270 ? celsius : nil
    }

    // MARK: Data packets

    private func data(_ block: DFMFrame.Block, frameCount: Double) -> DFMReport? {
        let bits = block.bits
        let id = bits.field(48, 4)
        guard id <= 8 else { return nil }
        arrived[id] = frameCount
        packetsSeen += 1
        arrivedNumber[id] = packetsSeen
        if id == 0 {
            let m = bits.field(16, 8)
            mode = m > 1 && m < 5 ? m : -1
            counter = bits.field(24, 8)
        }
        if mode <= 2 {
            switch id {
            case 1:
                satelliteMask = bits.field(0, 32)
                seconds = Double(bits.field(32, 16)) / 1000
            case 2:
                latitude = Double(bits.signed(0, 32)) / 1e7
                horizontalSpeed = Double(bits.signed(32, 16)) / 100
            case 3:
                longitude = Double(bits.signed(0, 32)) / 1e7
                heading = Double(bits.field(32, 16)) / 100
            case 4:
                altitude = Double(bits.signed(0, 32)) / 100
                verticalSpeed = Double(bits.signed(32, 16)) / 100
            case 5:
                geoid = Double(bits.signed(0, 16)) / 100
            default: break
            }
        } else {
            switch id {
            case 0:
                seconds = Double(bits.field(0, 16)) / 1000
                horizontalSpeed = Double(bits.signed(32, 16)) / 100
            case 1:
                latitude = Double(bits.signed(0, 32)) / 1e7
                heading = Double(bits.field(32, 16)) / 100
            case 2:
                longitude = Double(bits.signed(0, 32)) / 1e7
                verticalSpeed = Double(bits.signed(32, 16)) / 100
            case 3:
                altitude = Double(bits.signed(0, 32)) / 100
                if mode == 4 { for j in 0..<2 { aux[j] = UInt8(bits.field(32 + 8 * j, 8)) } }
            case 4...7 where mode == 4:
                for j in 0..<6 { aux[2 + 6 * (id - 4) + j] = UInt8(bits.field(8 * j, 8)) }
            default: break
            }
        }
        guard id == 8 else { return nil }
        year = bits.field(0, 12)
        month = bits.field(12, 4)
        day = bits.field(16, 5)
        hour = bits.field(21, 5)
        minute = bits.field(26, 6)
        let satellitesInSolution = bits.field(32, 8)
        defer { previousClose = arrivedNumber[8] }               // whether or not this second made a report
        return makeReport(satellites: satellitesInSolution, frameCount: frameCount)
    }

    private func makeReport(satellites: Int, frameCount: Double) -> DFMReport? {
        // Packets 0 to 4 and 8 of this second, close together and in the order they are sent: one lost packet must not
        // be made up with the same one from the second before.
        var last = previousClose ?? 0
        for id in [0, 1, 2, 3, 4, 8] {
            guard let at = arrived[id], frameCount - at < 6, let number = arrivedNumber[id], number > last else { return nil }
            last = number
        }
        guard seconds < 60, (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, year >= 2000,
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        let days = GPSTime.daysSince1980(year: year, month: month, day: day)
        let gpsSeconds = days * 86_400 + hour * 3600 + minute * 60 + Int(seconds + 0.5)
        // The counter minus the time's seconds (mod 256) stays put; two reports in a row that disagree with the
        // reference mean it has moved (or the first one was wrong).
        let offset = ((gpsSeconds & 0xff) - counter) & 0xff
        if let reference = counterOffset, offset != reference {
            guard pendingOffset == offset else { pendingOffset = offset; return nil }
            counterOffset = offset
        }
        if counterOffset == nil { counterOffset = offset }
        pendingOffset = nil

        let inSolution = satellites > 0 ? satellites : satelliteMask.nonzeroBitCount
        let ptu = temperature
        var extra: [UInt8]?
        if mode == 4, aux[0] != 0, (3...7).allSatisfy({ id in arrived[id].map { frameCount - $0 < 6 } ?? false }) { extra = aux }
        return DFMReport(
            frameCounter: counter, gpsSeconds: gpsSeconds, serial: serialText, typeCode: sondeType, model: modelName,
            year: year, month: month, day: day, hour: hour, minute: minute, second: seconds,
            latitude: latitude, longitude: longitude, altitude: altitude, horizontalSpeed: horizontalSpeed,
            heading: heading, verticalSpeed: verticalSpeed, satellites: inSolution,
            batteryVolts: sensorChannels >= 0xa && battery > 0 ? battery : nil,
            temperature: ptu, geoidHeight: mode <= 2 ? geoid : nil, positionMode: mode <= 2 ? 2 : mode, aux: extra)
    }
}
