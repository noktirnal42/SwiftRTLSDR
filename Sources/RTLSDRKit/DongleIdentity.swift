// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// What the app shows about a dongle, in one read-only value (SH-8).
///
/// Built from `readEEPROM()` alone: the EEPROM is read byte by byte, one I2C read each, and no write function is called,
/// so asking for the identity cannot change the dongle. A nil name means the string descriptor was malformed (it is not
/// guessed); a nil `calibration` means nothing usable is stored, and `calibrationArea` says which of the cases it is.
public struct DongleIdentity: Sendable, Equatable {
    public var manufacturer: String?
    public var product: String?
    public var serial: String?
    /// The EEPROM begins with the 0x28 0x32 signature.
    public var hasSignature: Bool
    /// The dongle reports a serial number at all (EEPROM byte 6 is 0xa5).
    public var serialEnabled: Bool
    /// The stored calibration, when the free area holds a valid record.
    public var calibration: CalibrationRecord?
    /// What the free area (offsets 0x80-0xff) holds: unused, a record, a damaged record, or something foreign.
    public var calibrationArea: EEPROMImage.CalibrationArea
    /// The whole EEPROM as a hex dump, for display.
    public var hexDump: String

    public init(
        manufacturer: String?, product: String?, serial: String?, hasSignature: Bool, serialEnabled: Bool,
        calibration: CalibrationRecord?, calibrationArea: EEPROMImage.CalibrationArea, hexDump: String
    ) {
        self.manufacturer = manufacturer
        self.product = product
        self.serial = serial
        self.hasSignature = hasSignature
        self.serialEnabled = serialEnabled
        self.calibration = calibration
        self.calibrationArea = calibrationArea
        self.hexDump = hexDump
    }
}

extension RTLSDRDevice {
    /// Reads the dongle's identity and stored calibration. Read-only: it calls `readEEPROM()` and nothing that writes.
    public func readIdentity() throws -> DongleIdentity {
        let image = try readEEPROM()
        let strings = try? image.strings()
        return DongleIdentity(
            manufacturer: strings?.manufacturer,
            product: strings?.product,
            serial: strings?.serial,
            hasSignature: image.hasSignature,
            serialEnabled: image.serialEnabled,
            calibration: image.calibration,
            calibrationArea: image.calibrationArea,
            hexDump: image.hexDump
        )
    }
}
