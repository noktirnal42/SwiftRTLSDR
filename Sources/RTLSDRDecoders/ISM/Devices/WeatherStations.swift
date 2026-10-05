// SPDX-License-Identifier: GPL-2.0-or-later
//
// Weather-station outdoor units, ported from rtl_433 release 25.02 (GPL-2.0-or-later): bresser_5in1.c,
// bresser_6in1.c, fineoffset.c (WH2, WH24/WH65B, WH25/WH32, WH0290) and the "TXR" family of acurite.c.
// Protocol descriptions, field names and checks are rtl_433's; the upstream authors are credited in NOTICE.
// See PROVENANCE.md.

/// Bresser Weather Center 5-in-1 (868.3 MHz, FSK): 26 bytes after `aa aa aa 2d d4`, the first 13 the inverse of the
/// last 13.
public struct Bresser5in1: ISMDevice {
    public let name = "Bresser Weather Center 5-in-1"
    public let protocolNumber = 119
    public let modulation = ISMModulation.fskPCM
    public let timing = ISMTiming(short: 124, long: 124, reset: 25000)
    public init() {}

    public func decode(_ bits: inout BitBuffer, into reports: inout [ISMReport]) -> Int {
        let preamble: [UInt8] = [0xaa, 0xaa, 0xaa, 0x2d, 0xd4]
        guard bits.rowCount == 1, bits.bitsPerRow[0] >= 248, bits.bitsPerRow[0] <= 440 else { return DecodeStatus.abortEarly }
        var start = bits.search(row: 0, from: 0, pattern: preamble, bits: 40)
        if start == bits.bitsPerRow[0] { return DecodeStatus.abortLength }
        start += 40
        var length = bits.bitsPerRow[0] - start
        if (length + 7) / 8 < 26 { return DecodeStatus.abortLength }
        length = min(length, 26 * 8)
        var msg = bits.extractBytes(row: 0, from: start, bits: length)
        msg += [UInt8](repeating: 0, count: max(0, 26 - msg.count))
        for column in 0..<13 where msg[column] ^ msg[column + 13] != 0xff { return DecodeStatus.failMIC }

        func bcd(_ byte: UInt8) -> Int { Int(byte & 0x0f) + Int(byte >> 4) * 10 }
        let temperatureOK = msg[20] & 0x0f <= 9
        var temperatureRaw = bcd(msg[20]) + Int(msg[21] & 0x0f) * 100
        if msg[25] & 0x0f != 0 { temperatureRaw = -temperatureRaw }
        let temperature = Float(temperatureRaw) * 0.1
        let humidityOK = msg[22] & 0x0f <= 9
        let humidity = bcd(msg[22])
        let direction = Float((msg[17] & 0xf0) >> 4) * 22.5
        let gust = Float(Int(msg[17] & 0x0f) << 8 + Int(msg[16])) * 0.1
        let average = Float(bcd(msg[18]) + Int(msg[19] & 0x0f) * 100) * 0.1
        var rain = Float(bcd(msg[23]) + bcd(msg[24]) * 100) * 0.1
        let batteryLow = msg[25] & 0x80 != 0
        let sensorType = msg[15] & 0x7f
        let id = Int(msg[14])

        if sensorType >= 0x39 && sensorType <= 0x3b {
            rain *= 2.5                                         // the Professional Rain Gauge
            reports.append(ISMReport([
                "model": "Bresser-ProRainGauge", "id": .int(id), "battery_ok": .int(batteryLow ? 0 : 1),
                "temperature_C": temperatureOK ? .float(temperature) : nil, "rain_mm": .float(rain), "mic": "CHECKSUM",
            ]))
        } else {
            reports.append(ISMReport([
                "model": "Bresser-5in1", "id": .int(id), "battery_ok": .int(batteryLow ? 0 : 1),
                "temperature_C": temperatureOK ? .float(temperature) : nil, "humidity": humidityOK ? .int(humidity) : nil,
                "wind_max_m_s": .float(gust), "wind_avg_m_s": .float(average), "wind_dir_deg": .float(direction),
                "rain_mm": .float(rain), "mic": "CHECKSUM",
            ]))
        }
        return 1
    }
}

/// Bresser Weather Center 6-in-1 and relatives (7-in-1 indoor, new 5-in-1, 3-in-1 wind gauge, soil and pool
/// sensors, Froggit WH6000, Ventus C8488A): 18 bytes after `aa aa 2d d4`, LFSR-16 digest and an add checksum.
public struct Bresser6in1: ISMDevice {
    public let name = "Bresser Weather Center 6-in-1, 7-in-1 indoor, soil, new 5-in-1, 3-in-1 wind gauge, Froggit WH6000, Ventus C8488A"
    public let protocolNumber = 172
    public let modulation = ISMModulation.fskPCM
    public let timing = ISMTiming(short: 124, long: 124, reset: 25000)
    public init() {}

