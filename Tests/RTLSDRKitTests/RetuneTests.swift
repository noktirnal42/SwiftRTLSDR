// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRKit

/// Indexes of tuner transfers (I2C address 0x34) made while the repeater bit (demodulator page 1, 0x01, bit 3) was off.
/// The tuner is unreachable then: such a write would silently go nowhere on real hardware.
func tunerAccessWhileBusClosed(_ transfers: [Transfer]) -> [Int] {
    var repeaterOn = false
    var found: [Int] = []
    for (position, transfer) in transfers.enumerated() {
        if transfer.isWrite, transfer.value == 0x0120, transfer.index == 0x0011 { repeaterOn = (transfer.data.first ?? 0) & 0x08 != 0 }
        if transfer.index >> 8 == 6, transfer.value == 0x34, !repeaterOn { found.append(position) }
    }
    return found
}

struct RetuneTests {
    private func tunedDevice(_ shortcuts: RTLSDRDevice.RetuneShortcuts = []) throws -> (RTLSDRDevice, RecordingTransport) {
        let fake = RecordingTransport()
        let device = try RTLSDRDevice(transport: fake)
        try device.setRetuneShortcuts(shortcuts)
        try device.setSampleRate(2_048_000)
        try device.setCenterFrequency(100_000_000)
        return (device, fake)
    }

    /// Control transfers for one retune within the same band, once the shortcuts have warmed up.
    private func transfersPerSameBandRetune(_ shortcuts: RTLSDRDevice.RetuneShortcuts) throws -> Int {
        let (device, fake) = try tunedDevice(shortcuts)
        try device.setCenterFrequency(100_025_000)
        let before = fake.transfers.count
        try device.setCenterFrequency(100_050_000)
        return fake.transfers.count - before
    }

    @Test func theReferenceSequenceCostsElevenTransfersPerRetune() throws {
        // Repeater on (write + latch read), autotune step, status read (pointer + read), PLL registers, lock read
        // (pointer + read), autotune step, repeater off (write + latch read). The band registers are already skipped
        // when they would not change.
        #expect(try transfersPerSameBandRetune([]) == 11)
    }

    @Test func eachShortcutSavesWhatItClaims() throws {
        #expect(try transfersPerSameBandRetune(.keepTunerBusOpen) == 7)
        #expect(try transfersPerSameBandRetune(.reuseVCOStatus) == 9)
        #expect(try transfersPerSameBandRetune(.all) == 5)
    }

    @Test func aBandChangeOnlyAddsTheRegistersThatChange() throws {
        let (device, fake) = try tunedDevice(.all)
        try device.setCenterFrequency(100_025_000)
        let before = fake.transfers.count
        try device.setCenterFrequency(150_000_000)
        // Register writes carry data after the register byte; a lone byte only points the tuner at its status.
        let tunerWrites = fake.transfers[before...].filter { $0.isWrite && $0.value == 0x34 && $0.data.count > 1 }.map { $0.data.first! }
        #expect(tunerWrites == [0x1b, 0x1a, 0x10, 0x1a], "tracking filter, autotune step, PLL, autotune step")
    }

    @Test(arguments: [RTLSDRDevice.RetuneShortcuts(), .keepTunerBusOpen, .reuseVCOStatus, .all])
    func theTunerIsNeverAddressedWhileItsBusIsClosed(shortcuts: RTLSDRDevice.RetuneShortcuts) throws {
        // A sequence that exercises every path that touches the repeater register, including the soft reset that a
        // sample-rate change does (it clears the repeater bit as a side effect).
        let (device, fake) = try tunedDevice(shortcuts)
        try device.setCenterFrequency(433_920_000)
        try device.setSampleRate(1_024_000)
        try device.setCenterFrequency(433_945_000)
        try device.setTunerGain(tenthsDB: 297)
        try device.setFrequencyCorrection(ppm: 3)
        try device.setSampleRate(2_400_000)
        try device.setAutomaticGain()
        try device.setRetuneShortcuts([])
        try device.setCenterFrequency(1_090_000_000)
        try device.setRetuneShortcuts(shortcuts)
        try device.setCenterFrequency(162_550_000)
        device.close()
        #expect(tunerAccessWhileBusClosed(fake.transfers) == [])
    }

