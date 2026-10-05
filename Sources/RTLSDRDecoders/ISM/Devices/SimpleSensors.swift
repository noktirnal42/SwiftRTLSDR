// SPDX-License-Identifier: GPL-2.0-or-later
//
// Small temperature/humidity sensors and remotes, ported from rtl_433 release 25.02 (GPL-2.0-or-later):
// nexus.c, rubicson.c, generic_remote.c, ambient_weather.c, lacrosse_tx141x.c. Protocol descriptions, field names
// and checks are rtl_433's; the upstream authors are credited in NOTICE. See PROVENANCE.md.

/// Nexus, FreeTec NC-7345, NX-3980, Solight TE82S, TFA 30.3209: 36 bits, PPM, repeated 12 times.
///
/// `[id:8] [battery:1 0:1 channel:2] [temperature:12, signed, ×10] [1111] [humidity:8]`
public struct NexusSensor: ISMDevice {
    public let name = "Nexus, FreeTec NC-7345, NX-3980, Solight TE82S, TFA 30.3209 temperature/humidity sensor"
    public let protocolNumber = 19
    public let modulation = ISMModulation.ookPPM
    public let timing = ISMTiming(short: 1000, long: 2000, reset: 5000, gap: 3000)
    public let priority = 10                                    // after Rubicson, which shares the framing
    public init() {}

    public func decode(_ bits: inout BitBuffer, into reports: inout [ISMReport]) -> Int {
        guard let r = bits.findRepeatedRow(minimumRepeats: 3, minimumBits: 36) else { return DecodeStatus.abortEarly }
        let b = bits.row(r)
        if bits.bitsPerRow[r] > 37 { return DecodeStatus.abortLength }   // 36 bits, maybe a trailing 0
        if b[3] & 0xf0 != 0xf0 { return DecodeStatus.abortEarly }
        if (b[0] == 0 && b[2] == 0 && b[3] == 0) || (b[0] == 0xff && b[2] == 0xff && b[3] == 0xff) { return DecodeStatus.abortEarly }

        let id = Int(b[0])
        let battery = b[1] & 0x80 != 0
        let channel = Int((b[1] & 0x30) >> 4) + 1
        let raw = Int16(truncatingIfNeeded: Int(b[1]) << 12 | Int(b[2]) << 4)
        let temperature = Float(Int(raw) >> 4) * 0.1
        let humidity = Int(b[3] & 0x0f) << 4 | Int(b[4] >> 4)

        reports.append(ISMReport([
            "model": .string(humidity == 0 ? "Nexus-T" : "Nexus-TH"),
            "id": .int(id),
            "channel": .int(channel),
            "battery_ok": .int(battery ? 1 : 0),
            "temperature_C": .float(temperature),
            "humidity": humidity == 0 ? nil : .int(humidity),
        ]))
        return 1
    }
}

/// Rubicson, TFA 30.3197, InFactory PT-310: 36 bits, PPM, repeated 12 times, CRC-8 (0x31, init 0x6c).
public struct RubicsonSensor: ISMDevice {
    public let name = "Rubicson, TFA 30.3197 or InFactory PT-310 Temperature Sensor"
    public let protocolNumber = 2
    public let modulation = ISMModulation.ookPPM
    public let timing = ISMTiming(short: 1000, long: 2000, reset: 4800, gap: 3000)
    public init() {}

    public func decode(_ bits: inout BitBuffer, into reports: inout [ISMReport]) -> Int {
        guard let r = bits.findRepeatedRow(minimumRepeats: 3, minimumBits: 36) else { return DecodeStatus.abortEarly }
        let b = bits.row(r)
        if bits.bitsPerRow[r] < 36 || bits.bitsPerRow[r] > 38 { return DecodeStatus.abortLength }
        if b[3] & 0xf0 != 0xf0 { return DecodeStatus.abortEarly }
        let check = [b[0], b[1], b[2], b[3] & 0xf0, (b[3] & 0x0f) << 4 | (b[4] & 0xf0) >> 4]
        if BitUtil.crc8(check, polynomial: 0x31, initial: 0x6c) != 0 { return DecodeStatus.failMIC }

        let raw = Int16(truncatingIfNeeded: Int(b[1]) << 12 | Int(b[2]) << 4)
        reports.append(ISMReport([
            "model": "Rubicson-Temperature",
            "id": .int(Int(b[0])),
            "channel": .int(Int((b[1] & 0x30) >> 4) + 1),
            "battery_ok": .int(b[1] & 0x80 != 0 ? 1 : 0),
            "temperature_C": .float(Float(Int(raw) >> 4) * 0.1),
            "mic": "CRC",
        ]))
        return 1
    }
}