    private static let moistureMap = [0, 7, 13, 20, 27, 33, 40, 47, 53, 60, 67, 73, 80, 87, 93, 99]

    public func decode(_ bits: inout BitBuffer, into reports: inout [ISMReport]) -> Int {
        let preamble: [UInt8] = [0xaa, 0xaa, 0x2d, 0xd4]
        guard bits.rowCount == 1, bits.bitsPerRow[0] >= 160, bits.bitsPerRow[0] <= 440 else { return DecodeStatus.abortEarly }
        let start = bits.search(row: 0, from: 0, pattern: preamble, bits: 32) + 32
        if start >= bits.bitsPerRow[0] { return DecodeStatus.abortLength }
        if bits.bitsPerRow[0] - start < 18 * 8 { return DecodeStatus.abortLength }
        var msg = bits.extractBytes(row: 0, from: start, bits: 18 * 8)

        let digest = Int(msg[0]) << 8 | Int(msg[1])
        if digest != Int(BitUtil.lfsrDigest16(msg[2..<17], generator: 0x8810, key: 0x5412)) { return DecodeStatus.failMIC }
        if BitUtil.addBytes(msg[2..<18]) & 0xff != 0xff { return DecodeStatus.failMIC }

        let id = UInt32(msg[2]) << 24 | UInt32(msg[3]) << 16 | UInt32(msg[4]) << 8 | UInt32(msg[5])
        let sensorType = Int(msg[6] >> 4)
        let startup = Int((msg[6] >> 3) & 1)
        let channel = Int(msg[6] & 0x7)
        let battery = Int((msg[13] >> 1) & 1)

        let temperatureOK = msg[12] <= 0x99 && msg[13] & 0xf0 <= 0x90
        let temperatureRaw = Int(msg[12] >> 4) * 100 + Int(msg[12] & 0x0f) * 10 + Int(msg[13] >> 4)
        var temperature = Float(temperatureRaw) * 0.1
        if (msg[13] >> 3) & 1 != 0 { temperature = Float(temperatureRaw - 1000) * 0.1 }
        if temperature < -50.0 { temperature = Float(-temperatureRaw) * 0.1 }   // the 3-in-1 wind gauge
        let humidity = Int(msg[14] >> 4) * 10 + Int(msg[14] & 0x0f)

        var uvOK = msg[16] & 0x0f == 0 && ~msg[15] <= 0x99 && ~msg[16] & 0xf0 <= 0x90
        let uvRaw = Int((~msg[15] & 0xf0) >> 4) * 100 + Int(~msg[15] & 0x0f) * 10 + Int((~msg[16] & 0xf0) >> 4)
        let uv = Float(uvRaw) * 0.1
        let flags = Int(msg[16] & 0x0f)

        msg[7] ^= 0xff; msg[8] ^= 0xff; msg[9] ^= 0xff
        var windOK = msg[7] <= 0x99 && msg[8] <= 0x99 && msg[9] <= 0x99
        let gust = Float(Int(msg[7] >> 4) * 100 + Int(msg[7] & 0x0f) * 10 + Int(msg[8] >> 4)) * 0.1
        let average = Float(Int(msg[9] >> 4) * 100 + Int(msg[9] & 0x0f) * 10 + Int(msg[8] & 0x0f)) * 0.1
        let direction = Int((msg[10] & 0xf0) >> 4) * 100 + Int(msg[10] & 0x0f) * 10 + Int((msg[11] & 0xf0) >> 4)

        msg[12] ^= 0xff; msg[13] ^= 0xff; msg[14] ^= 0xff
        let rainOK = msg[16] & 1 != 0
        let rainRaw = Int(msg[12] >> 4) * 100_000 + Int(msg[12] & 0x0f) * 10_000 + Int(msg[13] >> 4) * 1_000
            + Int(msg[13] & 0x0f) * 100 + Int(msg[14] >> 4) * 10 + Int(msg[14] & 0x0f)
        let rain = Float(rainRaw) * 0.1

        if sensorType == 4 { windOK = false; uvOK = false }     // the soil probe has no such hardware
        var moisture = -1
        if sensorType == 4 && temperatureOK && humidity >= 1 && humidity <= 16 { moisture = Self.moistureMap[humidity - 1] }

        reports.append(ISMReport([
            "model": "Bresser-6in1",
            "id": .int32(id),
            "channel": .int(channel),
            "battery_ok": rainOK ? nil : .int(battery),
            "temperature_C": temperatureOK ? .float(temperature) : nil,
            "humidity": temperatureOK && moisture < 0 ? .int(humidity) : nil,
            "sensor_type": .int(sensorType),
            "moisture": moisture >= 0 ? .int(moisture) : nil,
            "wind_max_m_s": windOK ? .float(gust) : nil,
            "wind_avg_m_s": windOK ? .float(average) : nil,
            "wind_dir_deg": windOK ? .int(direction) : nil,
            "rain_mm": rainOK ? .float(rain) : nil,
            "uv": uvOK ? .float(uv) : nil,
            "startup": startup != 0 ? .int(startup) : nil,
            "flags": .int(flags),
            "mic": "CRC",
        ]))
        return 1
    }
}

