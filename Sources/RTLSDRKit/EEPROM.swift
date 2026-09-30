// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The contents of a dongle's configuration EEPROM: 256 bytes that the RTL2832U reads at power-up for its USB IDs,
/// its manufacturer/product/serial strings and two flags.
///
/// Layout (from `rtl_eeprom.c` in librtlsdr; see PROVENANCE.md):
///
///     0-1   0x28 0x32 signature        6   0xa5 = report a serial number
///     2-3   vendor ID, little-endian   7   flags: bit 0 remote wakeup, bit 1 IR endpoint
///     4-5   product ID, little-endian  8   (0x02 in the reference's images)
///     9...  three USB string descriptors (length, 0x03, UTF-16LE text): manufacturer, product, serial,
///           which must end before offset 78 (the reference's limit; it keeps the IR configuration length at 78)
///
/// This type only parses and edits; `RTLSDRDevice.readEEPROM()` and `writeEEPROM(_:)` move it to and from a dongle.
public struct EEPROMImage: Sendable, Equatable {
    public static let size = 256
    /// Bytes 0...8 hold the USB IDs and flags. A bad write here can make the dongle unrecognisable, so this driver never
    /// writes them.
    public static let protectedHeader = 0..<9
    static let stringsStart = 9
    static let stringsLimit = 78

    public struct Strings: Sendable, Equatable {
        public var manufacturer: String
        public var product: String
        public var serial: String
    }

    public private(set) var bytes: [UInt8]

    /// nil unless `bytes` holds exactly 256 bytes.
    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.size else { return nil }
        self.bytes = bytes
    }

    public var hasSignature: Bool { bytes[0] == 0x28 && bytes[1] == 0x32 }
    public var vendorID: UInt16 { UInt16(bytes[2]) | UInt16(bytes[3]) << 8 }
    public var productID: UInt16 { UInt16(bytes[4]) | UInt16(bytes[5]) << 8 }
    /// Whether the dongle reports a serial number at all.
    public var serialEnabled: Bool { bytes[6] == 0xa5 }
    public var remoteWakeup: Bool { bytes[7] & 0x01 != 0 }
    /// Set on the tested generic dongle. The RTL-SDR Blog driver takes this flag as "force the bias tee on"; this
    /// driver does not.
    public var irEndpointEnabled: Bool { bytes[7] & 0x02 != 0 }

    private static func hex(_ value: Int) -> String { String(format: "0x%02x", value) }

    /// Where each string descriptor starts and ends (end exclusive).
    private func descriptorRanges() throws -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var position = Self.stringsStart
        for name in ["manufacturer", "product", "serial"] {
            guard position + 1 < Self.stringsLimit else { throw RTLSDRError.eepromMalformed("no room for the \(name) string") }
            let length = Int(bytes[position])
            guard bytes[position + 1] == 0x03 else {
                throw RTLSDRError.eepromMalformed("the \(name) string descriptor at \(Self.hex(position)) has type \(Self.hex(Int(bytes[position + 1]))), not 0x03")
            }
            guard length >= 2, length % 2 == 0, position + length <= Self.stringsLimit else {
                throw RTLSDRError.eepromMalformed("the \(name) string descriptor at \(Self.hex(position)) has an impossible length (\(length))")
            }
            ranges.append(position..<position + length)
            position += length
        }
        return ranges
    }

    public func strings() throws -> Strings {
        let text = try descriptorRanges().map { range -> String in
            let units = stride(from: range.lowerBound + 2, to: range.upperBound, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
            return String(decoding: units, as: UTF16.self)
        }
        return Strings(manufacturer: text[0], product: text[1], serial: text[2])
    }

    /// The longest serial that fits after the current manufacturer and product strings.
    public func maximumSerialLength() throws -> Int {
        let ranges = try descriptorRanges()
        return (Self.stringsLimit - ranges[1].upperBound - 2) / 2
    }

    /// A copy with a new serial number. Only the serial descriptor changes: the header (IDs and flags), the other two
    /// strings and everything from offset 78 on stay byte for byte as they were.
    ///
    /// The serial must be 1 or more printable ASCII characters without spaces, and must fit before offset 78. A dongle
    /// whose EEPROM does not enable the serial (byte 6) is refused, because enabling it would mean writing the header.
    public func replacingSerial(_ serial: String) throws -> EEPROMImage {
        guard hasSignature else { throw RTLSDRError.eepromMalformed("the signature (0x28 0x32) is missing") }
        guard serialEnabled else { throw RTLSDRError.eepromMalformed("this EEPROM does not enable a serial number (byte 6 is not 0xa5)") }
        let ascii = Array(serial.utf8)
        guard !ascii.isEmpty, ascii.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            throw RTLSDRError.invalidSerial("a serial must be printable ASCII without spaces: \(serial.debugDescription)")
        }
        let ranges = try descriptorRanges()
        let maximum = (Self.stringsLimit - ranges[1].upperBound - 2) / 2
        guard ascii.count <= maximum else {
            throw RTLSDRError.invalidSerial("\(serial) is \(ascii.count) characters; this EEPROM has room for \(maximum)")
        }
        var copy = self
        let start = ranges[2].lowerBound
        copy.bytes[start] = UInt8(2 + 2 * ascii.count)
        copy.bytes[start + 1] = 0x03
        for (index, character) in ascii.enumerated() {
            copy.bytes[start + 2 + 2 * index] = character
            copy.bytes[start + 3 + 2 * index] = 0x00
        }
        return copy
    }

    /// Offsets at which the two images differ.
    public func differences(from other: EEPROMImage) -> [Int] {
        bytes.indices.filter { bytes[$0] != other.bytes[$0] }
    }

    /// The classic 16-bytes-per-line hex dump.
    public var hexDump: String {
        stride(from: 0, to: Self.size, by: 16).map { row in
            String(format: "%02x: ", row) + bytes[row..<row + 16].map { String(format: "%02x", $0) }.joined(separator: " ")
        }.joined(separator: "\n")
    }
}

