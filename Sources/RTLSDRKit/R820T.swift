// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The Rafael Micro R820T tuner: a low-IF TV tuner that covers roughly 24-1766 MHz.
///
/// The chip is programmed over I2C (through the RTL2832U's repeater). Most of its registers are write-only, so the
/// driver keeps a shadow copy: it lets us change single bit-fields with a mask and skip writes that would change
/// nothing (I2C is slow). The status registers (PLL lock, VCO fine-tune, filter calibration result) are read back
/// bit-reversed, as the chip sends them least-significant bit first.
final class R820T {

    static let i2cAddress: UInt8 = 0x34
    static let identityRegister: UInt8 = 0x00
    static let identityValue: UInt8 = 0x69

    /// Where the shadow starts and how many registers it holds.
    private static let shadowStart = 5
    private static let shadowCount = 30
    private static let maxMessageLength = 8                       // register byte + up to 7 data bytes per I2C message
    private static let firmwareVersion: UInt8 = 49

    /// Crystal-load capacitor choices, ordered as they are tried during a crystal check.
    enum CrystalCap { case low30pF, low20pF, low10pF, low0pF, high0pF }

    private let bus: I2CBus
    /// The tuner's reference. Follows the crystal-error correction, like the reference driver's tuner structure.
    private var crystalHz: UInt64

    private var shadow = [UInt8](repeating: 0, count: R820T.shadowCount)
    private var crystalCap: CrystalCap = .high0pF
    private var filterCalibrationCode: UInt8 = 0

    /// The intermediate frequency the tuner currently delivers (Hz); the RTL2832U must mix this down.
    private(set) var intermediateFrequencyHz: Int = 0
    /// False if the last frequency change could not lock the PLL (the tuner is then off-frequency).
    private(set) var pllLocked = false
    /// Which of the VCO's sub-bands the autotune settled on (status register 2, bits 5...0). Adjacent codes can differ in output level.
    private(set) var vcoBandCode = 0

    /// Take the VCO fine-tune bits for a frequency change from the previous lock check (which then reads five status
    /// bytes instead of three) instead of reading the status again first. A retune shortcut; the reference reads again.
    var reusesVCOStatus = false { didSet { lastFineTune = nil } }
    /// The fine-tune bits seen when the PLL last locked, while `reusesVCOStatus` is on; nil means "read them".
    private var lastFineTune: UInt8?

    /// Tells the tuner what its reference crystal really runs at (applies to the next frequency change).
    func setCrystalFrequency(_ hertz: UInt64) { crystalHz = hertz }

    init(bus: I2CBus, crystalHz: Int = 28_800_000) {
        self.bus = bus
        self.crystalHz = UInt64(crystalHz)
    }

    // MARK: Register access with shadow

    private func shadowIndex(_ register: Int) -> Int? {
        let index = register - Self.shadowStart
        return (0..<Self.shadowCount).contains(index) ? index : nil
    }

    /// Writes consecutive registers, unless they already hold exactly these values.
    private func write(_ register: Int, _ values: [UInt8]) throws {
        if let start = shadowIndex(register), start + values.count <= Self.shadowCount,
           Array(shadow[start..<start + values.count]) == values {
            return
        }
        // Update the shadow (clipped to what it covers).
        for (offset, value) in values.enumerated() {
            if let index = shadowIndex(register + offset) { shadow[index] = value }
        }
        var register = register
        var position = 0
        while position < values.count {
            let size = min(Self.maxMessageLength - 1, values.count - position)
            try bus.i2cWrite(address: Self.i2cAddress, bytes: [UInt8(register)] + values[position..<position + size])
            register += size
            position += size
        }
    }

    private func write(_ register: Int, value: UInt8) throws {
        try write(register, [value])
    }

    /// Changes only the bits in `mask` (using the shadow for the rest).
    private func write(_ register: Int, value: UInt8, mask: UInt8) throws {
        guard let index = shadowIndex(register) else { throw RTLSDRError.usb("R820T register \(register) is not shadowed") }
        try write(register, [(shadow[index] & ~mask) | (value & mask)])
    }

    private func bitReversed(_ byte: UInt8) -> UInt8 {
        let nibble: [UInt8] = [0x0, 0x8, 0x4, 0xc, 0x2, 0xa, 0x6, 0xe, 0x1, 0x9, 0x5, 0xd, 0x3, 0xb, 0x7, 0xf]
        return (nibble[Int(byte & 0xf)] << 4) | nibble[Int(byte >> 4)]
    }