/// Fine Offset WH2 and relatives (WH2A, WH5, Telldus/Proove, Rosenborg 66796): PWM, 48 bits, CRC-8 (0x31).
public struct FineOffsetWH2: ISMDevice {
    public let name = "Fine Offset Electronics, WH2, WH5, Telldus Temperature/Humidity/Rain Sensor"
    public let protocolNumber = 18
    public let modulation = ISMModulation.ookPWM
    public let timing = ISMTiming(short: 500, long: 1500, reset: 1200, tolerance: 160)
    public init() {}

    public func decode(_ bits: inout BitBuffer, into reports: inout [ISMReport]) -> Int {
        let row = bits.row(0), length = bits.bitsPerRow[0]
        let b: [UInt8], model: String
        if length == 48 && row[0] == 0xff {
            b = bits.extractBytes(row: 0, from: 8, bits: 40); model = "Fineoffset-WH2"
        } else if length == 55 && row[0] == 0xfe {
            b = bits.extractBytes(row: 0, from: 7, bits: 48); model = "Fineoffset-WH2A"
        } else if length == 47 && row[0] == 0xfe {
            b = bits.extractBytes(row: 0, from: 7, bits: 40); model = "Fineoffset-WH5"
        } else if length == 49 && row[0] == 0xff && row[1] & 0x80 == 0x80 {
            b = bits.extractBytes(row: 0, from: 9, bits: 40); model = "Fineoffset-TelldusProove"
        } else {
            return DecodeStatus.abortLength
        }
        if b[4] != BitUtil.crc8(b.prefix(4), polynomial: 0x31, initial: 0) { return DecodeStatus.failMIC }
        if b[0] >> 4 != 4 { return DecodeStatus.failSanity }

        let id = Int(b[0] & 0x0f) << 4 | Int(b[1] & 0xf0) >> 4
        var temperature = Int(b[1] & 0x0f) << 8 | Int(b[2])
        if length != 47 {
            if temperature & 0x800 != 0 { temperature = -(temperature & 0x7ff) }   // sign and magnitude
        } else {
            temperature -= 400                                  // WH5: offset by 40 °C
        }
        let humidity = Int(b[3])
        reports.append(ISMReport([
            "model": .string(model), "id": .int(id), "temperature_C": .float(Float(temperature) * 0.1),
            "humidity": humidity != 0xff ? .int(humidity) : nil, "mic": "CRC",
        ]))
        return 1
    }
}

/// Fine Offset WH25/WH32/WH32B indoor units and (by length) the WH24/WH65B/HP1000 outdoor arrays, also sold as
/// Ecowitt, Ambient Weather and Misol: FSK, `aa 2d d4` then the payload.
public struct FineOffsetWH25: ISMDevice {
    public let name = "Fine Offset Electronics, WH25, WH32, WH32B, WN32B, WH24, WH65B, HP1000, Misol WS2320 Temperature/Humidity/Pressure Sensor"
    public let protocolNumber = 78
    public let modulation = ISMModulation.fskPCM
    public let timing = ISMTiming(short: 58, long: 58, reset: 20000)
    public init() {}

    private static let preamble: [UInt8] = [0xaa, 0x2d, 0xd4]

