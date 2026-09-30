// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// An RTL-SDR dongle (RTL2832U + Rafael Micro R820T tuner), driven natively.
///
/// Typical use:
///
///     let device = try RTLSDRDevice.openFirst()
///     try device.setSampleRate(2_048_000)
///     try device.setCenterFrequency(100_000_000)
///     try device.setAutomaticGain()
///     try device.startStreaming { samples in /* interleaved unsigned 8-bit I, Q, I, Q ... */ }
///
/// Not thread-safe for configuration: call the setters from one thread at a time (streaming runs on its own thread).
public final class RTLSDRDevice: @unchecked Sendable {

    public enum Tuner: String, Sendable { case r820t = "Rafael Micro R820T" }

    /// The range this driver accepts, taken from the reference driver's tuning table. The oscillator locked at every
    /// 5 MHz step from 24 to 1765 MHz on the one dongle tested; the frequency it actually produced was not measured.
    public static let tunableRange: ClosedRange<Int> = 24_000_000...1_766_000_000

    /// The gain settings the tuner offers, in tenths of a dB (so 496 = 49.6 dB).
    public static var supportedGainsTenthsDB: [Int] { R820T.gainSteps }

    public let info: RTLSDRDeviceInfo?
    public let tuner: Tuner

    public private(set) var sampleRate: Double = 0
    public private(set) var centerFrequency: Int = 0
    /// nil while automatic gain is on.
    public private(set) var tunerGainTenthsDB: Int?
    public private(set) var frequencyCorrectionPPM: Int = 0
    /// False if the last retune could not lock the oscillator (samples are then off-frequency).
    public private(set) var pllLocked = true
    /// The tuner oscillator's sub-band after the last retune (a diagnostic; see the README on level differences).
    public private(set) var tunerVCOBandCode = 0

    private let transport: RTLSDRTransport
    private let chip: RTL2832U
    private let r820t: R820T
    private let stateLock = NSLock()
    private var closed = false

    // MARK: Opening

    #if canImport(IOUSBHost)
    /// Dongles that are plugged in right now.
    public static func connectedDevices() -> [RTLSDRDeviceInfo] {
        USBRegistry.connectedDongles()
    }

    public static func open(_ info: RTLSDRDeviceInfo) throws -> RTLSDRDevice {
        try RTLSDRDevice(transport: TracingTransport.fromEnvironment(IOUSBHostTransport(info: info)), info: info)
    }

    /// Opens the dongle with `serial`, or the first one when `serial` is nil.
    public static func openFirst(serial: String? = nil) throws -> RTLSDRDevice {
        let devices = connectedDevices()
        guard !devices.isEmpty else { throw RTLSDRError.noDeviceFound }
        if let serial {
            guard let match = devices.first(where: { $0.serial == serial }) else { throw RTLSDRError.deviceNotFound(serial: serial) }
            return try open(match)
        }
        return try open(devices[0])
    }
    #endif

    /// Starts a session on an already-open transport (used by tests, and by anything that brings its own USB layer).
    init(transport: RTLSDRTransport, info: RTLSDRDeviceInfo? = nil) throws {
        self.transport = transport
        self.info = info
        chip = RTL2832U(transport: transport)

        try chip.writeRegister(.usb, RTL2832U.USB.systemControl, 0x09)      // first write doubles as a liveness check
        try chip.initializeBaseband()

        // Identify the tuner. The repeater has to stay on for all tuner access, so init happens in the same block.
        let bus: RTL2832U = chip
        var foundTuner: R820T?
        try chip.withI2CRepeater {
            let identity = try bus.i2cReadRegister(address: R820T.i2cAddress, register: R820T.identityRegister)
            guard identity == R820T.identityValue else { return }
            let tuner = R820T(bus: bus)
            try bus.configureForLowIFTuner(intermediateFrequencyHz: 3_570_000)
            try tuner.initialize()
            foundTuner = tuner
        }
        guard let foundTuner else {
            transport.close()
            throw RTLSDRError.unsupportedTuner
        }
        r820t = foundTuner
        tuner = .r820t
    }

    deinit { close() }

    // MARK: Settings

    /// Sets the sample rate; returns the rate actually produced (it is derived from the 28.8 MHz crystal).
    @discardableResult
    public func setSampleRate(_ rate: Int) throws -> Double {
        guard RTL2832U.resamplerSettings(sampleRate: rate) != nil else { throw RTLSDRError.invalidSampleRate(rate) }
        // The tuner's IF filter follows the sample rate; the demodulator then has to mix the new IF to zero.
        let intermediate = try chip.withI2CRepeater { try r820t.setBandwidth(rate) }
        try chip.setIntermediateFrequency(intermediate)
        if centerFrequency > 0 { try retune() }
        let actual = try chip.setSampleRate(rate, correctionPPM: frequencyCorrectionPPM)
        sampleRate = actual
        return actual
    }

