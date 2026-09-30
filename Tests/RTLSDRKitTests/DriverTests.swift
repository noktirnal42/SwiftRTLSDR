// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRKit

// MARK: Pure computations, checked against values read from real rtl_sdr traffic

struct ComputationTests {
    /// The registers when the reference starts streaming (later, closing puts the tuner into standby).
    private func golden(_ name: String) throws -> RegisterFile { RegisterFile(try goldenTrace(named: name), upTo: isBufferReset) }

    @Test func resamplerRatiosMatchWhatRtlSdrWrites() throws {
        // (rate, golden trace) pairs; the ratio is written as two 16-bit words at demodulator page 1, 0x9f and 0xa1.
        let cases: [(Int, String)] = [
            (2_048_000, "fm-100M-2048k-g297"), (250_000, "uhf-433M-250k-auto"), (2_400_000, "adsb-1090M-2400k-g496"),
            (1_024_000, "voice-162M-1024k-g207-ppm5"), (3_200_000, "high-1700M-3200k-g372"), (1_200_000, "trunk-851M-1200k-g09"),
        ]
        for (rate, name) in cases {
            let file = try golden(name)
            let written = (UInt32(file.demod[256 + 0x9f]!) << 24) | (UInt32(file.demod[256 + 0xa0]!) << 16)
                | (UInt32(file.demod[256 + 0xa1]!) << 8) | UInt32(file.demod[256 + 0xa2]!)
            #expect(RTL2832U.resamplerSettings(sampleRate: rate)?.ratio == written, "rate \(rate)")
        }
    }

    @Test func resamplerReportsTheRateItReallyProduces() throws {
        let settings = try #require(RTL2832U.resamplerSettings(sampleRate: 2_048_000))
        #expect(abs(settings.actualRate - 2_048_000) < 0.01)
        let odd = try #require(RTL2832U.resamplerSettings(sampleRate: 1_000_000))
        #expect(abs(odd.actualRate - 1_000_000) < 5, "1 MS/s is not an exact divisor of the crystal; the achieved rate is within a few S/s")
    }

    @Test(arguments: [225_000, 100_000, 300_001, 500_000, 900_000, 3_200_001, 0, -5])
    func unavailableSampleRatesAreRejected(rate: Int) {
        #expect(RTL2832U.resamplerSettings(sampleRate: rate) == nil)
    }

    @Test(arguments: [225_001, 300_000, 900_001, 3_200_000])
    func edgeSampleRatesAreAccepted(rate: Int) {
        #expect(RTL2832U.resamplerSettings(sampleRate: rate) != nil)
    }

    @Test func intermediateFrequencyWordMatchesRtlSdr() throws {
        // The IF the tuner delivers for 2.048 MS/s (from its filter plan) and the word the reference writes for it.
        let file = try golden("fm-100M-2048k-g297")
        let intermediate = R820T.planBandwidth(2_048_000).intermediateFrequencyHz
        let word = RTL2832U.intermediateFrequencyWord(hz: intermediate)
        #expect([word.high, word.middle, word.low] == [file.demod[256 + 0x19]!, file.demod[256 + 0x1a]!, file.demod[256 + 0x1b]!])
        #expect([word.high, word.middle, word.low] == [0x3c, 0x63, 0x8f])
        // During start-up and calibration the IF is 3.57 MHz; the reference writes this word for it first.
        let startUp = RTL2832U.intermediateFrequencyWord(hz: 3_570_000)
        #expect([startUp.high, startUp.middle, startUp.low] == [0x38, 0x11, 0x12])
    }

    @Test func frequencyCorrectionWordMatchesRtlSdr() throws {
        let file = try golden("voice-162M-1024k-g207-ppm5")
        let word = RTL2832U.frequencyCorrectionWord(ppm: 5)
        #expect(word.low == file.demod[256 + 0x3f] && word.high == file.demod[256 + 0x3e])
        #expect(RTL2832U.frequencyCorrectionWord(ppm: 0) == (low: 0, high: 0))
        let negative = RTL2832U.frequencyCorrectionWord(ppm: -5)
        #expect(negative.low == 0x53 && negative.high == 0x00)
    }

    @Test func correctedCrystalTruncatesLikeRtlSdr() {
        #expect(RTL2832U.correctedCrystal(28_800_000, ppm: 0) == 28_800_000)
        #expect(RTL2832U.correctedCrystal(28_800_000, ppm: 5) == 28_800_144)
        #expect(RTL2832U.correctedCrystal(28_800_000, ppm: -5) == 28_799_856)
    }

