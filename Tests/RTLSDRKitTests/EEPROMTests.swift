// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRKit

struct EEPROMImageTests {
    private let generic = EEPROMImage(bytes: RecordingTransport.genericEEPROM)!

    @Test func theGenericDongleImageParses() throws {
        #expect(generic.hasSignature && generic.vendorID == 0x0bda && generic.productID == 0x2838)
        #expect(generic.serialEnabled && generic.irEndpointEnabled && !generic.remoteWakeup)
        #expect(try generic.strings() == EEPROMImage.Strings(manufacturer: "Realtek", product: "RTL2838UHIDIR", serial: "00000001"))
        #expect(try generic.maximumSerialLength() == 11)
    }

    @Test func onlyWholeImagesAreAccepted() {
        #expect(EEPROMImage(bytes: [UInt8](repeating: 0, count: 255)) == nil)
    }

    @Test func aNewSerialChangesOnlyTheSerialDescriptor() throws {
        let updated = try generic.replacingSerial("ROOF-0001")
        #expect(try updated.strings() == EEPROMImage.Strings(manufacturer: "Realtek", product: "RTL2838UHIDIR", serial: "ROOF-0001"))
        let serialStart = 9 + 16 + 28
        for offset in updated.differences(from: generic) {
            #expect((serialStart..<78).contains(offset), "offset \(offset) is outside the serial descriptor")
        }
        #expect(Array(updated.bytes[0..<serialStart]) == Array(generic.bytes[0..<serialStart]), "header and other strings untouched")
        #expect(Array(updated.bytes[78...]) == Array(generic.bytes[78...]), "nothing from offset 78 on")
    }

    @Test func aSerialOneCharacterDifferentIsAOneByteChange() throws {
        #expect(try generic.replacingSerial("00000002").differences(from: generic) == [9 + 16 + 28 + 2 + 14])
    }

    @Test func aShorterSerialStillParses() throws {
        #expect(try generic.replacingSerial("A1").strings().serial == "A1")
    }

    @Test func serialsThatDoNotFitOrAreNotPlainASCIIAreRefused() {
        #expect(throws: RTLSDRError.self) { try generic.replacingSerial("ABCDEFGHIJKL") }          // 12 > 11
        #expect(throws: RTLSDRError.self) { try generic.replacingSerial("") }
        #expect(throws: RTLSDRError.self) { try generic.replacingSerial("has space") }
        #expect(throws: RTLSDRError.self) { try generic.replacingSerial("Ünïcode") }
        #expect(throws: Never.self) { try generic.replacingSerial("ABCDEFGHIJK") }
    }

    @Test func anEEPROMThatDoesNotEnableTheSerialIsRefused() {
        var bytes = RecordingTransport.genericEEPROM
        bytes[6] = 0x00
        #expect(throws: RTLSDRError.eepromMalformed("this EEPROM does not enable a serial number (byte 6 is not 0xa5)")) {
            try EEPROMImage(bytes: bytes)!.replacingSerial("X1")
        }
    }

    @Test func malformedContentsAreReportedNotGuessed() {
        var bytes = RecordingTransport.genericEEPROM
        bytes[10] = 0x04                                   // manufacturer descriptor type
        #expect(throws: RTLSDRError.self) { try EEPROMImage(bytes: bytes)!.strings() }
        var blank = [UInt8](repeating: 0xff, count: 256)
        #expect(throws: RTLSDRError.self) { try EEPROMImage(bytes: blank)!.strings() }
        blank[0] = 0x28
        #expect(throws: RTLSDRError.self) { try EEPROMImage(bytes: blank)!.replacingSerial("X1") }
    }

    @Test func theHexDumpHasSixteenRowsOfSixteen() {
        let lines = generic.hexDump.split(separator: "\n")
        #expect(lines.count == 16 && lines[0].hasPrefix("00: 28 32 da 0b 38 28 a5 16 02"))
    }
}

struct EEPROMDeviceTests {
    private func open(_ fake: RecordingTransport = RecordingTransport()) throws -> (RTLSDRDevice, RecordingTransport) {
        (try RTLSDRDevice(transport: fake), fake)
    }

