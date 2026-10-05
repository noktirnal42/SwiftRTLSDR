// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A frequency calibration kept on the dongle itself, in the EEPROM's unused second half (offsets 0x80-0xff), so that
/// it travels with the hardware. The format is this package's own:
///
///     0x80  "RTLC" (52 54 4c 43)      0x84  version (1)      0x85  length n of the fields that follow
///     0x86  fields: type, length, value (all little-endian); a reader skips the types it does not know
///     then  CRC-16/CCITT (0x1021, from 0xffff) of everything from 0x80, high byte first
///
/// Fields: 1 the correction in parts per billion (Int32); 2 when it was measured (Unix seconds, UInt32); 3 the
/// reference it was measured against (hertz, UInt64); 4 how (UInt8: 0 entered by hand, 1 a known carrier); 5 a label
/// (UTF-8, such as "roof antenna"). The record is written only where the area is unused (all 0xff, as the RTL2832U
/// dongles ship) or holds such a record already, so whatever a vendor may keep there is never overwritten.
public struct CalibrationRecord: Sendable, Equatable {
    public enum Method: UInt8, Sendable {
        case entered = 0
        case knownCarrier = 1
    }

    /// The bytes the record may occupy.
    public static let area = 0x80..<0x100
    static let magic: [UInt8] = [0x52, 0x54, 0x4c, 0x43]
    static let version: UInt8 = 1

    /// The crystal's error in parts per billion, as `setFrequencyCorrection(ppm:)` takes it: positive when the crystal
    /// runs fast (signals then appear below where they are).
    public var partsPerBillion: Int
    public var measured: Date?
    public var referenceHz: UInt64?
    public var method: Method?
    public var label: String?

    public init(partsPerBillion: Int, measured: Date? = nil, referenceHz: UInt64? = nil, method: Method? = nil, label: String? = nil) {
        self.partsPerBillion = partsPerBillion
        self.measured = measured
        self.referenceHz = referenceHz
        self.method = method
        self.label = label
    }

    public var ppm: Double { Double(partsPerBillion) / 1000 }

    /// The record's bytes, from offset 0x80. Throws if it does not fit (a label of more than about 90 bytes).
    public func encoded() throws -> [UInt8] {
        func little<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
            (0..<(T.bitWidth / 8)).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        }
        var fields: [UInt8] = []
        func add(_ type: UInt8, _ value: [UInt8]) throws {
            guard value.count <= Self.area.count else { throw RTLSDRError.calibrationRecord("a field of \(value.count) bytes does not fit") }
            fields += [type, UInt8(value.count)] + value
        }
        guard let ppb = Int32(exactly: partsPerBillion) else { throw RTLSDRError.calibrationRecord("the correction is out of range") }
        try add(1, little(ppb))
        if let measured { try add(2, little(UInt32(clamping: Int(measured.timeIntervalSince1970)))) }
        if let referenceHz { try add(3, little(referenceHz)) }
        if let method { try add(4, [method.rawValue]) }
        if let label, !label.isEmpty { try add(5, Array(label.utf8)) }
        var bytes = Self.magic + [Self.version, UInt8(truncatingIfNeeded: fields.count)] + fields
        guard bytes.count + 2 <= Self.area.count, fields.count <= 255 else {
            throw RTLSDRError.calibrationRecord("the record is \(bytes.count + 2) bytes; the area holds \(Self.area.count)")
        }
        let crc = Self.crc(bytes)
        bytes += [UInt8(crc >> 8), UInt8(crc & 0xff)]
        return bytes
    }

    /// Reads a record from the area's bytes; nil if there is none (or it is damaged).
    public init?(decoding area: ArraySlice<UInt8>) {
        let bytes = Array(area)
        guard bytes.count >= 8, Array(bytes[0..<4]) == Self.magic, bytes[4] >= 1 else { return nil }
        let length = Int(bytes[5])
        guard 6 + length + 2 <= bytes.count else { return nil }
        let crc = UInt16(bytes[6 + length]) << 8 | UInt16(bytes[7 + length])
        guard Self.crc(Array(bytes[0..<(6 + length)])) == crc else { return nil }
        var index = 6, ppb: Int?
        func little(_ value: ArraySlice<UInt8>) -> UInt64 {
            value.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        partsPerBillion = 0
        while index + 2 <= 6 + length {
            let type = bytes[index], size = Int(bytes[index + 1])
            guard index + 2 + size <= 6 + length else { return nil }
            let value = bytes[(index + 2)..<(index + 2 + size)]
            switch (type, size) {
            case (1, 4): ppb = Int(Int32(truncatingIfNeeded: little(value)))
            case (2, 4): measured = Date(timeIntervalSince1970: TimeInterval(little(value)))
            case (3, 8): referenceHz = little(value)
            case (4, 1): method = Method(rawValue: value.first!)
            case (5, _): label = String(decoding: value, as: UTF8.self)
            default: break                                  // a field from a later version
            }
            index += 2 + size
        }
        guard let ppb else { return nil }
        partsPerBillion = ppb
    }

    /// CRC-16/CCITT-FALSE: polynomial 0x1021, initial 0xffff, no reflection.
    static func crc(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? crc << 1 ^ 0x1021 : crc << 1 }
        }
        return crc
    }
}

extension EEPROMImage {
    /// What the unused second half holds.
    public enum CalibrationArea: Sendable, Equatable {
        /// All 0xff, as dongles ship.
        case unused
        case record(CalibrationRecord)
        /// A record of this format that does not check out (a write cut short, say): it may be cleared or rewritten.
        case damagedRecord
        /// Something else: this driver will not write there.
        case foreign
    }

    public var calibrationArea: CalibrationArea {
        let area = bytes[CalibrationRecord.area]
        if area.allSatisfy({ $0 == 0xff }) { return .unused }
        if let record = CalibrationRecord(decoding: area) { return .record(record) }
        if Array(area.prefix(4)) == CalibrationRecord.magic { return .damagedRecord }
        return .foreign
    }

    public var calibration: CalibrationRecord? {
        if case .record(let record) = calibrationArea { return record }
        return nil
    }

    /// A copy holding `record` (nil: the area returned to all 0xff). Nothing outside 0x80-0xff changes, and an area
    /// holding anything but unused bytes or a calibration record is refused.
    public func replacingCalibration(_ record: CalibrationRecord?) throws -> EEPROMImage {
        if calibrationArea == .foreign {
            throw RTLSDRError.calibrationRecord("offsets 0x80-0xff hold data this driver does not recognise; it will not overwrite them")
        }
        var bytes = self.bytes
        let encoded = try record?.encoded() ?? []
        for offset in CalibrationRecord.area {
            let index = offset - CalibrationRecord.area.lowerBound
            bytes[offset] = index < encoded.count ? encoded[index] : 0xff
        }
        return EEPROMImage(bytes: bytes)!
    }
}

extension RTLSDRDevice {
    /// The calibration stored on this dongle, if any.
    public func readCalibration() throws -> CalibrationRecord? {
        try readEEPROM().calibration
    }

    /// Stores `record` on the dongle (nil removes it), verified by reading back; returns the EEPROM as it was before.
    /// Only offsets 0x80-0xff are written, and only if they are unused or hold a calibration record already.
    /// **Untested on hardware**, like every EEPROM write: try it on a dongle you can afford to lose first.
    @discardableResult
    public func writeCalibration(_ record: CalibrationRecord?) throws -> EEPROMImage {
        try withControl {
            let before = try readEEPROM()
            try writeEEPROM(try before.replacingCalibration(record))
            return before
        }
    }
}
