// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The Realtek RTL2832U: a USB bridge with an ADC and a digital down-converter. This type knows its register
/// map and the handful of computations (resampler ratio, IF word, ppm word) that turn requests into register values.
///
/// Register access goes through vendor control transfers on the device's default pipe: every register is
/// addressed by a block (which internal unit) plus a 16-bit address, and the demodulator registers by a page
/// plus an address. See PROVENANCE.md for how the register map was established.
final class RTL2832U: @unchecked Sendable, I2CBus {

    // MARK: Register map

    enum Block: UInt16 {
        case demod = 0, usb = 1, sys = 2, tuner = 3, rom = 4, ir = 5, i2c = 6
    }

    enum USB {
        static let systemControl: UInt16 = 0x2000
        static let endpointAControl: UInt16 = 0x2148
        static let endpointAMaxPacket: UInt16 = 0x2158
    }

    enum Sys {
        static let demodControl: UInt16 = 0x3000
        static let gpioOutput: UInt16 = 0x3001
        static let gpioOutputEnable: UInt16 = 0x3003
        static let gpioDirection: UInt16 = 0x3004
        static let demodControl1: UInt16 = 0x300b
    }

    /// The crystal that clocks the RTL2832U (and, on most dongles, the tuner).
    static let defaultCrystalHz: Double = 28_800_000

    /// FIR coefficients loaded into the demodulator: the first eight fit a signed byte, the last eight need 12 bits.
    static let defaultFIR: [Int] = [-54, -36, -41, -40, -32, -14, 14, 53, 101, 156, 215, 273, 327, 372, 404, 421]

    let transport: RTLSDRTransport
    let crystalHz: Double
    /// The crystal after the user's ppm correction. The resampler ratio uses the nominal crystal (the ppm word then
    /// corrects the output rate); the IF mixer and the tuner use the corrected one.
    private(set) var correctedCrystalHz: Double

    init(transport: RTLSDRTransport, crystalHz: Double = RTL2832U.defaultCrystalHz) {
        self.transport = transport
        self.crystalHz = crystalHz
        self.correctedCrystalHz = crystalHz
    }

    // MARK: Register access

    func readRegister(_ block: Block, _ address: UInt16, length: Int = 1) throws -> UInt16 {
        let bytes = try transport.vendorRead(value: address, index: block.rawValue << 8, length: length)
        return combine(bytes)
    }

    func writeRegister(_ block: Block, _ address: UInt16, _ value: UInt16, length: Int = 1) throws {
        try transport.vendorWrite(value: address, index: (block.rawValue << 8) | 0x10, data: bytes(of: value, length: length))
    }

    func readDemod(page: UInt16, _ address: UInt16, length: Int = 1) throws -> UInt16 {
        let bytes = try transport.vendorRead(value: (address << 8) | 0x20, index: page, length: length)
        return combine(bytes)
    }

    func writeDemod(page: UInt16, _ address: UInt16, _ value: UInt16, length: Int = 1) throws {
        try transport.vendorWrite(value: (address << 8) | 0x20, index: 0x10 | page, data: bytes(of: value, length: length))
        // The chip needs a read of a status register after each demodulator write to latch it.
        _ = try readDemod(page: 0x0a, 0x01)
    }

    /// Single-byte values go out as-is; two-byte values go out most-significant byte first.
    private func bytes(of value: UInt16, length: Int) -> [UInt8] {
        length == 1 ? [UInt8(value & 0xff)] : [UInt8(value >> 8), UInt8(value & 0xff)]
    }

    private func combine(_ bytes: [UInt8]) -> UInt16 {
        let low = bytes.first.map(UInt16.init) ?? 0
        let high = bytes.count > 1 ? UInt16(bytes[1]) : 0
        return (high << 8) | low
    }

    // MARK: I2C (to the tuner)

    func i2cWrite(address: UInt8, bytes: [UInt8]) throws {
        try transport.vendorWrite(value: UInt16(address), index: (Block.i2c.rawValue << 8) | 0x10, data: bytes)
    }

    func i2cRead(address: UInt8, length: Int) throws -> [UInt8] {
        try transport.vendorRead(value: UInt16(address), index: Block.i2c.rawValue << 8, length: length)
    }

    /// Reads one tuner register: point at it, then read it back.
    func i2cReadRegister(address: UInt8, register: UInt8) throws -> UInt8 {
        try i2cWrite(address: address, bytes: [register])
        return try i2cRead(address: address, length: 1).first ?? 0
    }

    /// Whether the repeater is on, as far as this driver last set it.
    private var repeaterOn = false
    /// Leave the repeater on between tuner accesses instead of switching it around each one (a retune shortcut).
    private(set) var keepsRepeaterOn = false