    public func decode(_ bits: inout BitBuffer, into reports: inout [ISMReport]) -> Int {
        var type = 25
        let length = bits.bitsPerRow[0]
        if length < 160 {
            return decodeWH0290(bits, into: &reports)           // nominally 129 bits
        } else if length < 190 {
            type = 32                                           // WN32B
        } else if length < 440 {
            return decodeWH24(bits, into: &reports)
        }
        if length > 510 { type = 32 }

        let offset = bits.search(row: 0, from: 0, pattern: Self.preamble, bits: 24) + 24
        if offset + 64 > length { return DecodeStatus.abortLength }
        let b = bits.extractBytes(row: 0, from: offset, bits: 64)
        let messageType = b[0] & 0xf0
        if type == 32 && messageType == 0xd0 {
            type = 31                                           // an older WH32 without a barometer
        } else if messageType != 0xe0 {
            return b[0] == 0x41 ? decodeWH0290(bits, into: &reports) : DecodeStatus.abortEarly
        }
        if (BitUtil.addBytes(b.prefix(6)) & 0xff) - Int(b[6]) != 0 { return DecodeStatus.failMIC }
        var xorSum = BitUtil.xorBytes(b.prefix(6))
        xorSum = (xorSum & 0x0f) << 4 | xorSum >> 4
        if type == 25 && xorSum != b[7] { return DecodeStatus.failMIC }

        let id = Int(b[0] & 0x0f) << 4 | Int(b[1] >> 4)
        let lowBattery = (b[1] & 0x08) >> 3
        let temperature = Float((Int(b[1] & 0x03) << 8 | Int(b[2])) - 400) * 0.1
        let pressureRaw = Int(b[4]) << 8 | Int(b[5])
        reports.append(ISMReport([
            "model": .string(type == 31 ? "Fineoffset-WH32" : type == 32 ? "Fineoffset-WH32B" : "Fineoffset-WH25"),
            "id": .int(id), "battery_ok": .int(lowBattery == 0 ? 1 : 0), "temperature_C": .float(temperature),
            "humidity": .int(Int(b[3])), "pressure_hPa": pressureRaw != 0xffff ? .float(Float(pressureRaw) * 0.1) : nil,
            "mic": "CRC",
        ]))
        return 1
    }

    /// WH0290 (also Ambient Weather PM25, Misol PM25, Ecowitt WH41) air-quality monitor.
    private func decodeWH0290(_ bits: BitBuffer, into reports: inout [ISMReport]) -> Int {
        let offset = bits.search(row: 0, from: 0, pattern: Self.preamble, bits: 24) + 24
        if offset + 64 > bits.bitsPerRow[0] { return DecodeStatus.abortLength }
        let b = bits.extractBytes(row: 0, from: offset, bits: 64)
        let crc = BitUtil.crc8(b.prefix(6), polynomial: 0x31, initial: 0)
        let sum = UInt8(truncatingIfNeeded: BitUtil.addBytes(b.prefix(7)))
        if crc != b[6] || sum != b[7] { return DecodeStatus.failMIC }
        let pm25 = Int(b[2] & 0x3f) << 8 | Int(b[3])
        let pm100 = Int(b[4] & 0x3f) << 8 | Int(b[5])
        let batteryBars = Int(b[2] & 0x40) >> 4 | Int(b[4] & 0xc0) >> 6         // out of 5
        reports.append(ISMReport([
            "model": "Fineoffset-WH0290", "id": .int(Int(b[1])), "battery_ok": .float(Float(batteryBars) * 0.2),
            "pm2_5_ug_m3": .int(pm25 / 10), "estimated_pm10_0_ug_m3": .int(pm100 / 10), "family": .int(Int(b[0])),
            "unknown1": .int(b[2] & 0x80 != 0 ? 1 : 0), "mic": "CRC",
        ]))
        return 1
    }