    /// Reads status registers starting at `register`.
    private func read(_ register: Int, count: Int) throws -> [UInt8] {
        try bus.i2cWrite(address: Self.i2cAddress, bytes: [UInt8(register)])
        return try bus.i2cRead(address: Self.i2cAddress, length: count).map(bitReversed)
    }

    // MARK: Start-up

    func initialize() throws {
        crystalCap = .high0pF
        lastFineTune = nil
        shadow = [UInt8](repeating: 0, count: Self.shadowCount)
        // The table has 27 values; like the reference driver, write zeros to the reserved registers after them.
        let padding = [UInt8](repeating: 0, count: Self.shadowCount - R820TTables.initialRegisters.count)
        try write(Self.shadowStart, R820TTables.initialRegisters + padding)
        try selectStandard()
        try configureSignalPath()
    }

    /// Sets the filters and loads the register values for digital-TV style reception, calibrating the IF filter.
    private func selectStandard() throws {
        let filterCalibrationFrequencyHz: UInt32 = 56_000_000
        let intermediate = 3_570_000

        // Start from the power-on values.
        for (offset, value) in R820TTables.initialRegisters.enumerated() { shadow[offset] = value }

        try write(0x0c, value: 0x00, mask: 0x0f)                  // init flag and crystal-check result
        try write(0x13, value: Self.firmwareVersion, mask: 0x3f)
        try write(0x1d, value: 0x00, mask: 0x38)                  // LNA top for gain test
        intermediateFrequencyHz = intermediate

        // Calibrate the IF filter: run its calibration clock against a known PLL frequency and read the result.
        for _ in 0..<2 {
            try write(0x0b, value: 0x6b, mask: 0x60)              // filter capacitance
            try write(0x0f, value: 0x04, mask: 0x04)              // calibration clock on
            try write(0x10, value: 0x00, mask: 0x03)              // crystal cap 0 pF for the PLL
            try setPLL(frequencyHz: filterCalibrationFrequencyHz)
            if !pllLocked { return }                              // cannot calibrate without a lock
            try write(0x0b, value: 0x10, mask: 0x10)              // start trigger
            try write(0x0b, value: 0x00, mask: 0x10)              // stop trigger
            try write(0x0f, value: 0x00, mask: 0x04)              // calibration clock off
            let status = try read(0x00, count: 5)
            filterCalibrationCode = status[4] & 0x0f
            if filterCalibrationCode != 0 && filterCalibrationCode != 0x0f { break }
        }
        if filterCalibrationCode == 0x0f { filterCalibrationCode = 0 }  // narrowest

        try write(0x0a, value: 0x10 | filterCalibrationCode, mask: 0x1f)   // filter Q and calibration code
        try write(0x0b, value: 0x6b, mask: 0xef)                  // bandwidth, filter gain, high-pass corner
        try write(0x07, value: 0x00, mask: 0x80)                  // image rejection: negative
        try write(0x06, value: 0x10, mask: 0x30)                  // filter 3 dB point
        try write(0x1e, value: 0x60, mask: 0x60)                  // channel filter extension
        try write(0x05, value: 0x01, mask: 0x80)                  // loop-through off
        try write(0x1f, value: 0x00, mask: 0x80)                  // loop-through attenuation
        try write(0x0f, value: 0x00, mask: 0x80)                  // filter extension widest off
        try write(0x19, value: 0x60, mask: 0x60)                  // RF polyphase filter current
    }

