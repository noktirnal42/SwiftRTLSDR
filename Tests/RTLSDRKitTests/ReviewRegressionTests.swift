// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRKit

/// Regression tests for findings from the review of the section 6 work.
struct KitRegressionTests {
    @Test func frequencyCorrectionsTheRegisterCannotHoldAreRefusedWithoutTouchingHardware() throws {
        let fake = RecordingTransport()
        let device = try RTLSDRDevice(transport: fake)
        let before = fake.transfers.count
        for ppm in [489, -489, 1_000_000, -1_000_000, -1_000_001, Int(Int32.max), Int(Int32.min)] {
            #expect(throws: RTLSDRError.frequencyCorrectionOutOfRange(ppm)) { try device.setFrequencyCorrection(ppm: ppm) }
        }
        #expect(fake.transfers.count == before)
        try device.setFrequencyCorrection(ppm: 488)
        try device.setFrequencyCorrection(ppm: -488)
        #expect(device.frequencyCorrectionPPM == -488)
    }

    @Test func theLimitIsWhereTheCorrectionWordStillFits() {
        // 14 bits signed: the word for ±488 ppm is within ±8191; one more ppm is not.
        let offset = { (ppm: Int) in Int((Double(ppm) * -16_777_216.0 / 1_000_000).rounded(.towardZero)) }
        #expect(abs(offset(488)) <= 8191 && abs(offset(489)) > 8191)
    }

    @Test func aFailedLatchReadAfterASoftResetDoesNotLeaveTheBusThoughtOpen() throws {
        let fake = RecordingTransport()
        let device = try RTLSDRDevice(transport: fake)
        try device.setRetuneShortcuts(.keepTunerBusOpen)
        try device.setSampleRate(2_048_000)
        try device.setCenterFrequency(100_000_000)
        // The soft reset's first write reaches the chip (clearing the repeater bit), then its latch read fails.
        fake.failReadAfterWrite = (0x0120, 0x0011, [0x14])
        #expect(throws: RTLSDRError.usb("injected read failure")) { try device.setSampleRate(1_024_000) }
        try device.setCenterFrequency(100_025_000)
        #expect(tunerAccessWhileBusClosed(fake.transfers) == [], "the bus must be reopened before the next tuner access")
    }

    @Test func stoppingTheGainControlFromItsOwnCallbackDoesNotDeadlock() throws {
        let fake = RecordingTransport()
        let device = try RTLSDRDevice(transport: fake)
        let changes = Collected<Int>()
        let box = ControlBox()
        let control = try HostGainControl(device: device, configuration: .overloadGuard(ceilingTenthsDB: 496), onChange: { change in
            box.control?.stop()                          // runs on the control's own queue
            changes.append(change.toTenthsDB)
        })
        box.control = control
        let clipping = SampleStatistics((0..<4096).map { $0 % 2 == 0 ? 0 : 255 })
        control.observe(clipping)
        #expect(changes.wait(for: 1))
        for _ in 0..<5 { control.observe(clipping) }
        control.stop()                                   // and from outside, afterwards
        #expect(changes.values == [434], "stopped after the first change")
    }

    @Test func theReportedGainIsTheAppliedOneEvenWhenAChangeFails() throws {
        let fake = RecordingTransport()
        let device = try RTLSDRDevice(transport: fake)
        let errors = Collected<String>()
        let control = try HostGainControl(device: device, configuration: .overloadGuard(ceilingTenthsDB: 496),
                                          onError: { errors.append("\($0)") })
        device.close()
        control.observe(SampleStatistics((0..<4096).map { $0 % 2 == 0 ? 0 : 255 }))
        #expect(errors.wait(for: 1))
        #expect(control.gainTenthsDB == 496, "the change to 43.4 dB never happened")
    }
}

final class ControlBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HostGainControl?
    var control: HostGainControl? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
