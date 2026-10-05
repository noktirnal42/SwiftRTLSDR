// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRScan

struct FFTTests {
    @Test func matchesADirectDFT() throws {
        let fft = try #require(FFT(size: 64))
        var generator = SeededGenerator(state: 7)
        let inputRe = (0..<64).map { _ in generator.gaussian() }, inputIm = (0..<64).map { _ in generator.gaussian() }
        var re = inputRe, im = inputIm
        fft.forward(real: &re, imaginary: &im)
        for k in 0..<64 {
            var sumRe = 0.0, sumIm = 0.0
            for n in 0..<64 {
                let angle = -2 * Double.pi * Double(k * n) / 64
                sumRe += inputRe[n] * cos(angle) - inputIm[n] * sin(angle)
                sumIm += inputRe[n] * sin(angle) + inputIm[n] * cos(angle)
            }
            #expect(abs(re[k] - sumRe) < 1e-9 && abs(im[k] - sumIm) < 1e-9, "bin \(k)")
        }
    }

    @Test(arguments: [0, 1, 3, 12])
    func onlyPowersOfTwoAreAccepted(size: Int) {
        #expect(FFT(size: size) == nil)
    }
}

struct SpectrumEstimatorTests {
    /// A tone at `offset` Hz from the tuned frequency, `amplitude` codes, as u8 I/Q.
    private func tone(offsetHz: Double, amplitude: Double, rate: Double = 2_048_000, pairs: Int = 8192) -> [UInt8] {
        var bytes: [UInt8] = []
        for n in 0..<pairs {
            let angle = 2 * Double.pi * offsetHz * Double(n) / rate
            bytes.append(UInt8((127.5 + amplitude * cos(angle)).rounded()))
            bytes.append(UInt8((127.5 + amplitude * sin(angle)).rounded()))
        }
        return bytes
    }

    @Test func aToneLandsInItsBinAtItsLevel() throws {
        let estimator = try #require(SpectrumEstimator(fftSize: 1024))
        // 2.048 MS/s / 1024 = 2 kHz bins; +256 kHz is 128 bins above DC, DC sits at bin 512.
        let power = try #require(estimator.averagePower(tone(offsetHz: 256_000, amplitude: 100)))
        let peak = power.indices.max { power[$0] < power[$1] }!
        #expect(peak == 512 + 128)
        #expect(abs(10 * log10(power[peak]) - 20 * log10(100 / 127.5)) < 0.1, "amplitude 100 codes of 127.5")
    }

    @Test func negativeFrequenciesAreBelowDC() throws {
        let estimator = try #require(SpectrumEstimator(fftSize: 1024))
        let power = try #require(estimator.averagePower(tone(offsetHz: -100_000, amplitude: 60)))
        #expect(power.indices.max { power[$0] < power[$1] }! == 512 - 50)
    }

    @Test func tooFewSamplesGiveNothing() throws {
        let estimator = try #require(SpectrumEstimator(fftSize: 1024))
        #expect(estimator.averagePower([UInt8](repeating: 128, count: 2047)) == nil)
        #expect(estimator.frames(inByteCount: 2048 * 3 + 5) == 3)
    }
}

struct SweepPlanTests {
    @Test func overlappingHopsSeeEveryFrequencyAwayFromTheirOwnDCGap() throws {
        let plan = try #require(SweepPlan(range: 400_000_000...406_000_000, sampleRate: 2_400_000, fftSize: 1024))
        #expect(plan.centers.first == 400_000_000)
        #expect(plan.centers.last! >= 406_000_000)
        #expect(plan.stepBins == plan.usableHalfBins)
        var stitcher = SpectrumStitcher(plan: plan)
        for index in plan.centers.indices { stitcher.add(hop: index, power: [Double](repeating: 1, count: 1024)) }
        let spectrum = stitcher.spectrum()
        #expect(!spectrum.powerDB.contains { $0.isNaN }, "no holes")
        #expect(spectrum.startHz >= 400_000_000 && spectrum.frequency(ofBin: spectrum.powerDB.count - 1) <= 406_000_000)
        #expect(spectrum.frequency(ofBin: spectrum.powerDB.count - 1) > 406_000_000 - spectrum.binWidthHz)
    }