    /// Mixer/LNA thresholds, charge-pump and buffer currents.
    private func configureSignalPath() throws {
        let mixerTop: UInt8 = 0x24, lnaTop: UInt8 = 0xe5, chargePump: UInt8 = 0x38, dividerBuffer: UInt8 = 0x30
        let lnaThreshold: UInt8 = 0x53, mixerThreshold: UInt8 = 0x75, lnaDischarge: UInt8 = 14, filterCurrent: UInt8 = 0x40

        try write(0x1d, value: lnaTop, mask: 0xc7)
        try write(0x1c, value: mixerTop, mask: 0xf8)
        try write(0x0d, value: lnaThreshold)
        try write(0x0e, value: mixerThreshold)
        try write(0x05, value: 0x00, mask: 0x60)                  // input: air
        try write(0x06, value: 0x00, mask: 0x08)
        try write(0x11, value: chargePump, mask: 0x38)
        try write(0x17, value: dividerBuffer, mask: 0x30)
        try write(0x0a, value: filterCurrent, mask: 0x60)

        try write(0x1d, value: 0x00, mask: 0x38)                  // LNA top: lowest
        try write(0x1c, value: 0x00, mask: 0x04)                  // normal mode
        try write(0x06, value: 0x00, mask: 0x40)                  // pre-detect off
        try write(0x1a, value: 0x30, mask: 0x30)                  // AGC clock 250 Hz
        try write(0x1d, value: 0x18, mask: 0x38)                  // LNA top = 3
        try write(0x1c, value: mixerTop, mask: 0x04)              // discharge mode
        try write(0x1e, value: lnaDischarge, mask: 0x1f)          // LNA discharge current
        try write(0x1a, value: 0x20, mask: 0x30)                  // AGC clock 60 Hz
    }

    func standby() throws {
        lastFineTune = nil
        try write(0x06, value: 0xb1)
        try write(0x05, value: 0xa0)
        try write(0x07, value: 0x3a)
        try write(0x08, value: 0x40)
        try write(0x09, value: 0xc0)
        try write(0x0a, value: 0x36)
        try write(0x0c, value: 0x35)
        try write(0x0f, value: 0x68)
        try write(0x11, value: 0x03)
        try write(0x17, value: 0xf4)
        try write(0x19, value: 0x0c)
    }

    // MARK: Tuning

    /// Tunes to `frequencyHz` (the tuner's local oscillator is placed one IF above it).
    func setFrequency(_ frequencyHz: Int) throws {
        let loFrequency = UInt32(truncatingIfNeeded: frequencyHz + intermediateFrequencyHz)
        try selectBand(loFrequencyHz: loFrequency)
        try setPLL(frequencyHz: loFrequency)
    }

    /// RF mux, tracking filter and crystal load for the band containing `loFrequencyHz`.
    private func selectBand(loFrequencyHz: UInt32) throws {
        let megahertz = Int(loFrequencyHz / 1_000_000)
        var band = R820TTables.bands[0]
        for index in 0..<R820TTables.bands.count - 1 {
            if megahertz < R820TTables.bands[index + 1].startMHz { band = R820TTables.bands[index]; break }
            band = R820TTables.bands[index + 1]
        }

        try write(0x17, value: band.openDrain, mask: 0x08)
        try write(0x1a, value: band.rfMuxPolyMux, mask: 0xc3)
        try write(0x1b, value: band.trackingFilter)

        let crystalBits: UInt8
        switch crystalCap {
        case .low30pF, .low20pF: crystalBits = band.crystalCap20pF | 0x08
        case .low10pF: crystalBits = band.crystalCap10pF | 0x08
        case .high0pF: crystalBits = band.crystalCap0pF
        case .low0pF: crystalBits = band.crystalCap0pF | 0x08
        }
        try write(0x10, value: crystalBits, mask: 0x0b)
        try write(0x08, value: 0x00, mask: 0x3f)
        try write(0x09, value: 0x00, mask: 0x3f)
    }

    /// The PLL's parameters for a frequency, computed without touching hardware (so they can be unit tested).
    struct PLLPlan: Equatable {
        var dividerBits: UInt8            // register 0x10 bits 7:5 after the VCO fine-tune adjustment
        var integerPart: UInt8
        var fraction: UInt32
        var registers: [UInt8]            // the seven bytes for registers 0x10...0x16
    }

