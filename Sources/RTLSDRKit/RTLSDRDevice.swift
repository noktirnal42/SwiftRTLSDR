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
/// Thread-safe: settings can be changed from any thread (calls are serialised, one control sequence at a time), which
/// lets a gain loop or a network client adjust a stream that someone else started. The streaming handler runs on its
/// own queue and must not call back into the device.
public final class RTLSDRDevice: @unchecked Sendable {

    public enum Tuner: String, Sendable { case r820t = "Rafael Micro R820T" }

    /// The range this driver accepts, taken from the reference driver's tuning table. The oscillator locked at every
    /// 5 MHz step from 24 to 1765 MHz on the one dongle tested; the frequency it actually produced was not measured.
    public static let tunableRange: ClosedRange<Int> = 24_000_000...1_766_000_000

    /// The gain settings the tuner offers, in tenths of a dB (so 496 = 49.6 dB).
    public static var supportedGainsTenthsDB: [Int] { R820T.gainSteps }

    /// Ways to make a retune cheaper than the reference driver's sequence, which costs 11 control transfers when the
    /// band does not change. None is on by default. **Neither has been tried on hardware yet**: measure lock and
    /// retune time with `rtlsdr-tool retunebench` before relying on them.
    public struct RetuneShortcuts: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Leave the RTL2832U's I2C repeater (the gate to the tuner's bus) on between tuner accesses instead of
        /// switching it on and off around each one. Saves 4 transfers per retune. The reference always switches it off
        /// again; whether leaving it on affects reception is not known.
        public static let keepTunerBusOpen = RetuneShortcuts(rawValue: 1 << 0)
        /// Take the VCO fine-tune bits that choose the PLL divider from the previous retune's lock check instead of
        /// reading the tuner's status again first. Saves 2 transfers per retune. Differs from the reference only if
        /// those bits change between the lock and the next retune.
        public static let reuseVCOStatus = RetuneShortcuts(rawValue: 1 << 1)

        public static let all: RetuneShortcuts = [.keepTunerBusOpen, .reuseVCOStatus]
    }

    public let info: RTLSDRDeviceInfo?
    public let tuner: Tuner

    /// What the setters last established. Read and written only under `controlLock`.
    private struct Settings {
        var sampleRate: Double = 0
        var centerFrequency = 0
        var tunerGainTenthsDB: Int?
        var frequencyCorrectionPPM = 0
        var pllLocked = true
        var tunerVCOBandCode = 0
        var retuneShortcuts: RetuneShortcuts = []
    }
    private var settings = Settings()

    public var sampleRate: Double { withLock { settings.sampleRate } }
    public var centerFrequency: Int { withLock { settings.centerFrequency } }
    /// nil while automatic gain is on.
    public var tunerGainTenthsDB: Int? { withLock { settings.tunerGainTenthsDB } }
    public var frequencyCorrectionPPM: Int { withLock { settings.frequencyCorrectionPPM } }
    /// False if the last retune could not lock the oscillator (samples are then off-frequency).
    public var pllLocked: Bool { withLock { settings.pllLocked } }
    /// The tuner oscillator's sub-band after the last retune (a diagnostic; see the README on level differences).
    public var tunerVCOBandCode: Int { withLock { settings.tunerVCOBandCode } }
    public var retuneShortcuts: RetuneShortcuts { withLock { settings.retuneShortcuts } }

    private let transport: RTLSDRTransport
    let chip: RTL2832U
    private let r820t: R820T
    /// Serialises every control-transfer sequence and guards `settings` and `closed`. Recursive because some public
    /// calls are built from others.
    private let controlLock = NSRecursiveLock()
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
    #else
    /// The only USB backend is macOS's IOUSBHost; elsewhere the package builds (so its logic can be tested) but finds no dongles.
    public static func connectedDevices() -> [RTLSDRDeviceInfo] { [] }

    public static func open(_ info: RTLSDRDeviceInfo) throws -> RTLSDRDevice {
        throw RTLSDRError.openFailed("this platform has no USB backend (only macOS's IOUSBHost is implemented)")
    }
    #endif

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

    // MARK: Serialisation

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        controlLock.lock()
        defer { controlLock.unlock() }
        return try body()
    }

    /// Runs a control sequence with the device to itself; refuses once the device is closed.
    func withControl<T>(_ body: () throws -> T) throws -> T {
        try withLock {
            guard !closed else { throw RTLSDRError.closed }
            return try body()
        }
    }

    // MARK: Settings

    /// Sets the sample rate; returns the rate actually produced (it is derived from the 28.8 MHz crystal).
    @discardableResult
    public func setSampleRate(_ rate: Int) throws -> Double {
        guard RTL2832U.resamplerSettings(sampleRate: rate) != nil else { throw RTLSDRError.invalidSampleRate(rate) }
        return try withControl {
            // The tuner's IF filter follows the sample rate; the demodulator then has to mix the new IF to zero.
            let intermediate = try chip.withI2CRepeater { try r820t.setBandwidth(rate) }
            try chip.setIntermediateFrequency(intermediate)
            if settings.centerFrequency > 0 { try retune() }
            let actual = try chip.setSampleRate(rate, correctionPPM: settings.frequencyCorrectionPPM)
            settings.sampleRate = actual
            return actual
        }
    }

    public func setCenterFrequency(_ hertz: Int) throws {
        guard Self.tunableRange.contains(hertz) else { throw RTLSDRError.frequencyOutOfRange(hertz) }
        try withControl {
            settings.centerFrequency = hertz
            try retune()
        }
    }

    /// Caller holds `controlLock`.
    private func retune() throws {
        try chip.withI2CRepeater { try r820t.setFrequency(settings.centerFrequency) }
        settings.pllLocked = r820t.pllLocked
        settings.tunerVCOBandCode = r820t.vcoBandCode
    }

    /// Turns retune shortcuts on or off (see `RetuneShortcuts`). Turning `keepTunerBusOpen` off closes the bus now.
    public func setRetuneShortcuts(_ shortcuts: RetuneShortcuts) throws {
        try withControl {
            try chip.keepRepeaterOn(shortcuts.contains(.keepTunerBusOpen))
            r820t.reusesVCOStatus = shortcuts.contains(.reuseVCOStatus)
            settings.retuneShortcuts = shortcuts
        }
    }

    public func setAutomaticGain() throws {
        try withControl {
            try chip.withI2CRepeater { try r820t.setGain(manual: false) }
            settings.tunerGainTenthsDB = nil
        }
    }

    /// Manual gain, in tenths of a dB; the nearest setting the tuner can make is used.
    public func setTunerGain(tenthsDB: Int) throws {
        try withControl {
            try chip.withI2CRepeater { try r820t.setGain(manual: true, gainTenthsDB: tenthsDB) }
            settings.tunerGainTenthsDB = tenthsDB
        }
    }

    /// The corrections the demodulator can hold: its register is 14 bits signed, at 2^24 / 10^6 counts per ppm.
    public static let frequencyCorrectionRange: ClosedRange<Int> = -488...488

    /// Corrects the crystal's error (positive = the crystal runs fast). Takes effect immediately.
    public func setFrequencyCorrection(ppm: Int) throws {
        guard Self.frequencyCorrectionRange.contains(ppm) else { throw RTLSDRError.frequencyCorrectionOutOfRange(ppm) }
        try withControl {
            try chip.setFrequencyCorrection(ppm: ppm)
            settings.frequencyCorrectionPPM = ppm
            // The tuner's oscillator runs from the same crystal, so its PLL arithmetic must use the corrected value.
            r820t.setCrystalFrequency(UInt64(chip.correctedCrystalHz))
            if settings.centerFrequency > 0 { try retune() }
        }
    }

    /// Powers an antenna amplifier through the coax on dongles with a bias tee wired to GPIO 0 (the RTL-SDR Blog V3).
    /// On other dongles this toggles a pin that goes nowhere.
    public func setBiasTee(_ on: Bool) throws {
        try withControl {
            try chip.setGPIOOutput(0)
            try chip.setGPIO(0, high: on)
        }
    }

    // MARK: Samples

    /// Reads `byteCount` bytes of interleaved unsigned 8-bit I/Q and returns them (not while streaming). The stream
    /// starts afresh, so every byte was sampled after the call began. Short reads finish sooner with a smaller
    /// `blockSize` (a multiple of 512), because a block is only delivered once it is full.
    public func readSamples(byteCount: Int, blockSize: Int = 65_536) throws -> [UInt8] {
        let collector = SampleCollector(target: byteCount)
        try startStreaming(
            blockSize: blockSize,
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
    /// `handler` runs on a USB completion queue: return quickly (copy or enqueue the data), never call back into the
    /// device from it, and don't keep the buffer. `onError` fires once if the stream dies by itself.
    public func startStreaming(
        blockSize: Int = 65_536,
        bufferCount: Int = 8,
        onError: (@Sendable (Error) -> Void)? = nil,
        handler: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void
    ) throws {
        try withControl {
            guard !transport.isStreaming else { throw RTLSDRError.alreadyStreaming }
            try chip.resetStreamBuffer()                       // drop stale samples left in the dongle's FIFO
            try transport.startBulkStream(bufferSize: blockSize, bufferCount: bufferCount, handler: handler, onError: onError ?? { _ in })
        }
    }

    public var isStreaming: Bool { transport.isStreaming }

    public func stopStreaming() {
        transport.stopBulkStream()
    }

    public func close() {
        let first: Bool = withLock {
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        // Outside the lock: stopping waits for the last completion, which must not wait on us.
        transport.stopBulkStream()
        withLock {
            try? chip.withI2CRepeater { try r820t.standby() }
            try? chip.keepRepeaterOn(false)
            try? chip.powerDown()
            transport.close()
        }
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