    private func setRepeater(_ on: Bool) throws {
        try writeDemod(page: 1, 0x01, on ? 0x18 : 0x10)
        repeaterOn = on
    }

    /// The tuner is only reachable while the repeater is on. Turned off again afterwards, even on error, unless it is
    /// being kept on.
    func withI2CRepeater<T>(_ body: () throws -> T) throws -> T {
        if keepsRepeaterOn {
            if !repeaterOn { try setRepeater(true) }
            return try body()
        }
        try setRepeater(true)
        defer { try? setRepeater(false) }
        return try body()
    }

    /// Keeps the repeater on between tuner accesses, or switches it off now and goes back to toggling it.
    func keepRepeaterOn(_ keep: Bool) throws {
        keepsRepeaterOn = keep
        if !keep, repeaterOn { try setRepeater(false) }
    }

    /// Restarts the demodulator (so a new resampler ratio takes effect). The same register holds the repeater bit, so
    /// this also switches the repeater off.
    private func softReset() throws {
        try writeDemod(page: 1, 0x01, 0x14)
        repeaterOn = false
        try writeDemod(page: 1, 0x01, 0x10)
    }

    // MARK: Start-up

    /// Brings the USB block and the demodulator to a known state (start of every session).
    func initializeBaseband() throws {
        try writeRegister(.usb, USB.systemControl, 0x09)
        try writeRegister(.usb, USB.endpointAMaxPacket, 0x0002, length: 2)
        try writeRegister(.usb, USB.endpointAControl, 0x1002, length: 2)

        // Power on the demodulator.
        try writeRegister(.sys, Sys.demodControl1, 0x22)
        try writeRegister(.sys, Sys.demodControl, 0xe8)

        // Soft reset, then no spectrum inversion / adjacent-channel rejection.
        try softReset()
        try writeDemod(page: 1, 0x15, 0x00)
        try writeDemod(page: 1, 0x16, 0x0000, length: 2)

        // Clear the DDC shift and IF frequency registers.
        for offset: UInt16 in 0..<6 { try writeDemod(page: 1, 0x16 + offset, 0x00) }

        try loadFIR(Self.defaultFIR)

        try writeDemod(page: 0, 0x19, 0x05)          // SDR mode, digital AGC off
        try writeDemod(page: 1, 0x93, 0xf0)          // FSM state-holding registers
        try writeDemod(page: 1, 0x94, 0x0f)
        try writeDemod(page: 1, 0x11, 0x00)          // digital AGC off
        try writeDemod(page: 1, 0x04, 0x00)          // RF and IF AGC loops off
        try writeDemod(page: 0, 0x61, 0x60)          // PID filter off
        try writeDemod(page: 0, 0x06, 0x80)          // default ADC I/Q data path
        try writeDemod(page: 1, 0xb1, 0x1b)          // zero-IF, DC cancellation, IQ compensation on
        try writeDemod(page: 0, 0x0d, 0x83)          // stop the 4.096 MHz clock output
    }

    /// Settings a dongle with an R820T needs on top of `initializeBaseband` (the tuner delivers a low IF, not zero-IF).
    func configureForLowIFTuner(intermediateFrequencyHz: Int) throws {
        try writeDemod(page: 1, 0xb1, 0x1a)          // zero-IF off
        try writeDemod(page: 0, 0x08, 0x4d)          // In-phase ADC input only
        try setIntermediateFrequency(intermediateFrequencyHz)
        try writeDemod(page: 1, 0x15, 0x01)          // spectrum inversion on (the tuner's image is inverted)
    }

    // MARK: Computations (pure, tested)

    /// The two bytes-worth of resampler ratio for a sample rate, and the rate that ratio actually gives.
    /// Returns nil for rates the resampler cannot produce.
    static func resamplerSettings(sampleRate: Int, crystalHz: Double = defaultCrystalHz) -> (ratio: UInt32, actualRate: Double)? {
        guard sampleRate > 225_000, sampleRate <= 3_200_000, !(sampleRate > 300_000 && sampleRate <= 900_000) else { return nil }
        let scaled = crystalHz * 4_194_304.0                                  // crystal * 2^22
        var ratio = UInt32(scaled / Double(sampleRate))
        ratio &= 0x0fff_fffc
        let effective = ratio | ((ratio & 0x0800_0000) << 1)
        return (ratio, scaled / Double(effective))
    }

    /// Register bytes for the tuner's intermediate frequency (the demodulator mixes it down to zero).
    static func intermediateFrequencyWord(hz: Int, crystalHz: Double = defaultCrystalHz) -> (high: UInt8, middle: UInt8, low: UInt8) {
        let word = Int32(-(Double(hz) * 4_194_304.0 / crystalHz))            // negative: mix downwards
        return (UInt8((word >> 16) & 0x3f), UInt8((word >> 8) & 0xff), UInt8(word & 0xff))
    }