    /// - Parameters:
    ///   - currentRegisters: the shadow values of registers 0x10...0x16 (seven bytes).
    ///   - vcoFineTune: bits 5:4 of the status register read after the divider was chosen.
    static func planPLL(loFrequencyHz: UInt32, crystalHz: UInt64, currentRegisters: [UInt8], vcoFineTune: UInt8) -> PLLPlan? {
        let vcoMinimumKHz: UInt32 = 1_770_000
        let vcoMaximumKHz = vcoMinimumKHz * 2
        let vcoPowerReference: UInt8 = 2
        let frequencyKHz = (loFrequencyHz + 500) / 1000

        var registers = currentRegisters
        registers[0] = (registers[0] & ~0x10) | (0 & 0x10)                    // reference divider: none
        registers[2] = (registers[2] & ~0xe0) | (0x80 & 0xe0)                  // VCO current 100

        // The mixer divider puts the VCO between 1.77 and 3.54 GHz.
        var mixDivider: UInt32 = 2
        var dividerExponent: UInt8 = 0
        while mixDivider <= 64 {
            if frequencyKHz &* mixDivider >= vcoMinimumKHz && frequencyKHz &* mixDivider < vcoMaximumKHz {
                var buffer = mixDivider
                while buffer > 2 { buffer >>= 1; dividerExponent &+= 1 }
                break
            }
            mixDivider <<= 1
        }

        if vcoFineTune > vcoPowerReference { dividerExponent &-= 1 } else if vcoFineTune < vcoPowerReference { dividerExponent &+= 1 }
        registers[0] = (registers[0] & ~0xe0) | ((dividerExponent << 5) & 0xe0)

        // vco / (2 * reference) = nint + sdm / 65536, rounded.
        let vcoFrequency = UInt64(loFrequencyHz) * UInt64(mixDivider)
        let scaled = (crystalHz + 65_536 * vcoFrequency) / (2 * crystalHz)
        let nint = UInt8(truncatingIfNeeded: scaled / 65_536)
        let sdm = UInt32(scaled % 65_536)
        guard Int(nint) <= (128 / Int(vcoPowerReference)) - 1 else { return nil }

        let ni = UInt8(truncatingIfNeeded: (Int(nint) - 13) / 4)
        let si = UInt8(truncatingIfNeeded: Int(nint) - 4 * Int(ni) - 13)
        registers[4] = UInt8(truncatingIfNeeded: Int(ni) + (Int(si) << 6))
        registers[2] = (registers[2] & ~0x08) | ((sdm == 0 ? 0x08 : 0x00) & 0x08)   // sigma-delta off when exact
        registers[5] = UInt8(sdm & 0xff)
        registers[6] = UInt8(truncatingIfNeeded: sdm >> 8)
        return PLLPlan(dividerBits: dividerExponent, integerPart: nint, fraction: sdm, registers: registers)
    }

    private func setPLL(frequencyHz: UInt32) throws {
        try write(0x1a, value: 0x00, mask: 0x0c)                  // autotune step 128 kHz

        let current = Array(shadow[(0x10 - Self.shadowStart)..<(0x10 - Self.shadowStart + 7)])
        // The VCO fine-tune bits decide whether the divider is nudged, so they are needed before computing.
        let fineTune: UInt8
        if reusesVCOStatus, let cached = lastFineTune {
            fineTune = cached
        } else {
            let status = try read(0x00, count: 5)
            fineTune = (status[4] & 0x30) >> 4
        }
        lastFineTune = nil
        guard let plan = Self.planPLL(loFrequencyHz: frequencyHz, crystalHz: crystalHz, currentRegisters: current, vcoFineTune: fineTune) else {
            throw RTLSDRError.pllOutOfRange(frequencyHz: Int(frequencyHz))
        }
        try write(0x10, plan.registers)

        var locked = false
        var lock: [UInt8] = [0, 0, 0, 0, 0]
        for attempt in 0..<2 {
            lock = try read(0x00, count: reusesVCOStatus ? 5 : 3)
            if lock[2] & 0x40 != 0 { locked = true; break }
            if attempt == 0 { try write(0x12, value: 0x60, mask: 0xe0) }   // not locked: more VCO current
        }
        pllLocked = locked
        vcoBandCode = Int(lock[2] & 0x3f)
        guard locked else { return }
        if reusesVCOStatus { lastFineTune = (lock[4] & 0x30) >> 4 }
        try write(0x1a, value: 0x08, mask: 0x08)                  // autotune step 8 kHz
    }

    // MARK: Bandwidth

    private static let lowPassBandwidths = [1_700_000, 1_600_000, 1_550_000, 1_450_000, 1_200_000, 900_000, 700_000, 550_000, 450_000, 350_000]
    private static let highPassCorner1 = 350_000
    private static let highPassCorner2 = 380_000

    /// Register values and the resulting IF for a requested bandwidth (pure).
    struct BandwidthPlan: Equatable {
        var register0a: UInt8
        var register0b: UInt8
        var intermediateFrequencyHz: Int
    }