extension RTLSDRDevice {
    /// I2C address of the EEPROM, on the RTL2832U's own bus (not behind the tuner's repeater).
    static let eepromAddress: UInt8 = 0xa0

    /// Reads all 256 bytes (one I2C read per byte, as the reference does).
    public func readEEPROM() throws -> EEPROMImage {
        try withControl {
            try chip.withI2CRepeaterOff {
                try chip.i2cWrite(address: Self.eepromAddress, bytes: [0])
                var bytes: [UInt8] = []
                bytes.reserveCapacity(EEPROMImage.size)
                for _ in 0..<EEPROMImage.size {
                    guard let byte = try chip.i2cRead(address: Self.eepromAddress, length: 1).first else {
                        throw RTLSDRError.shortTransfer(expected: 1, actual: 0)
                    }
                    bytes.append(byte)
                }
                return EEPROMImage(bytes: bytes)!
            }
        }
    }

    /// Writes `image`: only the bytes that differ from what the EEPROM holds now, one at a time with a 5 ms pause
    /// (some EEPROMs need it), then reads the whole EEPROM back and checks every byte. Returns the offsets written.
    ///
    /// Refuses any change to the header (offsets 0...8: USB IDs and flags). **Untested on hardware**: try it on a
    /// dongle you can afford to lose, keep the backup, and replug the dongle afterwards for the change to show.
    @discardableResult
    public func writeEEPROM(_ image: EEPROMImage) throws -> [Int] {
        try withControl {
            let current = try readEEPROM()
            let changed = image.differences(from: current)
            if let offset = changed.first(where: { EEPROMImage.protectedHeader.contains($0) }) {
                throw RTLSDRError.eepromHeaderProtected(offset: offset)
            }
            try chip.withI2CRepeaterOff {
                for offset in changed {
                    try chip.i2cWrite(address: Self.eepromAddress, bytes: [UInt8(offset), image.bytes[offset]])
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            let readBack = try readEEPROM()
            let wrong = image.differences(from: readBack)
            guard wrong.isEmpty else { throw RTLSDRError.eepromVerifyFailed(offsets: wrong) }
            return changed
        }
    }

    /// Gives this dongle a new serial number (see `EEPROMImage.replacingSerial`), verified by reading back.
    /// Returns the EEPROM as it was before, to keep as a backup. The new serial shows after the dongle is replugged.
    @discardableResult
    public func setSerialNumber(_ serial: String) throws -> EEPROMImage {
        try withControl {
            let before = try readEEPROM()
            try writeEEPROM(try before.replacingSerial(serial))
            return before
        }
    }
}