/// Remotes and sensors on PT2260/PT2262, SC2260/SC2262 and EV1527 chips: 24 bits plus a stop bit, PWM.
public struct GenericRemote: ISMDevice {
    public let name = "Generic Remote SC226x EV1527"
    public let protocolNumber = 30
    public let modulation = ISMModulation.ookPWM
    public let timing = ISMTiming(short: 464, long: 1404, reset: 1800, tolerance: 200)
    public init() {}

    public func decode(_ bits: inout BitBuffer, into reports: inout [ISMReport]) -> Int {
        let row = bits.row(0)
        let b = [~row[0], ~row[1], ~row[2], row[3]]             // short pulse 0, long pulse 1
        if bits.bitsPerRow[0] != 25 || b[3] & 0x80 == 0 || (b[0] == 0 && b[1] == 0) || b[2] == 0 {
            return DecodeStatus.abortLength
        }
        let full = Int(b[0]) << 16 | Int(b[1]) << 8 | Int(b[2])
        let tristate = String(stride(from: 22, through: 0, by: -2).map { shift -> Character in
            switch (full >> shift) & 3 {
            case 0: return "0"
            case 1: return "Z"                                  // floating
            case 2: return "X"                                  // invalid for SC226x, valid for EV1527
            default: return "1"
            }
        })
        reports.append(ISMReport([
            "model": "Generic-Remote",
            "id": .int(Int(b[0]) << 8 | Int(b[1])),
            "cmd": .int(Int(b[2])),
            "tristate": .string(tristate),
        ]))
        return 1
    }
}

/// Ambient Weather F007TH/F012TH, TFA 30.3208.02, SwitchDoc Labs F016TH: Manchester, 6 bytes after a preamble,
/// LFSR digest (generator 0x98, key 0x3e, XOR 0x64).
public struct AmbientWeatherF007TH: ISMDevice {
    public let name = "Ambient Weather F007TH, TFA 30.3208.02, SwitchDocLabs F016TH temperature sensor"
    public let protocolNumber = 20
    public let modulation = ISMModulation.ookManchesterZeroBit
    public let timing = ISMTiming(short: 500, long: 0, reset: 2400)
    public init() {}

    private func decode(_ bits: BitBuffer, row: Int, at position: Int, into reports: inout [ISMReport]) -> Int {
        let b = bits.extractBytes(row: row, from: position, bits: 48)
        let calculated = BitUtil.lfsrDigest8(b.prefix(5), generator: 0x98, key: 0x3e) ^ 0x64
        if b[5] != calculated { return DecodeStatus.failMIC }
        let temperatureF = Float((Int(b[2] & 0x0f) << 8 | Int(b[3])) - 400) * 0.1
        let humidity = Int(b[4])
        if humidity > 100 { return DecodeStatus.failSanity }
        if temperatureF < -40.0 || temperatureF > 140.0 { return DecodeStatus.failSanity }
        reports.append(ISMReport([
            "model": "Ambientweather-F007TH",
            "id": .int(Int(b[1])),
            "channel": .int(Int((b[2] & 0x70) >> 4) + 1),
            "battery_ok": .int(b[2] & 0x80 != 0 ? 0 : 1),
            "temperature_F": .float(temperatureF),
            "humidity": .int(humidity),
            "mic": "CRC",
        ]))
        return 1
    }

    public func decode(_ bits: inout BitBuffer, into reports: inout [ISMReport]) -> Int {
        // Three repeats without a gap; the preamble is 0x00145 (or 0xffd45 when the Manchester phase is inverted).
        let preamble: [UInt8] = [0x01, 0x45], inverted: [UInt8] = [0xfd, 0x45]
        var result = 0
        for row in 0..<bits.rowCount {
            var position = 0
            while true {
                position = bits.search(row: row, from: position, pattern: preamble, bits: 12)
                guard position + 8 + 48 <= bits.bitsPerRow[row] else { break }
                result = decode(bits, row: row, at: position + 8, into: &reports)
                if result > 0 { return result }
                position += 16
            }
            position = 0
            while true {
                position = bits.search(row: row, from: position, pattern: inverted, bits: 12)
                guard position + 8 + 48 <= bits.bitsPerRow[row] else { break }
                result = decode(bits, row: row, at: position + 8, into: &reports)
                if result > 0 { return result }
                position += 15
            }
        }
        return result
    }
}

/// LaCrosse TX141-Bv2/Bv3, TX141TH-Bv2, TX141W, TX145wsdth (and TFA, ORIA rebrands): PWM, 4 sync pulses, up to 12
/// repeats.
public struct LaCrosseTX141: ISMDevice {
    public let name = "LaCrosse TX141-Bv2, TX141TH-Bv2, TX141-Bv3, TX141W, TX145wsdth, (TFA, ORIA) sensor"
    public let protocolNumber = 73
    public let modulation = ISMModulation.ookPWM
    public let timing = ISMTiming(short: 208, long: 417, reset: 1700, gap: 625, sync: 833)
    public init() {}

    private enum Kind { case tx141b, tx141, tx141th, tx141bv3, tx141w }

