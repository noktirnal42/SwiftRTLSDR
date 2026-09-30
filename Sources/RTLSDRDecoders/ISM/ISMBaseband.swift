// SPDX-License-Identifier: GPL-2.0-or-later
//
// The OOK envelope and FM discriminator for the ISM sensor decoders, ported from rtl_433's baseband.c
// (Benjamin Larsson, Tommy Vestermark; GPL-2.0-or-later, https://github.com/merbanan/rtl_433, release 25.02).
// The fixed-point arithmetic is kept exactly as there, so the pulse detector sees the numbers rtl_433 sees.
// See PROVENANCE.md.
import Foundation

/// Turns u8 I/Q into the two signals the pulse detector works on: the amplitude envelope (I² + Q², low-pass
/// filtered; full scale 16384) and the instantaneous frequency (π = 32767, low-pass filtered). State carries across
/// blocks.
struct ISMBaseband {
    private static let squares: [Int32] = (0..<256).map { Int32((127 - $0) * (127 - $0)) }

    // First-order Butterworth low-pass for the envelope, cutoff 0.05 × Nyquist, prescaled by ½ (Q1.15 >> 1).
    private static let envelopeA1 = 13_993         // FIX(0.85408) >> 1
    private static let envelopeB0 = 1_195          // FIX(0.07296) >> 1

    private var envelopeX: Int16 = 0               // last input, stored as rtl_433 stores it (a u16 in an i16)
    private var envelopeY: Int16 = 0

    private let fmA1: Int
    private let fmB0: Int
    private var xr: Int16 = 0, xi: Int16 = 0       // previous I/Q sample, centred
    private var xf: Int16 = 0, yf: Int16 = 0       // previous raw and filtered frequency

    /// `fmLowPass`: the discriminator's cutoff as a fraction of Nyquist; rtl_433 uses 0.1 with the classic FSK
    /// detector and 0.2 with the min/max one.
    init(fmLowPass: Float) {
        let ita = 1.0 / tan(Double.pi / 2 * Double(fmLowPass))
        let gain = 1.0 / (1.0 + ita) / 2           // prescaled by ½
        fmA1 = Int((ita - 1.0) * gain * 32_768)
        fmB0 = Int(gain * 32_768)
    }

    /// The discriminator's filter coefficients, for tests.
    var fmCoefficients: (a1: Int, b0: Int) { (fmA1, fmB0) }

    /// Processes whole I/Q pairs (`iq.count` must be even). Returns the mean envelope power, in dB relative to
    /// full scale, as rtl_433's `envelope_detect` does.
    @discardableResult
    mutating func process(_ iq: UnsafeBufferPointer<UInt8>, envelope: inout [Int16], fm: inout [Int16]) -> Float {
        let count = iq.count / 2
        envelope.removeAll(keepingCapacity: true)
        fm.removeAll(keepingCapacity: true)
        envelope.reserveCapacity(count)
        fm.reserveCapacity(count)
        guard count > 0 else { return 0 }

        var sum: UInt32 = 0
        var previousX = Int(envelopeX)
        var previousY = Int(envelopeY)
        var lastRaw: UInt16 = 0
        var x0r = xr, x0i = xi, x0f = xf, y0f = yf
        for n in 0..<count {
            let i = iq[2 * n], q = iq[2 * n + 1]

            // Envelope: (127 - I)² + (127 - Q)², then the low-pass filter.
            let raw = UInt16(Self.squares[Int(i)] + Self.squares[Int(q)])
            sum &+= UInt32(raw)
            let x = Int(raw)
            let y = (Self.envelopeA1 * previousY + Self.envelopeB0 * (x + previousX)) >> 14
            let y16 = Int16(truncatingIfNeeded: y)
            envelope.append(y16)
            previousX = x
            previousY = Int(y16)
            lastRaw = raw

            // Frequency: the angle of x[n]·conj(x[n-1]), then the low-pass filter.
            let x1r = x0r, x1i = x0i, x1f = x0f, y1f = y0f
            x0r = Int16(i) - 128
            x0i = Int16(q) - 128
            let pr = Int32(x0r) * Int32(x1r) + Int32(x0i) * Int32(x1i)
            let pi = Int32(x0i) * Int32(x1r) - Int32(x0r) * Int32(x1i)
            x0f = Self.atan2(pi, pr)
            y0f = Int16(truncatingIfNeeded: (fmA1 * Int(y1f) + fmB0 * (Int(x0f) + Int(x1f))) >> 14)
            fm.append(y0f)
        }
        envelopeX = Int16(bitPattern: lastRaw)
        envelopeY = Int16(truncatingIfNeeded: previousY)
        xr = x0r; xi = x0i; xf = x0f; yf = y0f

        let mean = Float(sum) / Float(count)
        return sum >= UInt32(count) ? 10 * log10f(mean) - 42.1442 : 10 * log10f(1) - 42.1442
    }

    /// rtl_433's integer atan2 with self-normalisation (error up to 0.07 rad); π is 32767.
    static func atan2(_ y: Int32, _ x: Int32) -> Int16 {
        let quarter: Int32 = 32_767 / 4, threeQuarters: Int32 = 3 * 32_767 / 4
        if x == 0 && y == 0 { return 0 }
        let absY = abs(y)
        var angle: Int32
        if x >= 0 {
            var denominator = absY + x
            if denominator == 0 { denominator = 1 }
            angle = quarter - quarter * (x - absY) / denominator
        } else {
            var denominator = absY - x
            if denominator == 0 { denominator = 1 }
            angle = threeQuarters - quarter * (x + absY) / denominator
        }
        if y < 0 { angle = -angle }
        return Int16(truncatingIfNeeded: angle)
    }
}
