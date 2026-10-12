// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRKit

/// `readIdentity()` (SH-8): one read-only value for the app. Nothing here may write the EEPROM.
struct DongleIdentityTests {

    private func open(_ fake: RecordingTransport) throws -> RTLSDRDevice {
        try RTLSDRDevice(transport: fake)
    }

    /// The generic dongle's image with `record` stored in the free area.
    private func imageWith(_ record: CalibrationRecord?) throws -> [UInt8] {
        try EEPROMImage(bytes: RecordingTransport.genericEEPROM)!.replacingCalibration(record).bytes
    }

    @Test func aDongleWithNoCalibrationReportsNilAndUnused() throws {
        let fake = RecordingTransport()
        let device = try open(fake)
        let identity = try device.readIdentity()
        #expect(identity.manufacturer == "Realtek")
        #expect(identity.product == "RTL2838UHIDIR")
        #expect(identity.serial == "00000001")
        #expect(identity.hasSignature && identity.serialEnabled)
        #expect(identity.calibration == nil)
        #expect(identity.calibrationArea == .unused, "all 0xff in the free area, as dongles ship")
        #expect(identity.hexDump.split(separator: "\n").count == 16)
    }

    @Test func aStoredRecordGivesItsPPMAndWhatItWasMeasuredAgainst() throws {
        let measured = Date(timeIntervalSince1970: 1_790_000_000)
        let record = CalibrationRecord(partsPerBillion: -1_500, measured: measured, referenceHz: 19_000, method: .knownCarrier, label: "roof")
        let fake = RecordingTransport()
        fake.eeprom = try imageWith(record)
        let identity = try open(fake).readIdentity()
        #expect(identity.calibration == record)
        #expect(identity.calibration?.ppm == -1.5)
        #expect(identity.calibrationArea == .record(record))
    }

    @Test func aDamagedRecordIsSaidSoNotReadAsAValue() throws {
        let record = CalibrationRecord(partsPerBillion: 900)
        var bytes = try imageWith(record)
        let last = CalibrationRecord.area.lowerBound + (try record.encoded().count) - 1
        bytes[last] ^= 0xff                                  // the last byte is the record's checksum: now it does not check out
        let fake = RecordingTransport()
        fake.eeprom = bytes
        let identity = try open(fake).readIdentity()
        #expect(identity.calibration == nil)
        #expect(identity.calibrationArea == .damagedRecord)
    }

    @Test func foreignDataInTheFreeAreaIsReportedAndNotDecoded() throws {
        var bytes = RecordingTransport.genericEEPROM
        bytes[0x80] = 0x12                                   // not "RTLC", not 0xff: someone else's data
        let fake = RecordingTransport()
        fake.eeprom = bytes
        let identity = try open(fake).readIdentity()
        #expect(identity.calibration == nil)
        #expect(identity.calibrationArea == .foreign)
    }

    @Test func readingTheIdentityWritesNothingToTheEEPROM() throws {
        let fake = RecordingTransport()
        let device = try open(fake)
        let before = fake.transfers.count
        _ = try device.readIdentity()
        let after = fake.transfers.dropFirst(before)
        // An EEPROM data write is a two-byte transfer to address 0xa0; the one-byte pointer set is a read setup, not a write.
        #expect(after.filter { $0.isWrite && $0.value == 0xa0 && $0.data.count == 2 }.isEmpty)
        #expect(after.contains { !$0.isWrite }, "the bytes were read from the dongle")
    }

    @Test func malformedStringsGiveNilNamesRatherThanAGuess() throws {
        var bytes = RecordingTransport.genericEEPROM
        bytes[9] = 0x00                                      // the manufacturer descriptor has no length
        let fake = RecordingTransport()
        fake.eeprom = bytes
        let identity = try open(fake).readIdentity()
        #expect(identity.manufacturer == nil)
        #expect(identity.product == nil)
        #expect(identity.serial == nil)
        #expect(identity.calibrationArea == .unused, "the free area is still reported")
    }
}