    @Test func withoutOverlapTheHopsHalveButLeaveAGapAtEachCentre() throws {
        let covering = try #require(SweepPlan(range: 400_000_000...420_000_000, sampleRate: 2_400_000, fftSize: 1024))
        let plan = try #require(SweepPlan(range: 400_000_000...420_000_000, sampleRate: 2_400_000, fftSize: 1024, coverDCHoles: false))
        #expect(plan.centers.count < covering.centers.count * 2 / 3)
        var stitcher = SpectrumStitcher(plan: plan)
        for index in plan.centers.indices { stitcher.add(hop: index, power: [Double](repeating: 1, count: 1024)) }
        let spectrum = stitcher.spectrum()
        for center in plan.centers.dropLast() {
            let bin = try #require(spectrum.bin(nearest: Double(center)))
            #expect(spectrum.powerDB[bin].isNaN, "gap at \(center)")
        }
    }

    @Test func settingsThatCannotWorkAreRefused() {
        #expect(SweepPlan(range: 1...2, sampleRate: 0, fftSize: 1024) == nil)
        #expect(SweepPlan(range: 1...2, sampleRate: 2_400_000, fftSize: 1000) == nil)
        #expect(SweepPlan(range: 1...2, sampleRate: 2_400_000, fftSize: 1024, dcExclusionHz: 1_000_000) == nil, "DC gap wider than the usable band")
    }

    @Test func aToneLandsInTheSameGlobalBinWhicheverHopSeesIt() throws {
        let receiver = SyntheticReceiver(tones: [.init(frequencyHz: 402_345_678, amplitude: 40)], noiseCodes: 1, dcOffsetCodes: 0)
        let plan = try #require(SweepPlan(range: 400_000_000...406_000_000, sampleRate: receiver.sampleRate, fftSize: 1024))
        let estimator = try #require(SpectrumEstimator(fftSize: 1024))
        var peaks: [Double] = []
        for (index, center) in plan.centers.enumerated() where abs(Double(center) - 402_345_678) < Double(plan.usableHalfBins) * plan.binWidth {
            try receiver.tune(to: center)
            var stitcher = SpectrumStitcher(plan: plan)
            stitcher.add(hop: index, power: try #require(estimator.averagePower(try receiver.capture(byteCount: 16 * 2048))))
            let spectrum = stitcher.spectrum()
            let strongest = spectrum.powerDB.indices.filter { !spectrum.powerDB[$0].isNaN }.max { spectrum.powerDB[$0] < spectrum.powerDB[$1] }!
            peaks.append(spectrum.frequency(ofBin: strongest))
        }
        #expect(peaks.count == 2, "seen by two overlapping hops")
        #expect(Set(peaks).count == 1 && abs(peaks[0] - 402_345_678) <= plan.binWidth)
    }
}

struct PeakDetectorTests {
    private func flatSpectrum(level: Double = -60, count: Int = 4000, binWidth: Double = 2000) -> Spectrum {
        var generator = SeededGenerator(state: 3)
        return Spectrum(startHz: 100_000_000, binWidthHz: binWidth, powerDB: (0..<count).map { _ in level + generator.gaussian() })
    }

    @Test func tonesAboveTheFloorAreFoundAndNothingElse() {
        var spectrum = flatSpectrum()
        for (bin, level) in [(500, -30.0), (1800, -45.0), (3500, -20.0)] { spectrum.powerDB[bin] = level }
        let found = PeakDetector().detect(in: spectrum)
        #expect(found.map(\.frequencyHz) == [101_000_000, 103_600_000, 107_000_000])
        #expect(abs(found[0].snrDB - 30) < 1.5 && abs(found[0].noiseFloorDB + 60) < 1)
    }