    @Test func turningTheBusShortcutOffClosesTheBusAtOnce() throws {
        let (device, fake) = try tunedDevice(.keepTunerBusOpen)
        #expect(RegisterFile(fake.transfers).demod[256 + 0x01] == 0x18, "kept open after the retune")
        try device.setRetuneShortcuts([])
        #expect(RegisterFile(fake.transfers).demod[256 + 0x01] == 0x10)
    }

    @Test func closingLeavesTheBusClosedEvenWhenItWasKeptOpen() throws {
        let (device, fake) = try tunedDevice(.keepTunerBusOpen)
        device.close()
        #expect(RegisterFile(fake.transfers).demod[256 + 0x01] == 0x10)
        #expect(fake.writes.last?.value == 0x3000 && fake.writes.last?.data == [0x20], "demodulator still powered down last")
    }

    @Test(arguments: GoldenTraceTests.sessions)
    func shortcutsLeaveTheSameRegistersAsTheReference(session: GoldenTraceTests.Session) throws {
        let fake = RecordingTransport()
        let device = try RTLSDRDevice(transport: fake)
        try device.setRetuneShortcuts(.all)
        try device.setSampleRate(session.rate)
        try device.setCenterFrequency(session.frequency)
        if let gain = session.gainTenthsDB { try device.setTunerGain(tenthsDB: gain) } else { try device.setAutomaticGain() }
        if session.ppm != 0 { try device.setFrequencyCorrection(ppm: session.ppm) }
        try device.startStreaming { _ in }

        // At stream start the only allowed difference is the repeater bit, which the shortcut leaves on.
        var atStart = RegisterFile(fake.transfers, upTo: isBufferReset)
        #expect(atStart.demod[256 + 0x01] == 0x18)
        atStart.demod[256 + 0x01] = 0x10
        let startDifferences = atStart.differences(from: RegisterFile(try goldenTrace(named: session.name), upTo: isBufferReset))
        #expect(startDifferences.isEmpty, "\(startDifferences.joined(separator: "\n"))")

        device.stopStreaming()
        device.close()
        let finalDifferences = RegisterFile(fake.transfers).differences(from: RegisterFile(try goldenTrace(named: session.name)))
        #expect(finalDifferences.isEmpty, "\(finalDifferences.joined(separator: "\n"))")
    }

    @Test func reusedVCOStatusComesFromTheLastLockCheck() throws {
        let (device, fake) = try tunedDevice(.reuseVCOStatus)
        try device.setCenterFrequency(100_025_000)             // warms up the cache from a five-byte lock read
        #expect(fake.transfers.last(where: { !$0.isWrite && $0.value == 0x34 })?.data.count == 5)

        // A fine-tune reading of 3 (above the reference value 2) would nudge the divider down by one. The cached value
        // from the lock check (2) is what the next retune uses, so the divider stays put.
        fake.tunerStatus[4] = 0x1f                             // bit-reversed: fine tune = 3
        let before = fake.transfers.count
        try device.setCenterFrequency(100_050_000)
        let pllWrite = try #require(fake.transfers[before...].first { $0.isWrite && $0.value == 0x34 && $0.data.first == 0x10 })
        #expect(pllWrite.data[1] >> 5 == 4, "divider exponent for 100 MHz without a nudge")
        let reads = fake.transfers[before...].filter { !$0.isWrite && $0.value == 0x34 }.map(\.data.count)
        #expect(reads == [5], "no status read before programming, only the lock check")
    }

    @Test func aFailedLockForgetsTheReusedStatus() throws {
        let (device, fake) = try tunedDevice(.reuseVCOStatus)
        try device.setCenterFrequency(100_025_000)
        fake.tunerStatus[2] = 0xfd                             // lock flag clear after bit reversal
        try device.setCenterFrequency(100_050_000)
        #expect(!device.pllLocked)
        fake.tunerStatus[2] = 0x1f
        let before = fake.transfers.count
        try device.setCenterFrequency(100_075_000)
        let reads = fake.transfers[before...].filter { !$0.isWrite && $0.value == 0x34 }.map(\.data.count)
        #expect(reads == [5, 5], "status read again before programming, then the lock check")
    }

    @Test func withoutShortcutsTheLockCheckReadsThreeBytesLikeTheReference() throws {
        let (device, fake) = try tunedDevice()
        let before = fake.transfers.count
        try device.setCenterFrequency(100_025_000)
        let reads = fake.transfers[before...].filter { !$0.isWrite && $0.value == 0x34 }.map(\.data.count)
        #expect(reads == [5, 3])
    }
}