    static func planBandwidth(_ requested: Int) -> BandwidthPlan {
        var bandwidth = requested
        if bandwidth > 7_000_000 { return BandwidthPlan(register0a: 0x10, register0b: 0x0b, intermediateFrequencyHz: 4_570_000) }
        if bandwidth > 6_000_000 { return BandwidthPlan(register0a: 0x10, register0b: 0x2a, intermediateFrequencyHz: 4_570_000) }
        if bandwidth > lowPassBandwidths[0] + highPassCorner1 + highPassCorner2 {
            return BandwidthPlan(register0a: 0x10, register0b: 0x6b, intermediateFrequencyHz: 3_570_000)
        }

        var register0b: UInt8 = 0x80
        var intermediate = 2_300_000
        var achieved = 0
        if bandwidth > lowPassBandwidths[0] + highPassCorner1 {
            bandwidth -= highPassCorner2
            intermediate += highPassCorner2
            achieved += highPassCorner2
        } else {
            register0b |= 0x20
        }
        if bandwidth > lowPassBandwidths[0] {
            bandwidth -= highPassCorner1
            intermediate += highPassCorner1
            achieved += highPassCorner1
        } else {
            register0b |= 0x40
        }
        // The narrowest low-pass setting that still passes the remaining bandwidth.
        var index = 0
        while index < lowPassBandwidths.count, bandwidth <= lowPassBandwidths[index] { index += 1 }
        let chosen = max(0, index - 1)
        register0b |= UInt8(15 - chosen)
        achieved += lowPassBandwidths[chosen]
        intermediate -= achieved / 2
        return BandwidthPlan(register0a: 0x00, register0b: register0b, intermediateFrequencyHz: intermediate)
    }

    /// Sets the IF filter for `bandwidthHz`; returns the IF the tuner now delivers.
    @discardableResult
    func setBandwidth(_ bandwidthHz: Int) throws -> Int {
        let plan = Self.planBandwidth(bandwidthHz)
        intermediateFrequencyHz = plan.intermediateFrequencyHz
        try write(0x0a, value: plan.register0a, mask: 0x10)
        try write(0x0b, value: plan.register0b, mask: 0xef)
        return plan.intermediateFrequencyHz
    }

    // MARK: Gain

    /// The gain settings offered to users (tenths of a dB). This matches the list a real R820T dongle reports.
    static let gainSteps: [Int] = [0, 9, 14, 27, 37, 77, 87, 125, 144, 157, 166, 197, 207, 229, 254, 280, 297, 328, 338, 364, 372, 386, 402, 421, 434, 439, 445, 480, 496]

    private static let lnaGain = [0, 9, 13, 40, 38, 13, 31, 22, 26, 31, 26, 14, 19, 5, 35, 13]
    private static let mixerGain = [0, 5, 10, 10, 19, 9, 10, 25, 17, 10, 8, 16, 13, 6, 3, -8]

    /// LNA and mixer indexes for a target gain (tenths of a dB): grow the two alternately until the target is reached.
    static func planGain(_ target: Int) -> (lna: UInt8, mixer: UInt8) {
        var total = 0
        var lna = 0, mixer = 0
        for _ in 0..<15 {
            if total >= target { break }
            lna += 1
            total += lnaGain[lna]
            if total >= target { break }
            mixer += 1
            total += mixerGain[mixer]
        }
        return (UInt8(lna), UInt8(mixer))
    }

    /// Automatic gain, or a manual setting near `gainTenthsDB`.
    func setGain(manual: Bool, gainTenthsDB: Int = 0) throws {
        if manual {
            try write(0x05, value: 0x10, mask: 0x10)              // LNA auto off
            try write(0x07, value: 0x00, mask: 0x10)              // mixer auto off
            _ = try read(0x00, count: 4)
            try write(0x0c, value: 0x08, mask: 0x9f)              // fixed VGA gain (16.3 dB)
            let plan = Self.planGain(gainTenthsDB)
            try write(0x05, value: plan.lna, mask: 0x0f)
            try write(0x07, value: plan.mixer, mask: 0x0f)
        } else {
            try write(0x05, value: 0x00, mask: 0x10)              // LNA auto on
            try write(0x07, value: 0x10, mask: 0x10)              // mixer auto on
            try write(0x0c, value: 0x0b, mask: 0x9f)              // fixed VGA gain (26.5 dB)
        }
    }
}