    @Test func aSlopingFloorIsNotMistakenForSignals() {
        var spectrum = flatSpectrum()
        for bin in spectrum.powerDB.indices { spectrum.powerDB[bin] += 25 * Double(bin) / Double(spectrum.powerDB.count) }
        #expect(PeakDetector().detect(in: spectrum).isEmpty)
    }

    @Test func peaksCloserThanTheSeparationMergeIntoTheStrongerOne() throws {
        var spectrum = flatSpectrum()
        spectrum.powerDB[1000] = -30
        spectrum.powerDB[1005] = -25                      // 10 kHz away
        let found = PeakDetector().detect(in: spectrum)
        let merged = try #require(found.first)
        #expect(found.count == 1 && merged.frequencyHz == spectrum.frequency(ofBin: 1005))
        #expect(merged.bandwidthHz >= 5 * spectrum.binWidthHz)
    }

    @Test func aWideSignalIsOneDetectionWithItsWidth() throws {
        var spectrum = flatSpectrum()
        for bin in 2000..<2010 { spectrum.powerDB[bin] = -35 }
        spectrum.powerDB[2004] = -33
        let found = PeakDetector().detect(in: spectrum)
        #expect(found.count == 1)
        #expect(found.first?.frequencyHz == spectrum.frequency(ofBin: 2004) && found.first?.bandwidthHz == 20_000)
    }

    @Test func binsWithoutDataAreSkipped() {
        var spectrum = flatSpectrum()
        for bin in 100..<110 { spectrum.powerDB[bin] = .nan }
        spectrum.powerDB[200] = -20
        #expect(PeakDetector().detect(in: spectrum).map(\.frequencyHz) == [spectrum.frequency(ofBin: 200)])
    }
}

struct ScannerTests {
    private func configuration(_ range: ClosedRange<Int> = 400_000_000...406_000_000) -> BandScanner.Configuration {
        var configuration = BandScanner.Configuration(range: range)
        configuration.framesPerHop = 8
        return configuration
    }

    @Test func aSweepFindsTheCarriersAndNotTheDCSpikes() throws {
        let frequencies = [401_200_000.0, 403_512_500, 405_900_000]
        let receiver = SyntheticReceiver(tones: frequencies.map { .init(frequencyHz: $0, amplitude: 20) }, dcOffsetCodes: 6)
        let scanner = try BandScanner(receiver: receiver, configuration: configuration())
        let spectrum = try scanner.sweep()
        let found = scanner.detect(in: spectrum)
        #expect(found.count == 3, "\(found.map(\.frequencyHz))")
        for (detection, expected) in zip(found, frequencies) {
            #expect(abs(detection.frequencyHz - expected) <= spectrum.binWidthHz, "\(detection.frequencyHz) vs \(expected)")
        }
        #expect(receiver.tuneLog == scanner.plan.centers, "one tune per hop, in order")
    }

    @Test func aCarrierExactlyOnAHopCentreIsStillFound() throws {
        let plan = try #require(SweepPlan(range: 400_000_000...406_000_000, sampleRate: 2_400_000, fftSize: 1024))
        let onCentre = Double(plan.centers[3])
        let receiver = SyntheticReceiver(tones: [.init(frequencyHz: onCentre, amplitude: 20)], dcOffsetCodes: 0)
        let scanner = try BandScanner(receiver: receiver, configuration: configuration())
        let found = scanner.detect(in: try scanner.sweep())
        #expect(found.count == 1 && abs(found[0].frequencyHz - onCentre) <= scanner.plan.binWidth)
    }

    @Test func aScannerWithoutASampleRateIsRefused() {
        let receiver = SyntheticReceiver(sampleRate: 0)
        #expect(throws: ScanError.invalidConfiguration) { try BandScanner(receiver: receiver, configuration: configuration()) }
    }
}

/// Recognises a carrier at 0 Hz of the dwell's baseband, which proves the dwell's offset arithmetic.
final class CarrierDecoder: SignalDecoder {
    let name = "carrier"
    let dwellSeconds = 0.01
    var interest: ClosedRange<Double> = 0...Double.greatestFiniteMagnitude
    var succeeds = true
    private(set) var dwells: [Dwell] = []

