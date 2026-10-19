// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRScan

/// SH-9: measure-only calibration results that say how sure they are, from synthetic signals with a known error.
/// Nothing here writes to a dongle.
struct CalibrationUncertaintyTests {

    /// A deterministic noise source (a 64-bit linear congruential generator), so each run sees the same samples.
    private struct Noise {
        var state: UInt64
        mutating func uniform() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            let u = max(uniform(), 1e-12), v = uniform()
            return (-2 * log(u)).squareRoot() * cos(2 * Double.pi * v)
        }
    }

    /// u8 I/Q of a carrier as a dongle whose crystal is `ppm` fast sees it when tuned to `tunedHz`, with noise.
    private func carrier(carrierHz: Double, tunedHz: Double, ppm: Double, rate: Double, seconds: Double) -> [UInt8] {
        let offset = carrierHz / (1 + ppm * 1e-6) - tunedHz
        var noise = Noise(state: 7)
        let count = Int(rate * seconds)
        var bytes = [UInt8](repeating: 0, count: 2 * count)
        for n in 0..<count {
            let phase = 2 * Double.pi * offset * Double(n) / rate
            bytes[2 * n] = UInt8(max(0, min(255, (127.5 + 12 * cos(phase) + 40 * noise.gaussian()).rounded())))
            bytes[2 * n + 1] = UInt8(max(0, min(255, (127.5 + 12 * sin(phase) + 40 * noise.gaussian()).rounded())))
        }
        return bytes
    }

    // MARK: Carrier calibrator

    @Test func aCarrierMeasurementCarriesAStandardErrorAndAnUncertainty() throws {
        let carrierHz = 162_550_000.0, rate = 1_024_000.0, tuned = carrierHz - rate / 4
        let calibrator = try #require(CarrierCalibrator(sampleRate: rate, tunedHz: tuned, carrierHz: carrierHz,
                                                        fftSize: 1 << 16, referenceUncertaintyPPM: 0.5))
        calibrator.process(iq: carrier(carrierHz: carrierHz, tunedHz: tuned, ppm: 23.7, rate: rate, seconds: 0.4))
        let m = try #require(calibrator.measurement())
        #expect(m.transforms == 6)
        let standardError = try #require(m.standardErrorPPM)
        #expect(standardError > 0 && standardError < 0.5, "the spread of six transforms: \(standardError) ppm")
        #expect(abs(m.uncertaintyPPM! - (standardError + 0.5)) < 1e-12, "the reference's accuracy is added in")
        #expect(abs(m.ppm - 23.7) < 4 * m.uncertaintyPPM!, "the result is within its stated uncertainty: \(m.ppm)")
    }

    @Test func oneTransformGivesNoUncertaintyRatherThanAFakeOne() throws {
        let carrierHz = 162_550_000.0, rate = 1_024_000.0, tuned = carrierHz - rate / 4
        let calibrator = try #require(CarrierCalibrator(sampleRate: rate, tunedHz: tuned, carrierHz: carrierHz, fftSize: 1 << 16))
        calibrator.process(iq: carrier(carrierHz: carrierHz, tunedHz: tuned, ppm: 1, rate: rate, seconds: 0.07))
        let m = try #require(calibrator.measurement())
        #expect(m.transforms == 1)
        #expect(m.standardErrorPPM == nil && m.uncertaintyPPM == nil)
    }

    // MARK: FM pilot

    /// The complex baseband of an FM station whose stereo pilot is 19 kHz in its own time base, received by a dongle
    /// whose crystal is `ppm` fast: the samples are taken at `rate·(1 + ppm·1e-6)` real hertz, so the pilot shows at
    /// 19 000 / (1 + ppm) in nominal hertz.
    private func fmStation(pilotLevel: Double, ppm: Double, rate: Double, samples: Int) -> [UInt8] {
        var noise = Noise(state: 11)
        let realRate = rate * (1 + ppm * 1e-6)
        let deviationHz = 5_000.0                               // a narrow test deviation keeps each phase step small
        var phase = 0.0
        var bytes = [UInt8](repeating: 0, count: 2 * samples)
        for n in 0..<samples {
            let t = Double(n) / realRate
            // Instantaneous frequency = deviation · pilot(t); the phase is its integral.
            let omega = 2 * Double.pi * FMPilotCalibrator.nominalPilotHz
            phase = deviationHz * pilotLevel * sin(omega * t) / FMPilotCalibrator.nominalPilotHz
            let i = 0.8 * cos(phase) + 0.01 * noise.gaussian()
            let q = 0.8 * sin(phase) + 0.01 * noise.gaussian()
            bytes[2 * n] = UInt8(max(0, min(255, (127.5 + 100 * i).rounded())))
            bytes[2 * n + 1] = UInt8(max(0, min(255, (127.5 + 100 * q).rounded())))
        }
        return bytes
    }

    @Test(arguments: [2.5, -7.0])
    func theCrystalErrorIsReadFromTheStereoPilot(ppm: Double) throws {
        let rate = 128_000.0
        let calibrator = try #require(FMPilotCalibrator(sampleRate: rate, fftSize: 1 << 19))
        #expect(calibrator.decimation == 1)
        calibrator.process(iq: fmStation(pilotLevel: 0.1, ppm: ppm, rate: rate, samples: (1 << 19) + 64))
        let m = try #require(calibrator.measurement())
        #expect(m.segments == 1)
        #expect(m.snrDB > 30, "a clean pilot stands well above the median: \(m.snrDB) dB")
        #expect(abs(m.ppm - ppm) < 0.5, "measured \(m.ppm) ppm for a true \(ppm)")
        #expect(m.standardErrorPPM == nil, "one segment has no spread")
    }

    @Test func aStationWithoutAPilotGivesNoMeasurement() throws {
        let rate = 128_000.0
        let calibrator = try #require(FMPilotCalibrator(sampleRate: rate, fftSize: 1 << 16))
        calibrator.process(iq: fmStation(pilotLevel: 0, ppm: 0, rate: rate, samples: (1 << 16) + 64))
        #expect(calibrator.measurement() == nil, "a mono station (no pilot) is not reported as a measurement")
    }

    @Test func theFMPilotReportsItsDecimationAndTolerance() throws {
        let calibrator = try #require(FMPilotCalibrator(sampleRate: 2_048_000))
        #expect(calibrator.decimation == 16)
        #expect(calibrator.decimatedRate == 128_000)
        #expect(abs(FMPilotCalibrator.regulatoryPilotTolerancePPM - 105.26) < 0.01, "±2 Hz at 19 kHz is about 105 ppm")
    }
}