    private func decodeWH24(_ bits: BitBuffer, into reports: inout [ISMReport]) -> Int {
        let length = bits.bitsPerRow[0]
        if length < 190 || length > 215 { return DecodeStatus.abortLength }
        let offset = bits.search(row: 0, from: 0, pattern: Self.preamble, bits: 24) + 24
        if offset + 17 * 8 > length { return DecodeStatus.abortLength }
        // WH24: nominally 3 bits after the payload; WH65B: a longer preamble and 12 bits after.
        let isWH24 = length - offset - 17 * 8 < 8 && offset < 61
        let b = bits.extractBytes(row: 0, from: offset, bits: 17 * 8)
        if b[0] != 0x24 { return DecodeStatus.failSanity }
        let crc = BitUtil.crc8(b.prefix(15), polynomial: 0x31, initial: 0)
        let sum = UInt8(truncatingIfNeeded: BitUtil.addBytes(b.prefix(16)))
        if crc != b[15] || sum != b[16] { return DecodeStatus.failMIC }

        let direction = Int(b[2]) | Int(b[3] & 0x80) << 1
        let lowBattery = (b[3] & 0x08) >> 3
        let temperatureRaw = Int(b[3] & 0x07) << 8 | Int(b[4])
        let humidity = Int(b[5])
        let windRaw = Int(b[6]) | Int(b[3] & 0x10) << 4
        let speedFactor: Float = isWH24 ? 1.12 : 0.51
        let rainPerTip: Float = isWH24 ? 0.3 : 0.254
        let gustRaw = Int(b[7])
        let rainRaw = Int(b[8]) << 8 | Int(b[9])
        let uvRaw = Int(b[10]) << 8 | Int(b[11])
        let lightRaw = Int(b[12]) << 16 | Int(b[13]) << 8 | Int(b[14])
        let uvUpper = [432, 851, 1210, 1570, 2017, 2450, 2761, 3100, 3512, 3918, 4277, 4650, 5029]
        var uvIndex = 0
        while uvIndex < 13 && uvUpper[uvIndex] < uvRaw { uvIndex += 1 }

        reports.append(ISMReport([
            "model": .string(isWH24 ? "Fineoffset-WH24" : "Fineoffset-WH65B"),
            "id": .int(Int(b[1])),
            "battery_ok": .int(lowBattery == 0 ? 1 : 0),
            "temperature_C": temperatureRaw != 0x7ff ? .float(Float(temperatureRaw - 400) * 0.1) : nil,
            "humidity": humidity != 0xff ? .int(humidity) : nil,
            "wind_dir_deg": direction != 0x1ff ? .int(direction) : nil,
            "wind_avg_m_s": windRaw != 0x1ff ? .float(Float(windRaw) * 0.125 * speedFactor) : nil,
            "wind_max_m_s": gustRaw != 0xff ? .float(Float(gustRaw) * speedFactor) : nil,
            "rain_mm": .float(Float(rainRaw) * rainPerTip),
            "uv": uvRaw != 0xffff ? .int(uvRaw) : nil,
            "uvi": uvRaw != 0xffff ? .int(uvIndex) : nil,
            "light_lux": lightRaw != 0xffffff ? .double(Double(lightRaw) * 0.1) : nil,
            "mic": "CRC",
        ]))
        return 1
    }
}

/// The AcuRite "TXR" family: PWM with sync pulses, a message type in byte 2, parity bits and an add checksum.
/// 592TXR/06002RM Tower, Iris 5-n-1, Notos 3-n-1, Atlas, 6045M lightning detector, 899 rain gauge, 515
/// refrigerator/freezer and 1190/1192 leak detector.
public struct AcuriteTXR: ISMDevice {
    public let name = "Acurite 592TXR Temp/Humidity, 592TX Temp, 5n1 Weather Station, 6045 Lightning, 899 Rain, 3N1, Atlas"
    public let protocolNumber = 40
    public let modulation = ISMModulation.ookPWM
    public let timing = ISMTiming(short: 220, long: 408, reset: 4000, gap: 500, sync: 620)
    public init() {}

    private enum Kind {
        static let leak: UInt8 = 0x01, tower: UInt8 = 0x04, refrigerator: UInt8 = 0x08, freezer: UInt8 = 0x09
        static let threeInOne: UInt8 = 0x20, lightning: UInt8 = 0x2f, rain899: UInt8 = 0x30
        static let fiveInOneRain: UInt8 = 0x31, fiveInOneTemperature: UInt8 = 0x38
        static let atlas: Set<UInt8> = [0x05, 0x06, 0x07], atlasWithLightning: Set<UInt8> = [0x25, 0x26, 0x27]
    }
    private static let known: Set<UInt8> = [0x01, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x20, 0x25, 0x26, 0x27, 0x2f, 0x30, 0x31, 0x38]
    // 5-n-1 wind direction in units of 22.5°, indexed by the transmitted code (the mapping jumps around).
    private static let windDirections = [14, 11, 13, 12, 15, 10, 0, 9, 3, 6, 4, 5, 2, 7, 1, 8]

    private static func channel(_ byte: UInt8) -> String { ["C", "E", "B", "A"][Int((byte & 0xc0) >> 6)] }
    private static func hex(_ bytes: ArraySlice<UInt8>) -> String { bytes.map(hex2).joined() }

    /// Length, checksum (last byte), even parity of the bytes between the ID and the checksum, and channel.
    private func check(_ bb: [UInt8], _ rowBytes: Int, _ expected: Int) -> Int {
        if rowBytes < 6 || rowBytes < expected { return DecodeStatus.abortLength }
        if BitUtil.addBytes(bb.prefix(expected - 1)) & 0xff != Int(bb[expected - 1]) { return DecodeStatus.failMIC }
        if BitUtil.parity(bb[2..<(expected - 1)]) != 0 { return DecodeStatus.failMIC }
        if Self.channel(bb[0]) == "E" { return DecodeStatus.failSanity }
        return 0
    }