    func wants(_ detection: Detection) -> Bool { interest.contains(detection.frequencyHz) }

    func decode(_ dwell: Dwell) -> [DecodedMessage] {
        dwells.append(dwell)
        let (i, q) = dwell.basebandIQ()
        // Mean over short windows: large only if the carrier was mixed to near 0 Hz. The detection is only accurate to
        // a bin (about ±1.2 kHz here), which a 256-sample window (0.1 ms) tolerates; a carrier left at the 600 kHz
        // tuning offset would average away.
        var magnitude: Float = 0
        let windows = i.count / 256
        for window in 0..<windows {
            let range = window * 256..<(window + 1) * 256
            let meanI = i[range].reduce(0, +) / 256, meanQ = q[range].reduce(0, +) / 256
            magnitude += (meanI * meanI + meanQ * meanQ).squareRoot() / Float(windows)
        }
        guard succeeds, magnitude > 0.1 else { return [] }
        return [DecodedMessage(decoder: name, frequencyHz: dwell.detection.frequencyHz, text: "carrier")]
    }
}

struct ScanLoopTests {
    private func loop(tones: [Double], decoder: CarrierDecoder, configure: (inout ScanLoop.Configuration) -> Void = { _ in }) throws
        -> (ScanLoop, SyntheticReceiver) {
        let receiver = SyntheticReceiver(tones: tones.map { .init(frequencyHz: $0, amplitude: 30) }, dcOffsetCodes: 0)
        var scanConfiguration = BandScanner.Configuration(range: 400_000_000...406_000_000)
        scanConfiguration.framesPerHop = 8
        var configuration = ScanLoop.Configuration()
        configure(&configuration)
        return (ScanLoop(scanner: try BandScanner(receiver: receiver, configuration: scanConfiguration), decoders: [decoder],
                         configuration: configuration), receiver)
    }

    @Test func eachDetectionGetsADwellTunedBesideIt() throws {
        let decoder = CarrierDecoder()
        let (scanLoop, _) = try loop(tones: [401_000_000, 404_000_000], decoder: decoder)
        let round = try scanLoop.runRound()
        #expect(round.detections.count == 2 && round.dwells.count == 2)
        for report in round.dwells {
            #expect(report.messages.count == 1, "the carrier was mixed to 0 Hz")
            #expect(abs(Double(report.tunedHz) - report.detection.frequencyHz - 600_000) < 1, "tuned a quarter of the rate above")
        }
    }

    @Test func theCarrierDecoderOnlyHearsACorrectlyMixedDwell() throws {
        let decoder = CarrierDecoder()
        let (scanLoop, _) = try loop(tones: [402_000_000], decoder: decoder)
        var dwell = try #require(try scanLoop.listen(to: Detection(frequencyHz: 402_000_000, powerDB: -20, noiseFloorDB: -50, bandwidthHz: 2000), for: 0.01))
        #expect(decoder.decode(dwell).count == 1)
        dwell.signalOffsetHz = 0                          // as if the offset had been forgotten
        #expect(decoder.decode(dwell).isEmpty)
    }

    @Test func aFrequencyThatDecodesNothingIsSkippedForTheLockoutRounds() throws {
        let decoder = CarrierDecoder()
        decoder.succeeds = false
        let (scanLoop, _) = try loop(tones: [402_000_000], decoder: decoder) { $0.lockoutRounds = 2 }
        let dwellCounts = try (1...5).map { _ in try scanLoop.runRound().dwells.count }
        #expect(dwellCounts == [1, 0, 0, 1, 0])
    }

    @Test func onlyDetectionsADecoderWantsGetADwell() throws {
        let decoder = CarrierDecoder()
        decoder.interest = 403_000_000...406_000_000
        let (scanLoop, _) = try loop(tones: [401_000_000, 404_000_000], decoder: decoder)
        let round = try scanLoop.runRound()
        #expect(round.dwells.map { Int($0.detection.frequencyHz / 1_000_000) } == [404])
    }