    @Test func packedFIRMatchesWhatRtlSdrLoads() throws {
        let file = try golden("fm-100M-2048k-g297")
        let packed = try #require(RTL2832U.packedFIR(RTL2832U.defaultFIR))
        #expect(packed.count == 20)
        #expect(packed == (0..<20).map { file.demod[256 + 0x1c + $0]! })
    }

    @Test func packedFIRRefusesCoefficientsThatDoNotFit() {
        #expect(RTL2832U.packedFIR(Array(repeating: 0, count: 15)) == nil)
        #expect(RTL2832U.packedFIR([200] + Array(repeating: 0, count: 15)) == nil)          // first eight must fit a signed byte
        #expect(RTL2832U.packedFIR(Array(repeating: 0, count: 8) + [3000] + Array(repeating: 0, count: 7)) == nil)   // rest must fit 12 bits
    }

    @Test func gainStepsAreTheOnesARealDongleReports() {
        #expect(RTLSDRDevice.supportedGainsTenthsDB.count == 29)
        #expect(RTLSDRDevice.supportedGainsTenthsDB.first == 0 && RTLSDRDevice.supportedGainsTenthsDB.last == 496)
        #expect(RTLSDRDevice.supportedGainsTenthsDB == RTLSDRDevice.supportedGainsTenthsDB.sorted())
    }

    @Test func gainPlansMatchTheGainRegistersRtlSdrWrites() throws {
        for (name, gain) in [("fm-100M-2048k-g297", 297), ("adsb-1090M-2400k-g496", 496), ("voice-162M-1024k-g207-ppm5", 207),
                             ("high-1700M-3200k-g372", 372), ("trunk-851M-1200k-g09", 9)] {
            let file = try golden(name)
            let plan = R820T.planGain(gain)
            #expect(plan.lna == file.tuner[0x05]! & 0x0f, "LNA index for \(gain)")
            #expect(plan.mixer == file.tuner[0x07]! & 0x0f, "mixer index for \(gain)")
        }
    }

    @Test func bandwidthPlansMatchTheFilterRegistersRtlSdrWrites() throws {
        for (name, rate) in [("fm-100M-2048k-g297", 2_048_000), ("uhf-433M-250k-auto", 250_000), ("high-1700M-3200k-g372", 3_200_000),
                             ("voice-162M-1024k-g207-ppm5", 1_024_000)] {
            let file = try golden(name)
            let plan = R820T.planBandwidth(rate)
            #expect(plan.register0b == file.tuner[0x0b]!, "IF filter register 0x0b at \(rate) S/s")
            #expect(plan.register0a & 0x10 == file.tuner[0x0a]! & 0x10, "register 0x0a filter bit at \(rate) S/s")
        }
    }

    @Test func pllPlanRefusesFrequenciesAboveWhatTheVCOCanReach() {
        let registers: [UInt8] = [0x6c, 0x83, 0x80, 0x00, 0x0f, 0x00, 0xc0]
        #expect(R820T.planPLL(loFrequencyHz: 2_000_000_000, crystalHz: 28_800_000, currentRegisters: registers, vcoFineTune: 2) == nil)
        #expect(R820T.planPLL(loFrequencyHz: 103_570_000, crystalHz: 28_800_000, currentRegisters: registers, vcoFineTune: 2) != nil)
    }

    @Test func pllPlanForAFrequencyBelowRangeIsGarbageSoThePublicAPIMustRefuseIt() {
        // The arithmetic still yields a plan for 3.57 MHz (librtlsdr writes exactly such a plan in its failed start-up
        // retune), but the oscillator cannot lock to it. RTLSDRDevice.setCenterFrequency enforces the range instead.
        let registers: [UInt8] = [0x6c, 0x83, 0x80, 0x00, 0x0f, 0x00, 0xc0]
        #expect(R820T.planPLL(loFrequencyHz: 3_570_000, crystalHz: 28_800_000, currentRegisters: registers, vcoFineTune: 2)?.dividerBits == 0)
    }
}

// MARK: Tables

struct TableTests {
    @Test func tuningBandsAreOrderedAndCoverFromZero() {
        let starts = R820TTables.bands.map(\.startMHz)
        #expect(starts.first == 0 && starts.count == 21)
        #expect(starts == starts.sorted() && Set(starts).count == starts.count)
    }

    @Test func initialRegisterTableHasTheDocumentedShape() {
        #expect(R820TTables.initialRegisters.count == 27)
        #expect(R820TTables.initialRegisters.first == 0x83)
    }

