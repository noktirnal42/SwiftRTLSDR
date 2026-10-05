// SPDX-License-Identifier: GPL-2.0-or-later
//
// Oregon Scientific protocols v2.1 and v3, ported from rtl_433's oregon_scientific.c (Helge Weissig, Denis Bodor,
// Tommy Vestermark, Karl Lattimer, deennoo, pclov3r, onlinux, Pasquale Fiorillo; GPL-2.0-or-later, release 25.02).
// The protocol itself is described in "Oregon Scientific RF Protocols" (wmrx00.sourceforge.net). The OWL CM160/
// CM180 energy monitors that share v3 are not ported. See PROVENANCE.md.
import Foundation

/// Oregon Scientific weather sensors: Manchester-coded, nibbles sent LSB first, a sum-of-nibbles checksum.
public struct OregonScientific: ISMDevice {
    public let name = "Oregon Scientific Weather Sensor"
    public let protocolNumber = 12
    public let modulation = ISMModulation.ookManchesterZeroBit
    public let timing = ISMTiming(short: 440, long: 0, reset: 2400)   // nominally 1024 Hz; pulses are shorter than pauses
    public init() {}

    private enum ID {
        static let thgr122n = 0x1d20, thgr968 = 0x1d30, bthr918 = 0x5d50, bhtr968 = 0x5d60, rgr968 = 0x2d10
        static let thr228n = 0xec40, thn132n = 0xec40, awr129 = 0xec41, rtgn318 = 0x0cc3, rtgn129 = 0x0cc3
        static let thgr810 = 0xf824, thgr810a = 0xf8b4, thn802 = 0xc844, pcr800 = 0x2914, pcr800a = 0x2d14
        static let wgr800 = 0x1984, wgr800a = 0x1994, wgr968 = 0x3d00, uv800 = 0xd874, thn129 = 0xcc43
        static let rthn129 = 0x0cd3, bthgn129 = 0x5d53, uvr128 = 0xec70, thgr328n = 0xcc23
        static let rtgr328nTemperature = [0xdcc3, 0xccc3, 0xbcc3, 0xacc3, 0x9cc3]
        static let rtgr328nClock = [0x8ce3, 0x8ae3]
    }

    public func decode(_ bits: inout BitBuffer, into reports: inout [ISMReport]) -> Int {
        let result = decodeV21(bits, into: &reports)
        return result > 0 ? result : decodeV3(bits, into: &reports)
    }

    // MARK: Readings (nibbles are BCD, least significant first)

    private static func temperature(_ msg: [UInt8]) -> Float {
        var celsius = Float(Int(msg[5] >> 4) * 100 + Int(msg[4] & 0x0f) * 10 + Int((msg[4] >> 4) & 0x0f)) / 10.0
        celsius += Float(msg[5] & 0x07) * 100.0                // the AWR129 BBQ thermometer's hundreds digit
        if msg[5] & 0x08 != 0 { celsius = -celsius }
        return celsius
    }

    private static func humidity(_ msg: [UInt8]) -> Int { Int(msg[6] & 0x0f) * 10 + Int(msg[6] >> 4) }
    private static func uv(_ msg: [UInt8]) -> Int { Int(msg[4] & 0x0f) * 10 + Int(msg[4] >> 4) }

    private static func rainRate(_ msg: [UInt8]) -> Float {
        Float(Int(msg[5] & 0x0f) * 1000 + Int(msg[5] >> 4) * 100 + Int(msg[4] & 0x0f) * 10 + Int(msg[4] >> 4)) / 100.0
    }

    private static func totalRain(_ msg: [UInt8]) -> Float {
        var total = Float(msg[8] & 0x0f) * 100.0
        total += Float((msg[8] >> 4) & 0x0f) * 10.0
        total += Float(msg[7] & 0x0f)
        total += Float((msg[7] >> 4) & 0x0f) / 10.0
        total += Float(msg[6] & 0x0f) / 100.0
        total += Float((msg[6] >> 4) & 0x0f) / 1000.0
        return total
    }

