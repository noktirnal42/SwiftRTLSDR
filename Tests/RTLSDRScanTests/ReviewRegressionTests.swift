// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRScan

/// Regression tests for findings from the review of the section 6 work.
struct ScanRegressionTests {
    @Test func theWholeBandIsUsableWithoutReadingPastTheFFT() throws {
        let plan = try #require(SweepPlan(range: 400_000_000...403_000_000, sampleRate: 2_400_000, fftSize: 1024, usableFraction: 1))
        #expect(plan.usableHalfBins == 511)
        let receiver = SyntheticReceiver(tones: [.init(frequencyHz: 401_000_000, amplitude: 20)])
        var configuration = BandScanner.Configuration(range: 400_000_000...403_000_000)
        configuration.usableFraction = 1
        configuration.framesPerHop = 4
        let scanner = try BandScanner(receiver: receiver, configuration: configuration)
        #expect(scanner.detect(in: try scanner.sweep()).count == 1)
    }

    @Test func hopsNearTheTopOfTheTunerRangeArePulledInsideItAndStayOnTheGrid() throws {
        let tunable = 24_000_000...1_766_000_000
        let plan = try #require(SweepPlan(range: 1_700_000_000...1_766_000_000, sampleRate: 2_400_000, fftSize: 1024, tunableRange: tunable))
        #expect(plan.centers.allSatisfy(tunable.contains))
        #expect(plan.centers.last! > 1_766_000_000 - Int(plan.binWidth), "the last hop sits right at the limit")
        #expect(Set(plan.centers).count == plan.centers.count, "no duplicate hops")

        var stitcher = SpectrumStitcher(plan: plan)
        for index in plan.centers.indices { stitcher.add(hop: index, power: [Double](repeating: 1, count: 1024)) }
        let spectrum = stitcher.spectrum()
        #expect(!spectrum.powerDB.contains { $0.isNaN }, "still no holes")
        #expect(spectrum.frequency(ofBin: spectrum.powerDB.count - 1) > 1_766_000_000 - spectrum.binWidthHz)
    }

    @Test func aCarrierSeenByTheClampedHopLandsInTheRightBin() throws {
        let receiver = SyntheticReceiver(tones: [.init(frequencyHz: 1_765_700_000, amplitude: 20)], dcOffsetCodes: 0)
        var configuration = BandScanner.Configuration(range: 1_760_000_000...1_766_000_000)
        configuration.framesPerHop = 8
        let scanner = try BandScanner(receiver: receiver, configuration: configuration)
        #expect(receiver.tuneLog.isEmpty)
        let found = scanner.detect(in: try scanner.sweep())
        #expect(receiver.tuneLog.allSatisfy { $0 <= 1_766_000_000 })
        #expect(found.count == 1 && abs(found[0].frequencyHz - 1_765_700_000) <= scanner.plan.binWidth)
    }

    @Test func hopsBelowTheTunerRangeArePulledUp() throws {
        let plan = try #require(SweepPlan(range: 20_000_000...30_000_000, sampleRate: 2_400_000, fftSize: 1024, tunableRange: 24_000_000...1_766_000_000))
        #expect(plan.centers.first! >= 24_000_000 && plan.centers.first! < 24_000_000 + Int(plan.binWidth))
        #expect(plan.hopOffsetBins.first == 0 && plan.hopOffsetBins == plan.hopOffsetBins.sorted())
    }

    @Test func aHopThatDoesNotLockIsLeftOutAndReported() throws {
        let plan = try #require(SweepPlan(range: 400_000_000...406_000_000, sampleRate: 2_400_000, fftSize: 1024))
        let bad = plan.centers[3]
        // A carrier a little above the bad hop's centre: a neighbouring hop must still see it.
        let receiver = SyntheticReceiver(tones: [.init(frequencyHz: Double(bad) + 200_000, amplitude: 20)], dcOffsetCodes: 0)
        receiver.unlockedFrequencies = [bad]
        var configuration = BandScanner.Configuration(range: 400_000_000...406_000_000)
        configuration.framesPerHop = 8
        let scanner = try BandScanner(receiver: receiver, configuration: configuration)
        let spectrum = try scanner.sweep()
        #expect(scanner.unlockedHops == [bad])
        let found = scanner.detect(in: spectrum)
        #expect(found.count == 1 && abs(found[0].frequencyHz - Double(bad) - 200_000) <= scanner.plan.binWidth)
    }

    @Test func noDwellHappensOnARetuneThatDoesNotLock() throws {
        let receiver = SyntheticReceiver(tones: [.init(frequencyHz: 402_000_000, amplitude: 30)], dcOffsetCodes: 0)
        receiver.unlockedRanges = [402_590_000...402_610_000]        // where the dwell would tune (the detection is bin-accurate)
        var configuration = BandScanner.Configuration(range: 400_000_000...406_000_000)
        configuration.framesPerHop = 8
        let decoder = CarrierDecoder()
        let scanLoop = ScanLoop(scanner: try BandScanner(receiver: receiver, configuration: configuration), decoders: [decoder])
        let round = try scanLoop.runRound()
        #expect(round.detections.count == 1 && round.dwells.isEmpty && decoder.dwells.isEmpty)
        #expect(!scanLoop.isLockedOut(402_000_000), "an unlocked retune is not the signal's fault")
    }

    @Test func aCarrierInTheLastFewBinsIsNotSwallowedByATinyFloorWindow() {
        var generator = SeededGenerator(state: 9)
        let window = 250                                             // floorWindowHz / binWidth below
        var powers = (0..<(4 * window + 14)).map { _ in -60 + generator.gaussian() }
        for bin in (powers.count - 10)..<powers.count { powers[bin] = -30 }
        let spectrum = Spectrum(startHz: 88_000_000, binWidthHz: 2000, powerDB: powers)
        let found = PeakDetector(floorWindowHz: Double(window) * 2000).detect(in: spectrum)
        #expect(found.count == 1 && found.first!.frequencyHz >= spectrum.frequency(ofBin: powers.count - 10))
    }

    @Test func mergedDetectionsSpanTheRealEdgesOfBothRuns() throws {
        var generator = SeededGenerator(state: 11)
        var powers = (0..<3000).map { _ in -60 + generator.gaussian() }
        for bin in 1000...1004 { powers[bin] = -35 }
        powers[1000] = -25                                           // the peak sits at the run's left edge
        for bin in 1007...1008 { powers[bin] = -30 }                 // 16 kHz away: merges
        let spectrum = Spectrum(startHz: 100_000_000, binWidthHz: 2000, powerDB: powers)
        let found = PeakDetector().detect(in: spectrum)
        let merged = try #require(found.first)
        #expect(found.count == 1 && merged.frequencyHz == spectrum.frequency(ofBin: 1000))
        #expect(merged.bandwidthHz == 18_000, "bins 1000 to 1008 inclusive")
    }
}
