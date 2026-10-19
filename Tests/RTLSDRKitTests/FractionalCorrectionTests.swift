// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRKit

/// Sub-ppm crystal corrections (SH-3). The demodulator's correction register resolves about 0.06 ppm, but the whole-ppm
/// setter threw away a measured 0.4 ppm; these pin the parts-per-billion path and show that it agrees with the ppm one
/// where both apply.
struct FractionalCorrectionTests {

    @Test func aWholePartsPerMillionGivesTheSameRegisterWordAsBefore() {
        for ppm in [-488, -5, -1, 0, 1, 5, 488] {
            let ppb = RTL2832U.frequencyCorrectionWord(partsPerBillion: ppm * 1000)
            let old = RTL2832U.frequencyCorrectionWord(ppm: ppm)
            #expect(ppb.low == old.low && ppb.high == old.high, "ppm \(ppm)")
        }
    }

    /// The demodulator's register is 14 bits, two's complement (the top two bits of the high byte are not used).
    private func signed14(_ word: (low: UInt8, high: UInt8)) -> Int {
        let raw = Int(word.high & 0x3f) << 8 | Int(word.low)
        return raw >= 0x2000 ? raw - 0x4000 : raw
    }

    @Test func aSubPPMCorrectionIsNotRoundedAwayInTheRegister() {
        let word = RTL2832U.frequencyCorrectionWord(partsPerBillion: 400)      // 0.4 ppm: -6.7 counts, truncated to -6
        #expect(word != RTL2832U.frequencyCorrectionWord(partsPerBillion: 0))
        #expect(signed14(word) == -6)
        let negative = RTL2832U.frequencyCorrectionWord(partsPerBillion: -400)
        #expect(signed14(negative) == 6)
    }

    @Test func thePLLCrystalFollowsTheSubPPMCorrectionToTheWholeHertz() {
        // 28.8 MHz at +0.4 ppm is 28 800 011.52 Hz, truncated like the reference driver truncates.
        #expect(RTL2832U.correctedCrystal(28_800_000, partsPerBillion: 400) == 28_800_011)
        #expect(RTL2832U.correctedCrystal(28_800_000, partsPerBillion: 0) == 28_800_000)
        #expect(RTL2832U.correctedCrystal(28_800_000, ppm: 5) == RTL2832U.correctedCrystal(28_800_000, partsPerBillion: 5_000))
    }

    @Test func theDeviceAcceptsAFractionOfAPPMAndKeepsIt() throws {
        let fake = RecordingTransport()
        let device = try RTLSDRDevice(transport: fake)
        try device.setFrequencyCorrection(partsPerBillion: 400)
        #expect(device.frequencyCorrectionPartsPerBillion == 400)
        #expect(device.frequencyCorrectionPPM == 0, "the whole-ppm view rounds toward zero")
        try device.setFrequencyCorrection(ppm: -5)
        #expect(device.frequencyCorrectionPartsPerBillion == -5_000)
        #expect(device.frequencyCorrectionPPM == -5)
    }

    @Test func theDeviceRefusesCorrectionsBeyondTheRegister() throws {
        let fake = RecordingTransport()
        let device = try RTLSDRDevice(transport: fake)
        #expect(throws: RTLSDRError.frequencyCorrectionOutOfRange(488_001)) {
            try device.setFrequencyCorrection(partsPerBillion: 488_001)
        }
        #expect(throws: RTLSDRError.frequencyCorrectionOutOfRange(-488_001)) {
            try device.setFrequencyCorrection(partsPerBillion: -488_001)
        }
        #expect(device.frequencyCorrectionPartsPerBillion == 0, "a refused correction changes nothing")
    }
}