    /// The crystal frequency after a correction in ppm, truncated to whole hertz like the reference driver does.
    static func correctedCrystal(_ crystalHz: Double, ppm: Int) -> Double {
        Double(UInt32(crystalHz * (1.0 + Double(ppm) / 1e6)))
    }

    /// Crystal error correction in parts per million, as the two register bytes the demodulator wants.
    static func frequencyCorrectionWord(ppm: Int) -> (low: UInt8, high: UInt8) {
        let offset = Int16(truncatingIfNeeded: Int((Double(ppm) * -1 * 16_777_216.0 / 1_000_000).rounded(.towardZero)))
        return (UInt8(offset & 0xff), UInt8((offset >> 8) & 0x3f))
    }

    /// The FIR as the 20 bytes the demodulator expects: eight signed bytes, then eight 12-bit values packed in pairs.
    static func packedFIR(_ coefficients: [Int]) -> [UInt8]? {
        guard coefficients.count == 16 else { return nil }
        var packed: [UInt8] = []
        for value in coefficients[0..<8] {
            guard (-128...127).contains(value) else { return nil }
            packed.append(UInt8(truncatingIfNeeded: value))
        }
        for index in stride(from: 8, to: 16, by: 2) {
            let first = coefficients[index], second = coefficients[index + 1]
            guard (-2048...2047).contains(first), (-2048...2047).contains(second) else { return nil }
            packed.append(UInt8(truncatingIfNeeded: first >> 4))
            packed.append(UInt8(truncatingIfNeeded: (first << 4) | ((second >> 8) & 0x0f)))
            packed.append(UInt8(truncatingIfNeeded: second))
        }
        return packed
    }

    // MARK: Settings built on the computations

    func loadFIR(_ coefficients: [Int]) throws {
        guard let packed = Self.packedFIR(coefficients) else { throw RTLSDRError.usb("FIR coefficients out of range") }
        for (offset, byte) in packed.enumerated() {
            try writeDemod(page: 1, 0x1c + UInt16(offset), UInt16(byte))
        }
    }

    func setIntermediateFrequency(_ hz: Int) throws {
        let word = Self.intermediateFrequencyWord(hz: hz, crystalHz: correctedCrystalHz)
        try writeDemod(page: 1, 0x19, UInt16(word.high))
        try writeDemod(page: 1, 0x1a, UInt16(word.middle))
        try writeDemod(page: 1, 0x1b, UInt16(word.low))
    }

    func setFrequencyCorrection(ppm: Int) throws {
        correctedCrystalHz = Self.correctedCrystal(crystalHz, ppm: ppm)
        let word = Self.frequencyCorrectionWord(ppm: ppm)
        try writeDemod(page: 1, 0x3f, UInt16(word.low))
        try writeDemod(page: 1, 0x3e, UInt16(word.high))
    }

    /// Programs the resampler; returns the sample rate that will really be produced.
    @discardableResult
    func setSampleRate(_ rate: Int, correctionPPM: Int) throws -> Double {
        guard let settings = Self.resamplerSettings(sampleRate: rate, crystalHz: crystalHz) else {
            throw RTLSDRError.invalidSampleRate(rate)
        }
        try writeDemod(page: 1, 0x9f, UInt16(settings.ratio >> 16), length: 2)
        try writeDemod(page: 1, 0xa1, UInt16(settings.ratio & 0xffff), length: 2)
        try setFrequencyCorrection(ppm: correctionPPM)
        try softReset()                                         // so the new ratio takes effect
        return settings.actualRate
    }

    /// Powers off the demodulator and the ADCs (last step of closing).
    func powerDown() throws {
        try writeRegister(.sys, Sys.demodControl, 0x20)
    }

    /// Restarts the sample FIFO. Call before streaming.
    func resetStreamBuffer() throws {
        try writeRegister(.usb, USB.endpointAControl, 0x1002, length: 2)
        try writeRegister(.usb, USB.endpointAControl, 0x0000, length: 2)
    }

    // MARK: GPIO (bias tee, antenna switches, ...)

    func setGPIOOutput(_ pin: Int) throws {
        let mask = UInt16(1 << pin)
        let direction = try readRegister(.sys, Sys.gpioDirection)
        try writeRegister(.sys, Sys.gpioDirection, direction & ~mask)
        let enable = try readRegister(.sys, Sys.gpioOutputEnable)
        try writeRegister(.sys, Sys.gpioOutputEnable, enable | mask)
    }

    func setGPIO(_ pin: Int, high: Bool) throws {
        let mask = UInt16(1 << pin)
        let current = try readRegister(.sys, Sys.gpioOutput)
        try writeRegister(.sys, Sys.gpioOutput, high ? (current | mask) : (current & ~mask))
    }
}
