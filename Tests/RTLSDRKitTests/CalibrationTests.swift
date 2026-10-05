// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRKit

struct CalibrationRecordTests {
    private let record = CalibrationRecord(partsPerBillion: -23_456, measured: Date(timeIntervalSince1970: 1_790_000_000),
                                           referenceHz: 596_309_441, method: .knownCarrier, label: "roof antenna")

    @Test func aRecordRoundTrips() throws {
        let bytes = try record.encoded()
        #expect(Array(bytes.prefix(6)) == [0x52, 0x54, 0x4c, 0x43, 1, UInt8(bytes.count - 8)])
        #expect(CalibrationRecord(decoding: bytes[...]) == record)
        #expect(record.ppm == -23.456)
        // Only the correction is required.
        let bare = CalibrationRecord(partsPerBillion: 5)
        #expect(CalibrationRecord(decoding: try bare.encoded()[...]) == bare)
    }

    @Test func theCRCCatchesDamage() throws {
        var bytes = try record.encoded()
        bytes[7] ^= 0x01
        #expect(CalibrationRecord(decoding: bytes[...]) == nil)
        #expect(CalibrationRecord.crc(Array("123456789".utf8)) == 0x29b1)          // CRC-16/CCITT-FALSE check value
    }

    @Test func fieldsFromALaterVersionAreSkipped() throws {
        var bytes = Array(try CalibrationRecord(partsPerBillion: 1_500).encoded().dropLast(2))
        bytes += [9, 3, 0xaa, 0xbb, 0xcc]                  // an unknown field type
        bytes[5] = UInt8(bytes.count - 6)
        bytes[4] = 2                                       // a later version
        let crc = CalibrationRecord.crc(bytes)
        bytes += [UInt8(crc >> 8), UInt8(crc & 0xff)]
        #expect(CalibrationRecord(decoding: bytes[...])?.partsPerBillion == 1_500)
    }

    @Test func aRecordThatDoesNotFitIsRefused() {
        let long = CalibrationRecord(partsPerBillion: 0, label: String(repeating: "x", count: 120))
        #expect(throws: RTLSDRError.self) { try long.encoded() }
        let huge = CalibrationRecord(partsPerBillion: 0, label: String(repeating: "é", count: 200))   // 400 bytes: no crash
        #expect(throws: RTLSDRError.self) { try huge.encoded() }
    }

    @Test func aRecordCutShortCanBeClearedOrRewritten() throws {
        var bytes = try EEPROMImage(bytes: RecordingTransport.genericEEPROM)!.replacingCalibration(record).bytes
        for offset in 0x90..<0x100 { bytes[offset] = 0xff }          // the write stopped at 0x90
        let image = EEPROMImage(bytes: bytes)!
        #expect(image.calibrationArea == .damagedRecord)
        #expect(try image.replacingCalibration(record).calibration == record)
        #expect(try image.replacingCalibration(nil).calibrationArea == .unused)
    }

    @Test func onlyTheFreeAreaChanges() throws {
        let generic = EEPROMImage(bytes: RecordingTransport.genericEEPROM)!
        #expect(generic.calibrationArea == .unused)
        let stored = try generic.replacingCalibration(record)
        #expect(stored.calibration == record)
        #expect(stored.differences(from: generic).allSatisfy { CalibrationRecord.area.contains($0) })
        #expect(try stored.replacingCalibration(nil) == generic)      // cleared: all 0xff again
    }

    @Test func dataThatIsNotARecordIsNotOverwritten() {
        var bytes = RecordingTransport.genericEEPROM
        bytes[0x90] = 0x12                                 // a vendor's own use of the area, say
        let image = EEPROMImage(bytes: bytes)!
        #expect(image.calibrationArea == .foreign)
        #expect(throws: RTLSDRError.self) { try image.replacingCalibration(record) }
    }

    @Test func theDeviceStoresAndReadsBack() throws {
        let fake = RecordingTransport()
        let device = try RTLSDRDevice(transport: fake)
        #expect(try device.readCalibration() == nil)
        let backup = try device.writeCalibration(record)
        #expect(backup.bytes == RecordingTransport.genericEEPROM)
        #expect(try device.readCalibration() == record)
        #expect(Array(fake.eeprom[0..<0x80]) == Array(RecordingTransport.genericEEPROM[0..<0x80]))
        try device.writeCalibration(nil)
        #expect(fake.eeprom == RecordingTransport.genericEEPROM)
    }
}