    public func decode(_ bits: inout BitBuffer, into reports: inout [ISMReport]) -> Int {
        var decoded = 0
        var error = 0
        bits.invert()
        for row in 0..<bits.rowCount {
            let rowBytes = bits.bitsPerRow[row] / 8             // extra bits are spurious
            if rowBytes < 6 { continue }
            if rowBytes > 10 { error = DecodeStatus.abortLength; continue }
            let bb = bits.row(row).bytes(16)
            let allBytes = (bits.bitsPerRow[row] + 7) / 8       // what the raw_msg field shows
            if bb[0] == 0 && bb[1] == 0 && bb[2] == 0 && bb[rowBytes - 1] == 0 { continue }
            let type = bb[2] & 0x3f
            guard Self.known.contains(type) else { error = DecodeStatus.failSanity; continue }

            func run(expecting length: Int, _ body: () -> Int) {
                let checked = check(bb, rowBytes, length)
                if checked != 0 { error = checked; return }
                let result = body()
                if result > 0 { decoded += result } else if result < 0 { error = result }
            }
            switch type {
            case Kind.tower: run(expecting: 7) { decodeTower(bb, into: &reports) }
            case Kind.leak: run(expecting: 7) { decodeLeak(bb, into: &reports) }
            case Kind.lightning: run(expecting: 9) { decodeLightning(bb, allBytes, into: &reports) }
            case Kind.refrigerator, Kind.freezer: run(expecting: 6) { decode515(bb, into: &reports) }
            case Kind.fiveInOneRain, Kind.fiveInOneTemperature: run(expecting: 8) { decodeFiveInOne(bb, into: &reports) }
            case Kind.rain899: run(expecting: 8) { decode899(bb, into: &reports) }
            case Kind.threeInOne:
                // The 3-n-1 is checked by checksum only (a sample in rtl_433_tests has odd parity).
                if rowBytes < 8 { error = DecodeStatus.abortLength; continue }
                if BitUtil.addBytes(bb.prefix(7)) & 0xff != Int(bb[7]) { error = DecodeStatus.failMIC; continue }
                let result = decodeThreeInOne(bb, into: &reports)
                if result > 0 { decoded += result } else if result < 0 { error = result }
            default:
                run(expecting: Kind.atlas.contains(type) ? 8 : 10) { decodeAtlas(bb, allBytes, into: &reports) }
            }
        }
        return decoded > 0 ? decoded : error
    }

    private func decodeTower(_ bb: [UInt8], into reports: inout [ISMReport]) -> Int {
        let channel = Self.channel(bb[0])
        let id = Int(bb[0] & 0x3f) << 8 | Int(bb[1])
        let batteryLow = bb[2] & 0x40 == 0
        let humidity = Int(bb[3] & 0x7f)
        if humidity > 100 && humidity != 127 { return DecodeStatus.failSanity }
        let raw = Int(bb[4] & 0x7f) << 7 | Int(bb[5] & 0x7f)
        let temperature = Float(raw - 1000) * 0.1
        if temperature < -40 || temperature > 70 { return DecodeStatus.failSanity }
        var report = ISMReport([
            "model": "Acurite-Tower", "id": .int(id), "channel": .string(channel), "battery_ok": .int(batteryLow ? 0 : 1),
            "temperature_C": .float(temperature), "humidity": humidity != 127 ? .int(humidity) : nil, "mic": "CHECKSUM",
        ])
        if raw & 0x3800 != 0 {
            // Bits that should be zero are not: add the raw message for later analysis, as rtl_433 does.
            report.append("exception", .int(1))
            report.append("raw_msg", .string(Self.hex(bb[0..<7])))
        }
        reports.append(report)
        return 1
    }

    private func decodeLeak(_ bb: [UInt8], into reports: inout [ISMReport]) -> Int {
        reports.append(ISMReport([
            "model": "Acurite-Leak", "id": .int(Int(bb[0] & 0x3f) << 8 | Int(bb[1])), "channel": .string(Self.channel(bb[0])),
            "battery_ok": .int(bb[2] & 0x40 == 0 ? 0 : 1), "leak_detected": .int(Int((bb[3] & 0x10) >> 4)), "mic": "CHECKSUM",
        ]))
        return 1
    }