    @Test func dwellsPerRoundAreCappedStrongestFirst() throws {
        let decoder = CarrierDecoder()
        let receiverTones = [400_500_000.0, 401_500_000, 402_500_000, 403_500_000]
        let (scanLoop, receiver) = try loop(tones: receiverTones, decoder: decoder) { $0.maximumDwellsPerRound = 2 }
        receiver.tones[2].amplitude = 60
        let round = try scanLoop.runRound()
        #expect(round.dwells.count == 2)
        #expect(round.dwells.first.map { Int($0.detection.frequencyHz / 100_000) } == 4025)
    }

    @Test func nearTheTopOfTheTunerRangeTheOffsetFlipsBelow() throws {
        let decoder = CarrierDecoder()
        let (scanLoop, _) = try loop(tones: [], decoder: decoder) { $0.tunableRange = 24_000_000...402_300_000 }
        let dwell = try #require(try scanLoop.listen(to: Detection(frequencyHz: 402_000_000, powerDB: -20, noiseFloorDB: -50, bandwidthHz: 2000), for: 0.001))
        #expect(dwell.tunedHz == 401_400_000 && dwell.signalOffsetHz == 600_000)
    }
}

struct CarrierCalibratorTests {
    /// u8 I/Q of a carrier at `carrierHz` as a dongle whose crystal is `ppm` fast sees it when tuned to `tunedHz`.
    private func capture(carrierHz: Double, tunedHz: Double, ppm: Double, rate: Double, seconds: Double) -> [UInt8] {
        let offset = carrierHz / (1 + ppm * 1e-6) - tunedHz
        var state: UInt64 = 7
        func noise() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Double(state >> 40) / Double(1 << 24) - 0.5
        }
        let count = Int(rate * seconds)
        var bytes = [UInt8](repeating: 0, count: 2 * count)
        for n in 0..<count {
            let phase = 2 * Double.pi * offset * Double(n) / rate
            bytes[2 * n] = UInt8(max(0, min(255, (127.5 + 12 * cos(phase) + 40 * noise()).rounded())))
            bytes[2 * n + 1] = UInt8(max(0, min(255, (127.5 + 12 * sin(phase) + 40 * noise()).rounded())))
        }
        return bytes
    }

    @Test(arguments: [23.7, -61.25, 0.4])
    func theCrystalErrorIsMeasured(ppm: Double) throws {
        let carrier = 162_550_000.0, rate = 1_024_000.0, tuned = carrier - rate / 4
        let calibrator = try #require(CarrierCalibrator(sampleRate: rate, tunedHz: tuned, carrierHz: carrier, fftSize: 1 << 16))
        let samples = capture(carrierHz: carrier, tunedHz: tuned, ppm: ppm, rate: rate, seconds: 0.4)
        stride(from: 0, to: samples.count, by: 100_001).forEach {           // odd pieces, as a stream gives them
            calibrator.process(iq: Array(samples[$0..<min(samples.count, $0 + 100_001)]))
        }
        let m = try #require(calibrator.measurement())
        #expect(abs(m.ppm - ppm) < 0.02, "measured \(m.ppm)")
        #expect(m.snrDB > 20 && m.transforms == 6)
    }

    @Test func noTransformYetGivesNoMeasurement() throws {
        let calibrator = try #require(CarrierCalibrator(sampleRate: 1_024_000, tunedHz: 100e6, carrierHz: 100.25e6, fftSize: 1 << 12))
        calibrator.process(iq: [UInt8](repeating: 128, count: 1000))
        #expect(calibrator.measurement() == nil)
    }

    @Test func atscPilots() {
        #expect(CarrierCalibrator.atscPilotHz(channel: 14) == 470_309_440.559)
        #expect(CarrierCalibrator.atscPilotHz(channel: 7) == 174_309_440.559)
        #expect(CarrierCalibrator.atscPilotHz(channel: 5) == 76_309_440.559)
        #expect(CarrierCalibrator.atscPilotHz(channel: 37) == nil)
    }
}