    public func setCenterFrequency(_ hertz: Int) throws {
        guard Self.tunableRange.contains(hertz) else { throw RTLSDRError.frequencyOutOfRange(hertz) }
        centerFrequency = hertz
        try retune()
    }

    private func retune() throws {
        try chip.withI2CRepeater { try r820t.setFrequency(centerFrequency) }
        pllLocked = r820t.pllLocked
        tunerVCOBandCode = r820t.vcoBandCode
    }

    public func setAutomaticGain() throws {
        try chip.withI2CRepeater { try r820t.setGain(manual: false) }
        tunerGainTenthsDB = nil
    }

    /// Manual gain, in tenths of a dB; the nearest setting the tuner can make is used.
    public func setTunerGain(tenthsDB: Int) throws {
        try chip.withI2CRepeater { try r820t.setGain(manual: true, gainTenthsDB: tenthsDB) }
        tunerGainTenthsDB = tenthsDB
    }

    /// Corrects the crystal's error (positive = the crystal runs fast). Takes effect immediately.
    public func setFrequencyCorrection(ppm: Int) throws {
        try chip.setFrequencyCorrection(ppm: ppm)
        frequencyCorrectionPPM = ppm
        // The tuner's oscillator runs from the same crystal, so its PLL arithmetic must use the corrected value.
        r820t.setCrystalFrequency(UInt64(chip.correctedCrystalHz))
        if centerFrequency > 0 { try retune() }
    }

    /// Powers an antenna amplifier through the coax on dongles with a bias tee wired to GPIO 0 (the RTL-SDR Blog V3).
    /// On other dongles this toggles a pin that goes nowhere.
    public func setBiasTee(_ on: Bool) throws {
        try chip.setGPIOOutput(0)
        try chip.setGPIO(0, high: on)
    }

    // MARK: Samples

    /// Reads `byteCount` bytes of interleaved unsigned 8-bit I/Q and returns them (not while streaming).
    public func readSamples(byteCount: Int) throws -> [UInt8] {
        let collector = SampleCollector(target: byteCount)
        try startStreaming(
            onError: { collector.fail($0) },
            handler: { collector.append($0) }
        )
        defer { stopStreaming() }
        // The data arrives at the sample rate; allow generous slack for the first buffers and for a busy machine.
        let expected = Double(byteCount) / max(1, sampleRate * 2)
        return try collector.wait(timeout: expected + 3)
    }

    /// Delivers samples (interleaved unsigned 8-bit I, Q, I, Q ...) to `handler` until `stopStreaming()`.
    ///
    /// Blocks are `blockSize` bytes, with `bufferCount` requests kept queued so the dongle's FIFO never overflows.
    /// `handler` runs on a USB completion queue: return quickly (copy or enqueue the data), never call
    /// `stopStreaming()` from it, and don't keep the buffer. `onError` fires once if the stream dies by itself.
    public func startStreaming(
        blockSize: Int = 65_536,
        bufferCount: Int = 8,
        onError: (@Sendable (Error) -> Void)? = nil,
        handler: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !closed else { throw RTLSDRError.closed }
        guard !transport.isStreaming else { throw RTLSDRError.alreadyStreaming }
        try chip.resetStreamBuffer()                       // drop stale samples left in the dongle's FIFO
        try transport.startBulkStream(bufferSize: blockSize, bufferCount: bufferCount, handler: handler, onError: onError ?? { _ in })
    }

    public func stopStreaming() {
        transport.stopBulkStream()
    }

    public func close() {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        stateLock.unlock()
        transport.stopBulkStream()
        try? chip.withI2CRepeater { try r820t.standby() }
        try? chip.powerDown()
        transport.close()
    }
}

/// Gathers streamed blocks until enough bytes have arrived.
private final class SampleCollector: @unchecked Sendable {
    private let target: Int
    private let condition = NSCondition()
    private var bytes: [UInt8] = []
    private var failure: Error?

    init(target: Int) {
        self.target = target
        bytes.reserveCapacity(target)
    }

    func append(_ block: UnsafeBufferPointer<UInt8>) {
        condition.lock()
        if bytes.count < target { bytes.append(contentsOf: block.prefix(target - bytes.count)) }
        condition.broadcast()
        condition.unlock()
    }

    func fail(_ error: Error) {
        condition.lock()
        failure = error
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval) throws -> [UInt8] {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while bytes.count < target {
            if let failure { throw failure }
            if !condition.wait(until: deadline) { throw RTLSDRError.usb("timed out waiting for samples (\(bytes.count) of \(target) bytes)") }
        }
        return bytes
    }
}