    private func decodeLightning(_ bb: [UInt8], _ allBytes: Int, into reports: inout [ISMReport]) -> Int {
        let humidity = Int(bb[3] & 0x7f)
        if humidity > 100 { return DecodeStatus.failSanity }
        let raw = Int(bb[4] & 0x1f) << 7 | Int(bb[5] & 0x7f)
        let temperatureF = Float(raw - 1480) * 0.1
        if temperatureF < -40.0 || temperatureF > 158.0 { return DecodeStatus.failSanity }
        var exception = raw & 0x3000 != 0 ? 1 : 0
        if bb[4] & 0x20 != 0 { exception += 1 }                // unknown status bits, always off
        reports.append(ISMReport([
            "model": "Acurite-6045M", "id": .int(Int(bb[0] & 0x3f) << 8 | Int(bb[1])), "channel": .string(Self.channel(bb[0])),
            "battery_ok": .int(bb[2] & 0x40 == 0 ? 0 : 1), "temperature_F": .float(temperatureF), "humidity": .int(humidity),
            "strike_count": .int(Int(bb[6] & 0x7f) << 1 | Int((bb[7] & 0x40) >> 6)), "storm_dist": .int(Int(bb[7] & 0x1f)),
            "active": .int(bb[4] & 0x40 != 0 ? 1 : 0), "rfi": .int(bb[7] & 0x20 != 0 ? 1 : 0), "exception": .int(exception),
            "raw_msg": .string(Self.hex(bb[0..<min(allBytes, 15)])),
        ]))
        return 1
    }

    private func decode515(_ bb: [UInt8], into reports: inout [ISMReport]) -> Int {
        let raw = Int(bb[3] & 0x7f) << 7 | Int(bb[4] & 0x7f)
        let temperatureF = Float(raw - 1480) * 0.1
        if temperatureF < -40.0 || temperatureF > 158.0 { return DecodeStatus.failSanity }
        let channel = Self.channel(bb[0]) + (bb[2] & 0x3f == Kind.refrigerator ? "R" : "F")
        var report = ISMReport([
            "model": "Acurite-515", "id": .int(Int(bb[0] & 0x3f) << 8 | Int(bb[1])), "channel": .string(channel),
            "battery_ok": .int(bb[2] & 0x40 == 0 ? 0 : 1), "temperature_F": .float(temperatureF), "mic": "CHECKSUM",
        ])
        if raw & 0x3000 != 0 {
            report.append("exception", .int(1))
            report.append("raw_msg", .string(Self.hex(bb[0..<6])))
        }
        reports.append(report)
        return 1
    }

    private func decodeFiveInOne(_ bb: [UInt8], into reports: inout [ISMReport]) -> Int {
        let channel = Self.channel(bb[0])
        let id = Int(bb[0] & 0x0f) << 8 | Int(bb[1])
        let sequence = Int((bb[0] & 0x30) >> 4)
        let batteryLow = bb[2] & 0x40 == 0
        let type = bb[2] & 0x3f
        let speedRaw = Int(bb[3] & 0x1f) << 3 | Int((bb[4] & 0x70) >> 4)   // cup rotations per 4 s
        let speed: Float = speedRaw > 0 ? Float(speedRaw) * 0.8278 + 1.0 : 0

        if type == Kind.fiveInOneRain {
            let direction = Float(Self.windDirections[Int(bb[4] & 0x0f)]) * 22.5
            let rain = Int(bb[5] & 0x7f) << 7 | Int(bb[6] & 0x7f)
            reports.append(ISMReport([
                "model": "Acurite-5n1", "message_type": .int(Int(type)), "id": .int(id), "channel": .string(channel),
                "sequence_num": .int(sequence), "battery_ok": .int(batteryLow ? 0 : 1), "wind_avg_km_h": .float(speed),
                "wind_dir_deg": .float(direction), "rain_in": .float(Float(rain) * 0.01), "mic": "CHECKSUM",
            ]))
        } else {
            let temperatureF = Float((Int(bb[4] & 0x0f) << 7 | Int(bb[5] & 0x7f)) - 400) * 0.1
            if temperatureF < -40.0 || temperatureF > 158.0 { return DecodeStatus.failSanity }
            let humidity = Int(bb[6] & 0x7f)
            if humidity > 100 { return DecodeStatus.failSanity }
            reports.append(ISMReport([
                "model": "Acurite-5n1", "message_type": .int(Int(type)), "id": .int(id), "channel": .string(channel),
                "sequence_num": .int(sequence), "battery_ok": .int(batteryLow ? 0 : 1), "wind_avg_km_h": .float(speed),
                "temperature_F": .float(temperatureF), "humidity": .int(humidity), "mic": "CHECKSUM",
            ]))
        }
        return 1
    }

