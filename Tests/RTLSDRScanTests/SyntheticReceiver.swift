// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRScan

/// A deterministic random source (SplitMix64), so tests see the same noise every run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    /// A standard normal value (Box-Muller).
    mutating func gaussian() -> Double {
        let u1 = max(Double.leastNonzeroMagnitude, Double.random(in: 0..<1, using: &self))
        let u2 = Double.random(in: 0..<1, using: &self)
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

/// Stands in for a dongle: carriers at fixed absolute frequencies, Gaussian noise, and a DC offset, quantised to
/// unsigned 8 bits and clipped like the real ADC.
final class SyntheticReceiver: ScanReceiver {
    struct Tone { var frequencyHz: Double; var amplitude: Double }   // amplitude in ADC codes

    var sampleRate: Double
    var tones: [Tone]
    var noiseCodes: Double
    var dcOffsetCodes: Double
    private(set) var tunedHz = 0
    private(set) var tuneLog: [Int] = []
    private var generator = SeededGenerator(state: 1)

    init(sampleRate: Double = 2_400_000, tones: [Tone] = [], noiseCodes: Double = 3, dcOffsetCodes: Double = 4) {
        self.sampleRate = sampleRate
        self.tones = tones
        self.noiseCodes = noiseCodes
        self.dcOffsetCodes = dcOffsetCodes
    }

    func tune(to hertz: Int) throws {
        tunedHz = hertz
        tuneLog.append(hertz)
    }

    func capture(byteCount: Int) throws -> [UInt8] {
        let visible = tones.filter { abs($0.frequencyHz - Double(tunedHz)) < sampleRate / 2 }
        let phases = visible.map { _ in Double.random(in: 0..<(2 * Double.pi), using: &generator) }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for n in 0..<(byteCount / 2) {
            var i = 127.5 + dcOffsetCodes + noiseCodes * generator.gaussian()
            var q = 127.5 + dcOffsetCodes + noiseCodes * generator.gaussian()
            for (tone, phase) in zip(visible, phases) {
                let angle = phase + 2 * Double.pi * (tone.frequencyHz - Double(tunedHz)) * Double(n) / sampleRate
                i += tone.amplitude * cos(angle)
                q += tone.amplitude * sin(angle)
            }
            bytes[2 * n] = UInt8(min(255, max(0, i.rounded())))
            bytes[2 * n + 1] = UInt8(min(255, max(0, q.rounded())))
        }
        return bytes
    }
}