    /// The v2.1/v3 checksum: the sum of the nibbles before `nibble`, compared with the byte there (nibbles swapped).
    static func checksumIsValid(_ msg: [UInt8], nibble: Int) -> Bool {
        var sum = 0
        var index = 0
        while index < nibble - 1 {
            sum += Int(msg[index >> 1] >> 4) + Int(msg[index >> 1] & 0x0f)
            index += 2
        }
        let checksum: Int
        if nibble & 1 != 0 {
            sum += Int(msg[nibble >> 1] >> 4)
            checksum = Int(msg[nibble >> 1] & 0x0f) | Int(msg[(nibble + 1) >> 1] & 0xf0)
        } else {
            checksum = Int(msg[nibble >> 1] >> 4) | Int(msg[nibble >> 1] & 0x0f) << 4
        }
        return sum & 0xff == checksum
    }

    // MARK: v2.1: every bit sent twice (inverted), a 0x55/0xaa preamble, then sync nibble 0x99 (0xa after Manchester)

    private func decodeV21(_ bits: BitBuffer, into reports: inout [ISMReport]) -> Int {
        let b = bits.row(0)
        if (b[1] != 0x55 || b[2] != 0x55) && (b[1] != 0xaa || b[2] != 0xaa) { return DecodeStatus.abortEarly }

        var data = BitBuffer()
        let syncTest = UInt32(b[3]) << 24 | UInt32(b[4]) << 16 | UInt32(b[5]) << 8 | UInt32(b[6])
        for patternIndex in 0..<8 {
            // Allow for bits gained or lost in the preamble: look for the sync a few bits either way.
            let mask = UInt32(0xffff_0000) >> UInt32(patternIndex)
            let pattern = UInt32(0x5599_0000) >> UInt32(patternIndex)
            let pattern2 = UInt32(0xaa99_0000) >> UInt32(patternIndex)
            if syncTest & mask != pattern && syncTest & mask != pattern2 { continue }
            bits.manchesterDecode(row: 0, from: patternIndex + 40, into: &data, maximum: 173)
            break
        }
        let messageBits = data.bitsPerRow[0]
        var msg = data.row(0).bytes(BitBuffer.rowBytes)
        BitUtil.reflectNibbles(&msg, count: (messageBits + 7) / 8)

        let sensorID = Int(msg[0]) << 8 | Int(msg[1])
        let channel = Int((msg[2] >> 4) & 0x0f)
        let deviceID = Int(msg[2] & 0x0f) | Int(msg[3] & 0xf0)
        let battery: ISMReport.Value = .int((msg[3] >> 2) & 1 != 0 ? 0 : 1)
        func valid(_ expectedBits: Int, _ nibble: Int) -> Bool {
            expectedBits == messageBits && Self.checksumIsValid(msg, nibble: nibble)
        }
        func report(_ model: String, _ extra: KeyValuePairs<String, ISMReport.Value?>) -> Int {
            var fields = ISMReport(["model": .string(model), "id": .int(deviceID), "channel": .int(channel), "battery_ok": battery])
            for (key, value) in extra { if let value { fields.append(key, value) } }
            reports.append(fields)
            return 1
        }

        if sensorID == ID.thgr122n || sensorID == ID.thgr968 {
            guard valid(76, 15) else { return 0 }
            return report(sensorID == ID.thgr122n ? "Oregon-THGR122N" : "Oregon-THGR968",
                          ["temperature_C": .float(Self.temperature(msg)), "humidity": .int(Self.humidity(msg))])
        } else if sensorID == ID.wgr968 {
            guard valid(94, 17) else { return 0 }
            let direction = Float(Int(msg[4] & 0x0f) * 10 + Int((msg[4] >> 4) & 0x0f) * 1 + Int((msg[5] >> 4) & 0x0f) * 100)
            var average = Float((msg[7] >> 4) & 0x0f) / 10.0
            average += Float(msg[7] & 0x0f) * 1.0
            average += Float((msg[8] >> 4) & 0x0f) / 10.0
            var gust = Float(msg[5] & 0x0f) / 10.0
            gust += Float((msg[6] >> 4) & 0x0f) * 1.0
            gust += Float(msg[6] & 0x0f) / 10.0
            return report("Oregon-WGR968", ["wind_max_m_s": .float(gust), "wind_avg_m_s": .float(average), "wind_dir_deg": .float(direction)])
        } else if sensorID == ID.bhtr968 {
            guard valid(92, 19) else { return 0 }
            let pressure = Float(Int(msg[7] & 0x0f) | Int(msg[8] & 0xf0)) + 856
            return report("Oregon-BHTR968", ["temperature_C": .float(Self.temperature(msg)), "humidity": .int(Self.humidity(msg)),
                                             "pressure_hPa": .float(pressure)])
        } else if sensorID == ID.bthr918 {
            guard valid(84, 19) else { return 0 }
            let pressure = Float(Int(msg[7] & 0x0f) | Int(msg[8] & 0xf0)) + 795
            return report("Oregon-BTHR918", ["temperature_C": .float(Self.temperature(msg)), "humidity": .int(Self.humidity(msg)),
                                             "pressure_hPa": .float(pressure)])
        } else if sensorID == ID.rgr968 {
            guard valid(80, 16) else { return 0 }
            let rate = Float(Int(msg[4] & 0x0f) * 100 + Int(msg[4] >> 4) * 10 + Int((msg[5] >> 4) & 0x0f)) / 10.0
            let total = Float(Int(msg[7] & 0xf) * 10000 + Int(msg[7] >> 4) * 1000 + Int(msg[6] & 0xf) * 100
                              + Int(msg[6] >> 4) * 10 + Int(msg[5] & 0xf)) / 10.0
            return report("Oregon-RGR968", ["rain_rate_mm_h": .float(rate), "rain_mm": .float(total)])
        } else if (sensorID == ID.thr228n || sensorID == ID.awr129) && messageBits == 76 {
            guard valid(76, 12) else { return 0 }
            return report(sensorID == ID.thr228n ? "Oregon-THR228N" : "Oregon-AWR129", ["temperature_C": .float(Self.temperature(msg))])
        } else if sensorID == ID.thn132n && messageBits == 64 {
            guard valid(64, 12) else { return 0 }
            if (msg[5] >> 4) & 0x0f > 9 || msg[4] & 0x0f > 9 || (msg[4] >> 4) & 0x0f > 9 { return DecodeStatus.failSanity }
            let celsius = Self.temperature(msg)
            if celsius > 70 || celsius < -50 { return DecodeStatus.failSanity }
            return report("Oregon-THN132N", ["temperature_C": .float(celsius)])
        } else if sensorID & 0x0fff == ID.rtgn129 && messageBits == 80 {
            guard valid(80, 15) else { return 0 }
            return report("Oregon-RTGN129", ["temperature_C": .float(Self.temperature(msg)), "humidity": .int(Self.humidity(msg))])
        } else if ID.rtgr328nTemperature.contains(sensorID) && messageBits == 173 {
            guard valid(173, 15) else { return 0 }
            return report("Oregon-RTGR328N", ["temperature_C": .float(Self.temperature(msg)), "humidity": .int(Self.humidity(msg))])
        } else if ID.rtgr328nClock.contains(sensorID) {
            guard valid(100, 21) else { return 0 }
            func bcd(_ byte: UInt8) -> Int { Int(byte & 0x0f) * 10 + Int((byte & 0xf0) >> 4) }
            let clock = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", bcd(msg[9]) + 2000, Int((msg[8] & 0xf0) >> 4),
                               bcd(msg[7]), bcd(msg[6]), bcd(msg[5]), bcd(msg[4]))
            return report("Oregon-RTGR328N", ["radio_clock": .string(clock)])
        } else if sensorID & 0x0fff == ID.rtgn318 {
            if valid(76, 15) {
                return report("Oregon-RTGN318", ["temperature_C": .float(Self.temperature(msg)), "humidity": .int(Self.humidity(msg))])
            }
        } else if sensorID == ID.thn129 || sensorID & 0x0fff == ID.rthn129 {
            if valid(68, 12) {
                return report(sensorID == ID.thn129 ? "Oregon-THN129" : "Oregon-RTHN129", ["temperature_C": .float(Self.temperature(msg))])
            }
        } else if sensorID == ID.bthgn129 {
            guard valid(92, 19) else { return 0 }
            let pressure = Float((Int(msg[7] & 0x0f) | Int(msg[8] & 0xf0)) * 2 + Int(msg[8] & 0x01) + 600)
            return report("Oregon-BTHGN129", ["temperature_C": .float(Self.temperature(msg)), "humidity": .int(Self.humidity(msg)),
                                              "pressure_hPa": .float(pressure)])
        } else if sensorID == ID.uvr128 && messageBits == 148 {
            guard valid(148, 12) else { return 0 }
            if (msg[4] >> 4) & 0x0f > 9 || msg[4] & 0x0f > 9 { return DecodeStatus.failSanity }
            let index = Self.uv(msg)
            if index > 25 { return DecodeStatus.failSanity }
            reports.append(ISMReport(["model": "Oregon-UVR128", "id": .int(deviceID), "uv": .int(index), "battery_ok": battery]))
            return 1
        } else if sensorID == ID.thgr328n {
            guard valid(173, 15) else { return 0 }
            return report("Oregon-THGR328N", ["temperature_C": .float(Self.temperature(msg)), "humidity": .int(Self.humidity(msg))])
        }
        return 0
    }

    // MARK: v3: bits sent once, preamble 0x00 0x00 0x00 0x5 (shorter on the WGR800X)

    private func decodeV3(_ bits: BitBuffer, into reports: inout [ISMReport]) -> Int {
        let b = bits.row(0)
        if (b[0] & 0x0f != 0x0f || b[1] != 0xff || b[2] & 0xc0 != 0xc0) && (b[0] & 0x0f != 0x00 || b[1] != 0x00 || b[2] & 0xc0 != 0x00) {
            return DecodeStatus.abortEarly
        }
        let length = bits.bitsPerRow[0]
        let osPosition = bits.search(row: 0, from: 0, pattern: [0x00, 0x05], bits: 16) + 16
        let cm180Position = bits.search(row: 0, from: 0, pattern: [0x00, 0x46], bits: 16) + 8
        let cm180iPosition = bits.search(row: 0, from: 0, pattern: [0x00, 0x4a], bits: 16) + 8
        let altPosition = bits.search(row: 0, from: 0, pattern: [0xff, 0xf5], bits: 16) + 16   // a broken-Manchester workaround
        var position = 0, messageLength = 0
        if length - osPosition >= 56 {
            (position, messageLength) = (osPosition, length - osPosition)
        } else if length - cm180Position >= 52 {
            (position, messageLength) = (cm180Position, length - cm180Position)
        } else if length - cm180iPosition >= 84 {
            (position, messageLength) = (cm180iPosition, length - cm180iPosition)
        } else if length - altPosition >= 56 {
            (position, messageLength) = (altPosition, length - altPosition)
        }
        if messageLength == 0 || messageLength > 44 * 8 { return DecodeStatus.abortEarly }
        var msg = bits.extractBytes(row: 0, from: position, bits: messageLength)
        msg += [UInt8](repeating: 0, count: 44 - msg.count)
        BitUtil.reflectNibbles(&msg, count: (messageLength + 7) / 8)

        let sensorID = Int(msg[0]) << 8 | Int(msg[1])
        let channel = Int((msg[2] >> 4) & 0x0f)
        let deviceID = Int(msg[2] & 0x0f) | Int(msg[3] & 0xf0)
        let battery: ISMReport.Value = .int((msg[3] >> 2) & 1 != 0 ? 0 : 1)
        func report(_ model: String, _ extra: KeyValuePairs<String, ISMReport.Value?>) -> Int {
            var fields = ISMReport(["model": .string(model), "id": .int(deviceID), "channel": .int(channel), "battery_ok": battery])
            for (key, value) in extra { if let value { fields.append(key, value) } }
            reports.append(fields)
            return 1
        }

        if sensorID == ID.thgr810 || sensorID == ID.thgr810a {
            guard Self.checksumIsValid(msg, nibble: 15) else { return DecodeStatus.failMIC }
            if (msg[5] >> 4) & 0x0f > 9 || msg[4] & 0x0f > 9 || (msg[4] >> 4) & 0x0f > 9 || msg[6] & 0x0f > 9 || (msg[6] >> 4) & 0x0f > 9 {
                return DecodeStatus.failSanity
            }
            let celsius = Self.temperature(msg)
            if celsius > 70 || celsius < -50 { return DecodeStatus.failSanity }
            return report("Oregon-THGR810", ["temperature_C": .float(celsius), "humidity": .int(Self.humidity(msg))])
        } else if sensorID == ID.thn802 {
            guard Self.checksumIsValid(msg, nibble: 12) else { return DecodeStatus.failMIC }
            return report("Oregon-THN802", ["temperature_C": .float(Self.temperature(msg))])
        } else if sensorID == ID.uv800 {
            guard Self.checksumIsValid(msg, nibble: 13) else { return DecodeStatus.failMIC }
            return report("Oregon-UV800", ["uv": .int(Self.uv(msg))])
        } else if sensorID == ID.pcr800 {
            guard Self.checksumIsValid(msg, nibble: 18) else { return DecodeStatus.failMIC }
            for index in 4...8 where msg[index] & 0x0f > 9 || (msg[index] >> 4) & 0x0f > 9 { return DecodeStatus.failSanity }
            return report("Oregon-PCR800", ["rain_rate_in_h": .float(Self.rainRate(msg)), "rain_in": .float(Self.totalRain(msg))])
        } else if sensorID == ID.pcr800a {
            guard Self.checksumIsValid(msg, nibble: 18) else { return DecodeStatus.failMIC }
            return report("Oregon-PCR800a", ["rain_rate_in_h": .float(Self.rainRate(msg)), "rain_in": .float(Self.totalRain(msg))])
        } else if sensorID == ID.wgr800 || sensorID == ID.wgr800a {
            guard Self.checksumIsValid(msg, nibble: 17) else { return DecodeStatus.failMIC }
            if msg[5] & 0x0f > 9 || (msg[6] >> 4) & 0x0f > 9 || msg[6] & 0x0f > 9 || (msg[7] >> 4) & 0x0f > 9
                || msg[7] & 0x0f > 9 || (msg[8] >> 4) & 0x0f > 9 {
                return DecodeStatus.failSanity
            }
            var gust = Float(msg[5] & 0x0f) / 10.0
            gust += Float((msg[6] >> 4) & 0x0f) * 1.0
            gust += Float(msg[6] & 0x0f) * 10.0
            var average = Float((msg[7] >> 4) & 0x0f) / 10.0
            average += Float(msg[7] & 0x0f) * 1.0
            average += Float((msg[8] >> 4) & 0x0f) * 10.0
            let direction = Float((msg[4] >> 4) & 0x0f) * 22.5
            if gust < 0 || gust > 56 || average < 0 || average > 56 { return DecodeStatus.failSanity }
            return report("Oregon-WGR800", ["wind_max_m_s": .float(gust), "wind_avg_m_s": .float(average), "wind_dir_deg": .float(direction)])
        }
        return DecodeStatus.failSanity                          // unknown sensor, or an OWL energy monitor (not ported)
    }
}