    private func decode899(_ bb: [UInt8], into reports: inout [ISMReport]) -> Int {
        let rain = Int(bb[5] & 0x7f) << 7 | Int(bb[6] & 0x7f)   // tips of 0.01 inch
        reports.append(ISMReport([
            "model": "Acurite-Rain899", "id": .int(Int(bb[0] & 0x3f) << 8 | Int(bb[1])), "channel": .int(Int(bb[0] >> 6)),
            "battery_ok": .int(bb[2] & 0x40 == 0 ? 0 : 1), "rain_mm": .double(Double(rain) * 0.254), "mic": "CHECKSUM",
        ]))
        return 1
    }

    private func decodeThreeInOne(_ bb: [UInt8], into reports: inout [ISMReport]) -> Int {
        let channel = Self.channel(bb[0])
        if channel == "E" { return DecodeStatus.failSanity }
        let humidity = Int(bb[3] & 0x7f)
        if humidity > 100 { return DecodeStatus.failSanity }
        let temperatureF = Float((Int(bb[4] & 0x1f) << 7 | Int(bb[5] & 0x7f)) - 1480) * 0.1
        if temperatureF < -40.0 || temperatureF > 158.0 { return DecodeStatus.failSanity }
        reports.append(ISMReport([
            "model": "Acurite-3n1", "message_type": .int(Int(bb[2] & 0x3f)), "id": .int(Int(bb[0] & 0x3f) << 8 | Int(bb[1])),
            "channel": .string(channel), "sequence_num": .int(Int((bb[0] & 0x30) >> 4)), "battery_ok": .int(bb[2] & 0x40 == 0 ? 0 : 1),
            "wind_avg_mi_h": .float(Float(bb[6] & 0x7f)), "temperature_F": .float(temperatureF), "humidity": .int(humidity),
            "mic": "CHECKSUM",
        ]))
        return 1
    }

    private func decodeAtlas(_ bb: [UInt8], _ allBytes: Int, into reports: inout [ISMReport]) -> Int {
        let type = bb[2] & 0x3f
        var exception = 0
        let speed = Float(Int(bb[3] & 0x7f) << 1 | Int((bb[4] & 0x40) >> 6))   // mph
        if speed > 200 { return DecodeStatus.failSanity }
        var report = ISMReport([
            "model": "Acurite-Atlas", "id": .int(Int(bb[0] & 0x03) << 8 | Int(bb[1])), "channel": .string(Self.channel(bb[0])),
            "sequence_num": .int(Int((bb[0] & 0x0c) >> 2)), "battery_ok": .int(bb[2] & 0x40 == 0 ? 0 : 1),
            "message_type": .int(Int(type)), "wind_avg_mi_h": .float(speed),
        ])
        switch type & 0x0f {
        case 0x05:                                              // wind speed, temperature, humidity
            if bb[4] & 0x30 != 0 { exception += 1 }
            let temperatureF = Float((Int(bb[4] & 0x0f) << 7 | Int(bb[5] & 0x7f)) - 400) * 0.1
            if temperatureF < -40.0 || temperatureF > 158.0 { return DecodeStatus.failSanity }
            let humidity = Int(bb[6] & 0x7f)
            if humidity > 100 { return DecodeStatus.failSanity }
            if humidity == 0 { exception += 1 }
            report.append("temperature_F", .float(temperatureF))
            report.append("humidity", .int(humidity))
        case 0x06:                                              // wind speed, direction, rain
            let direction = Float(Int(bb[4] & 0x1f) << 5 | Int((bb[5] & 0x7c) >> 2))
            if bb[4] & 0x30 != 0 { exception += 1 }
            if direction > 360 { return DecodeStatus.failSanity }
            let rain = Int(bb[5] & 0x03) << 7 | Int(bb[6] & 0x7f)
            report.append("wind_dir_deg", .float(direction))
            report.append("rain_in", .float(Float(rain) * 0.01))
        default:                                                // wind speed, UV, lux
            let lux = Int(bb[5] & 0x7f) << 7 | Int(bb[6] & 0x7f)
            if lux > 12000 { return DecodeStatus.failSanity }
            report.append("uv", .int(Int(bb[4] & 0x0f)))
            report.append("lux", .int(lux * 10))
        }
        if Kind.atlasWithLightning.contains(type) {
            report.append("strike_count", .int(Int(bb[7] & 0x7f) << 2 | Int((bb[8] & 0x60) >> 5)))
            report.append("strike_distance", .int(Int(bb[8] & 0x1f)))
        }
        report.append("exception", .int(exception))
        report.append("raw_msg", .string(Self.hex(bb[0..<min(allBytes, 15)])))
        reports.append(report)
        return 1
    }
}
