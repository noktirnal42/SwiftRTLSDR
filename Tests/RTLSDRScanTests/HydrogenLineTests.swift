// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRScan

struct LSRCorrectionTests {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    /// astropy 8.0.1: SkyCoord.radial_velocity_correction(kind="barycentric") plus 20 km/s toward (18h, +30°) B1900.
    @Test(arguments: [
        ("2026-10-05T12:00:00Z", 52.0, 4.6, 19.5, 30.0, 1.469),
        ("2026-03-20T00:00:00Z", 37.4, -122.1, 18.0, -23.44, 41.627),
        ("2027-06-21T06:30:00Z", -33.9, 151.2, 5.5, -70.0, -14.043),
        ("2026-12-24T18:00:00Z", 40.0, -105.0, 3.0, 60.0, -8.902),
    ])
    func agreesWithAstropy(when: String, latitude: Double, longitude: Double, ra: Double, dec: Double, expected: Double) {
        let v = LSRCorrection.velocity(rightAscension: ra, declination: dec, date: date(when), latitude: latitude, longitude: longitude)
        #expect(abs(v - expected) < 0.3, "\(v) km/s against \(expected)")
    }

    @Test func azimuthAndElevationGiveTheSkyPosition() {
        // astropy: az 135°, el 40° from 52° N 4.6° E at 2026-10-05 12:00 UTC is RA 15.455 h, Dec +10.056° (it adds
        // refraction and polar motion, a few hundredths of a degree here).
        let (ra, dec) = LSRCorrection.equatorial(azimuth: 135, elevation: 40, date: date("2026-10-05T12:00:00Z"), latitude: 52, longitude: 4.6)
        #expect(abs(ra - 15.455) < 0.005, "RA \(ra) h")
        #expect(abs(dec - 10.056) < 0.1, "Dec \(dec)°")
    }

    @Test func radioVelocities() {
        #expect(HydrogenLine.radioVelocity(frequencyHz: HydrogenLine.restHz) == 0)
        #expect(abs(HydrogenLine.radioVelocity(frequencyHz: HydrogenLine.restHz - 473_795) - 100) < 0.01)   // receding
    }
}

struct SwitchedSpectrometerTests {
    /// Noise through a bandpass that falls off toward the edges, plus (when `line`) a weak band of noise 200 kHz below
    /// the tuned frequency: what a dish sees on and off the 21 cm line.
    private func capture(line: Bool, seed: UInt64, count: Int) -> [UInt8] {
        var state = seed
        func gaussian() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let u1 = (Double(state >> 11) + 0.5) / Double(1 << 53)
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let u2 = (Double(state >> 11) + 0.5) / Double(1 << 53)
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
        var bytes = [UInt8](repeating: 0, count: 2 * count)
        var (pi, pq) = (0.0, 0.0), (li, lq) = (0.0, 0.0)
        let step = -2 * Double.pi * 200_000 / 2_400_000
        for n in 0..<count {
            // Bandpass: a gentle low-pass of white noise. Line: narrow noise (one pole) shifted to −200 kHz.
            (pi, pq) = (0.6 * pi + gaussian(), 0.6 * pq + gaussian())
            var i = pi * 8, q = pq * 8
            if line {
                (li, lq) = (0.98 * li + 0.25 * gaussian(), 0.98 * lq + 0.25 * gaussian())
                let (c, s) = (cos(step * Double(n)), sin(step * Double(n)))
                i += 8 * (li * c - lq * s)
                q += 8 * (li * s + lq * c)
            }
            bytes[2 * n] = UInt8(max(0, min(255, (127.5 + i).rounded())))
            bytes[2 * n + 1] = UInt8(max(0, min(255, (127.5 + q).rounded())))
        }
        return bytes
    }

    @Test func aLineOnlyTheSignalTuningSeesStandsOut() throws {
        let spectrometer = try #require(SwitchedSpectrometer(fftSize: 256, sampleRate: 2_400_000))
        for round in 0..<4 {                                 // alternating, as the switching does
            spectrometer.add(capture(line: true, seed: UInt64(2 * round + 1), count: 128 * 256), to: .signal)
            spectrometer.add(capture(line: false, seed: UInt64(2 * round + 2), count: 128 * 256), to: .reference)
        }
        let ratio = try #require(spectrometer.ratio(smoothing: 3))
        let offsets = spectrometer.binOffsets
        let peak = ratio.indices.max { ratio[$0] < ratio[$1] }!
        #expect(abs(offsets[peak] + 200_000) < 3 * 9_375, "peak at \(offsets[peak]) Hz")
        #expect(ratio[peak] > 0.5)
        // Away from the line the bandpass divides out: flat to the noise of 512 transforms.
        let far = ratio.indices.filter { abs(offsets[$0] - 400_000) < 200_000 }
        #expect(far.allSatisfy { abs(ratio[$0]) < 0.15 })
        let expectedSeconds: Double = 4.0 * 128 * 256 / 2_400_000    // outside the macro: Swift 6.3 cannot type-check it inside
        #expect(spectrometer.integratedSeconds.signal == expectedSeconds)
    }

    @Test func nothingBeforeBothPositionsHaveData() throws {
        let spectrometer = try #require(SwitchedSpectrometer(fftSize: 64, sampleRate: 1_000_000))
        spectrometer.add([UInt8](repeating: 128, count: 256), to: .signal)
        #expect(spectrometer.ratio() == nil)
    }
}