    private func eepromWrites(_ transfers: ArraySlice<Transfer>) -> [[UInt8]] {
        transfers.filter { $0.isWrite && $0.value == 0xa0 && $0.data.count == 2 }.map(\.data)
    }

    @Test func readingReturnsTheWholeEEPROM() throws {
        let (device, fake) = try open()
        let before = fake.transfers.count
        #expect(try device.readEEPROM().bytes == RecordingTransport.genericEEPROM)
        let transfers = fake.transfers[before...]
        #expect(transfers.first?.isWrite == true && transfers.first?.data == [0], "points at offset 0 first")
        #expect(transfers.filter { !$0.isWrite && $0.value == 0xa0 }.count == 256, "one read per byte, like the reference")
        #expect(eepromWrites(transfers).isEmpty, "reading writes nothing")
    }

    @Test func settingASerialWritesOnlyTheChangedBytesAndVerifies() throws {
        let (device, fake) = try open()
        let before = fake.transfers.count
        let backup = try device.setSerialNumber("00000002")
        #expect(backup.bytes == RecordingTransport.genericEEPROM)
        #expect(eepromWrites(fake.transfers[before...]) == [[UInt8(9 + 16 + 28 + 2 + 14), 0x32]])
        #expect(try EEPROMImage(bytes: fake.eeprom)!.strings().serial == "00000002")
    }

    @Test func theHeaderIsNeverWritten() throws {
        let (device, fake) = try open()
        var bytes = RecordingTransport.genericEEPROM
        bytes[4] = 0x32                                    // would turn 0bda:2838 into 0bda:2832
        bytes[40] = 0x41
        let before = fake.transfers.count
        #expect(throws: RTLSDRError.eepromHeaderProtected(offset: 4)) { try device.writeEEPROM(EEPROMImage(bytes: bytes)!) }
        #expect(eepromWrites(fake.transfers[before...]).isEmpty, "nothing at all is written")
        #expect(fake.eeprom == RecordingTransport.genericEEPROM)
    }

    @Test func aWriteThatDoesNotStickIsReported() throws {
        let fake = RecordingTransport()
        let serialEnd = 9 + 16 + 28 + 2 + 14
        fake.stuckEEPROMOffsets = [serialEnd]
        let (device, _) = try open(fake)
        #expect(throws: RTLSDRError.eepromVerifyFailed(offsets: [serialEnd])) { try device.setSerialNumber("00000009") }
    }

    @Test func theFreeAreaCanBeWritten() throws {
        let (device, fake) = try open()
        var bytes = RecordingTransport.genericEEPROM
        bytes[0x80] = 0x53
        bytes[0x81] = 0x52
        #expect(try device.writeEEPROM(EEPROMImage(bytes: bytes)!) == [0x80, 0x81])
        #expect(fake.eeprom[0x80...0x82] == [0x53, 0x52, 0xff])
    }

    @Test func eepromAccessHappensWithTheTunerBusClosedAndTuningStillWorksAfter() throws {
        let (device, fake) = try open()
        try device.setRetuneShortcuts(.keepTunerBusOpen)
        try device.setSampleRate(2_048_000)
        try device.setCenterFrequency(100_000_000)
        _ = try device.readEEPROM()
        try device.setCenterFrequency(100_025_000)

        var repeaterOn = false
        for transfer in fake.transfers {
            if transfer.isWrite, transfer.value == 0x0120, transfer.index == 0x0011 { repeaterOn = transfer.data[0] & 0x08 != 0 }
            if transfer.value == 0xa0, transfer.index >> 8 == 6 { #expect(!repeaterOn, "EEPROM traffic with the repeater on") }
        }
        #expect(tunerAccessWhileBusClosed(fake.transfers) == [])
    }

    @Test func aClosedDeviceRefusesEEPROMAccess() throws {
        let (device, _) = try open()
        device.close()
        #expect(throws: RTLSDRError.closed) { try device.readEEPROM() }
        #expect(throws: RTLSDRError.closed) { try device.setSerialNumber("X1") }
    }
}