    @Test func knownDeviceListHasNoDuplicatesAndTheTestedDongle() {
        let ids = KnownDevices.all.map { UInt32($0.vendorID) << 16 | UInt32($0.productID) }
        #expect(Set(ids).count == ids.count && ids.count == 42)
        #expect(KnownDevices.all.contains { $0.vendorID == 0x0bda && $0.productID == 0x2838 && $0.name == "Generic RTL2832U OEM" })
    }
}

// MARK: Behaviour on a fake dongle

struct DeviceBehaviourTests {
    private func openDevice(_ fake: RecordingTransport = RecordingTransport()) throws -> (RTLSDRDevice, RecordingTransport) {
        (try RTLSDRDevice(transport: fake), fake)
    }

    @Test func aDongleWithAnotherTunerIsRefusedAndReleased() {
        let fake = RecordingTransport()
        fake.tunerStatus[0] = 0x00                       // not an R820T
        #expect(throws: RTLSDRError.unsupportedTuner) { try RTLSDRDevice(transport: fake) }
        #expect(fake.closed, "a failed open must give the USB device back")
    }

    @Test func frequenciesOutsideTheTunableRangeAreRejectedWithoutTouchingHardware() throws {
        let (device, fake) = try openDevice()
        let before = fake.transfers.count
        for hertz in [0, 1, 23_999_999, 1_766_000_001, 5_000_000_000, -1] {
            #expect(throws: RTLSDRError.frequencyOutOfRange(hertz)) { try device.setCenterFrequency(hertz) }
        }
        #expect(fake.transfers.count == before)
        #expect(device.centerFrequency == 0)
    }

    @Test(arguments: [24_000_000, 100_000_000, 1_766_000_000])
    func frequenciesInsideTheRangeAreAccepted(hertz: Int) throws {
        let (device, _) = try openDevice()
        try device.setCenterFrequency(hertz)
        #expect(device.centerFrequency == hertz)
    }

    @Test func invalidSampleRatesAreRejectedWithoutTouchingHardware() throws {
        let (device, fake) = try openDevice()
        let before = fake.transfers.count
        #expect(throws: RTLSDRError.invalidSampleRate(500_000)) { try device.setSampleRate(500_000) }
        #expect(fake.transfers.count == before)
    }

    @Test func sampleRateReturnsWhatTheHardwareWillReallyProduce() throws {
        let (device, _) = try openDevice()
        let actual = try device.setSampleRate(2_048_000)
        #expect(abs(actual - 2_048_000) < 0.01 && device.sampleRate == actual)
    }

    @Test func retuningAfterASampleRateChangeKeepsTheFrequency() throws {
        let (device, fake) = try openDevice()
        try device.setSampleRate(2_048_000)
        try device.setCenterFrequency(100_000_000)
        try device.setSampleRate(1_024_000)
        #expect(device.centerFrequency == 100_000_000)
        let final = RegisterFile(fake.transfers)
        let reference = RegisterFile(try goldenTrace(named: "fm-100M-2048k-g297"))
        #expect(final.tuner[0x14] == reference.tuner[0x14], "the PLL still targets 100 MHz + IF after the rate change")
    }

    @Test func gainReadbackFollowsTheLastSetting() throws {
        let (device, _) = try openDevice()
        #expect(device.tunerGainTenthsDB == nil)
        try device.setTunerGain(tenthsDB: 297)
        #expect(device.tunerGainTenthsDB == 297)
        try device.setAutomaticGain()
        #expect(device.tunerGainTenthsDB == nil)
    }

    @Test func biasTeeDrivesGPIO0() throws {
        let (device, fake) = try openDevice()
        let before = fake.transfers.count
        try device.setBiasTee(true)
        let writes = fake.transfers[before...].filter(\.isWrite)
        #expect(writes.last?.value == 0x3001 && writes.last?.data == [1], "output register bit 0 set")
        #expect(writes.contains { $0.value == 0x3003 && $0.data == [1] }, "output enabled on pin 0")
        try device.setBiasTee(false)
        #expect(fake.writes.last?.value == 0x3001 && fake.writes.last?.data == [0])
    }

    @Test func streamingFlushesTheDongleFIFOFirst() throws {
        let (device, fake) = try openDevice()
        let before = fake.transfers.count
        try device.startStreaming { _ in }
        let fifoWrites = fake.transfers[before...].filter { $0.value == 0x2148 }
        #expect(fifoWrites.map(\.data) == [[0x10, 0x02], [0x00, 0x00]])
        device.stopStreaming()
    }