    public func decode(_ bits: inout BitBuffer, into reports: inout [ISMReport]) -> Int {
        // The most frequent row: at least 5 of 12 repeats, or 3 of 4; then 2 of 3-7 for the TX141W.
        guard let r = bits.findRepeatedRow(minimumRepeats: bits.rowCount > 5 ? 5 : 3, minimumBits: 32)
                ?? bits.findRepeatedRow(minimumRepeats: 2, minimumBits: 64) else { return DecodeStatus.abortLength }
        let length = bits.bitsPerRow[r]
        let kind: Kind
        if length >= 64 {
            kind = .tx141w
        } else if length > 41 {
            return DecodeStatus.abortLength
        } else if length >= 41 {
            if bits.rowCount > 12 { return DecodeStatus.abortLength }   // a GT-WT03 false positive
            kind = .tx141th                                     // a TX141TH-Bv3
        } else if length >= 40 {
            kind = .tx141th
        } else if length >= 37 {
            kind = .tx141
        } else if length == 32 {
            kind = .tx141b
        } else {
            kind = .tx141bv3
        }

        bits.invert()
        let b = bits.row(r)

        if kind == .tx141w {
            if b[0] >> 3 != 0x01 { return DecodeStatus.abortEarly }
            if BitUtil.crc8(b.bytes(8), polynomial: 0x31, initial: 0) != 0 { return DecodeStatus.failMIC }
            let id = Int(b[0] & 0x07) << 16 | Int(b[1]) << 8 | Int(b[2])
            let batteryLow = Int(b[3] >> 7)
            let test = Int((b[3] & 0x40) >> 6)
            let channel = Int((b[3] & 0x30) >> 4)
            let type = b[3] & 0x0f
            let raw = Int(b[4]) << 4 | Int(b[5] >> 4)
            let humidityOrDirection = Int(b[5] & 0x0f) << 8 | Int(b[6])
            switch type {
            case 1:
                reports.append(ISMReport([
                    "model": "LaCrosse-TX141W", "id": .int(id), "channel": .int(channel), "battery_ok": .int(batteryLow == 0 ? 1 : 0),
                    "temperature_C": .float(Float(raw - 500) * 0.1), "humidity": .int(humidityOrDirection),
                    "test": .int(test), "mic": "CRC",
                ]))
            case 2:
                reports.append(ISMReport([
                    "model": "LaCrosse-TX141W", "id": .int(id), "channel": .int(channel), "battery_ok": .int(batteryLow == 0 ? 1 : 0),
                    "wind_avg_km_h": .float(Float(raw) * 0.1), "wind_dir_deg": .int(humidityOrDirection),
                    "test": .int(test), "mic": "CRC",
                ]))
            default:
                return DecodeStatus.failOther
            }
            return 1
        }

        let id = Int(b[0])
        let batteryLow = kind == .tx141th ? Int(b[1] >> 7) : (b[1] >> 7 == 0 ? 1 : 0)
        let test = (b[1] & 0x40) >> 6 != 0 ? "Yes" : "No"
        let channel = Int((b[1] & 0x30) >> 4)
        let temperature = Float((Int(b[1] & 0x0f) << 8 | Int(b[2])) - 500) * 0.1
        let humidity = kind == .tx141th ? Int(b[3]) : 0
        if id == 0 || (kind == .tx141th && (humidity == 0 || humidity > 100)) || temperature < -40.0 || temperature > 140.0 {
            return DecodeStatus.failSanity
        }

        switch kind {
        case .tx141b:
            reports.append(ISMReport([
                "model": "LaCrosse-TX141B", "id": .int(id), "temperature_C": .float(temperature),
                "battery_ok": .int(batteryLow == 0 ? 1 : 0), "test": .string(test),
            ]))
        case .tx141:
            reports.append(ISMReport([
                "model": "LaCrosse-TX141Bv2", "id": .int(id), "channel": .int(channel), "temperature_C": .float(temperature),
                "battery_ok": .int(batteryLow == 0 ? 1 : 0), "test": .string(test),
            ]))
        case .tx141bv3:
            reports.append(ISMReport([
                "model": "LaCrosse-TX141Bv3", "id": .int(id), "channel": .int(channel),
                "battery_ok": .int(batteryLow == 0 ? 1 : 0), "temperature_C": .float(temperature), "test": .string(test),
            ]))
        default:
            if BitUtil.lfsrDigest8Reflect(b.bytes(4), generator: 0x31, key: 0xf4) != b[4] { return DecodeStatus.failMIC }
            reports.append(ISMReport([
                "model": "LaCrosse-TX141THBv2", "id": .int(id), "channel": .int(channel),
                "battery_ok": .int(batteryLow == 0 ? 1 : 0), "temperature_C": .float(temperature),
                "humidity": .int(humidity), "test": .string(test), "mic": "CRC",
            ]))
        }
        return 1
    }
}