    @Test func aSecondStreamIsRefused() throws {
        let (device, _) = try openDevice()
        try device.startStreaming { _ in }
        #expect(throws: RTLSDRError.alreadyStreaming) { try device.startStreaming { _ in } }
        device.stopStreaming()
        try device.startStreaming { _ in }            // and works again after stopping
        device.stopStreaming()
    }

    @Test func stoppingWhenNotStreamingIsHarmless() throws {
        let (device, _) = try openDevice()
        device.stopStreaming()
        device.stopStreaming()
    }

    @Test func streamedBlocksReachTheHandlerInOrder() throws {
        let fake = RecordingTransport()
        let (device, _) = try openDevice(fake)
        let received = Received()
        try device.startStreaming { received.append(Array($0)) }
        fake.deliver([1, 2, 3])
        fake.deliver([4, 5])
        device.stopStreaming()
        #expect(received.blocks == [[1, 2, 3], [4, 5]])
    }

    @Test func readSamplesReturnsExactlyTheBytesAskedFor() throws {
        let fake = RecordingTransport()
        fake.blocksToDeliver = [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12]]
        let (device, _) = try openDevice(fake)
        try device.setSampleRate(2_048_000)
        #expect(try device.readSamples(byteCount: 10) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        #expect(!fake.isStreaming, "readSamples must stop the stream it started")
    }

    @Test func readSamplesReportsAStreamThatDiesInsteadOfHanging() throws {
        let fake = RecordingTransport()
        let (device, _) = try openDevice(fake)
        try device.setSampleRate(2_048_000)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { fake.fail(RTLSDRError.usb("unplugged")) }
        #expect(throws: RTLSDRError.usb("unplugged")) { try device.readSamples(byteCount: 1_000_000) }
        #expect(!fake.isStreaming)
    }

    @Test func closingPowersEverythingDownOnceAndBlocksFurtherStreaming() throws {
        let (device, fake) = try openDevice()
        device.close()
        #expect(fake.closed)
        #expect(fake.writes.last?.value == 0x3000 && fake.writes.last?.data == [0x20], "demodulator powered down last")
        let count = fake.transfers.count
        device.close()
        #expect(fake.transfers.count == count, "a second close does nothing")
        #expect(throws: RTLSDRError.closed) { try device.startStreaming { _ in } }
    }

    @Test func standbyLeavesTheTunerInItsLowPowerState() throws {
        let (device, fake) = try openDevice()
        device.close()
        let file = RegisterFile(fake.transfers)
        #expect([file.tuner[0x06], file.tuner[0x05], file.tuner[0x07]] == [0xb1, 0xa0, 0x3a])
    }

    @Test func aRetuneThatCannotLockIsReportedNotHidden() throws {
        let fake = RecordingTransport()
        fake.tunerStatus[2] = 0xfd                       // lock flag clear after bit reversal
        let (device, _) = try openDevice(fake)
        try device.setSampleRate(2_048_000)
        try device.setCenterFrequency(100_000_000)
        #expect(device.pllLocked == false)
    }
}

final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[UInt8]] = []
    func append(_ block: [UInt8]) { lock.lock(); storage.append(block); lock.unlock() }
    var blocks: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return storage }
}

// MARK: The trace logger

struct TracingTests {
    @Test func loggedSessionsParseBackToTheSameTransfers() throws {
        let fake = RecordingTransport()
        let pipe = Pipe()
        let tracing = TracingTransport(wrapping: fake, to: pipe.fileHandleForWriting)
        let device = try RTLSDRDevice(transport: tracing)
        try device.setSampleRate(2_048_000)
        try device.setCenterFrequency(100_000_000)
        device.close()
        try pipe.fileHandleForWriting.close()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(parseTrace(text) == fake.transfers)
    }

    @Test func traceLinesUseTheDocumentedFormat() throws {
        let fake = RecordingTransport()
        let pipe = Pipe()
        let tracing = TracingTransport(wrapping: fake, to: pipe.fileHandleForWriting)
        try tracing.vendorWrite(value: 0x2000, index: 0x0110, data: [0x09])
        _ = try tracing.vendorRead(value: 0x0120, index: 0x000a, length: 1)
        try pipe.fileHandleForWriting.close()
        let lines = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        #expect(lines == ["W 0x2000 0x0110 09", "R 0x0120 0x000a 1 -> 00"])
    }

    @Test func noTracingWithoutTheEnvironmentVariable() {
        let fake = RecordingTransport()
        #expect(TracingTransport.fromEnvironment(fake) === fake || ProcessInfo.processInfo.environment["RTLSDR_TRACE"] != nil)
    }
}
