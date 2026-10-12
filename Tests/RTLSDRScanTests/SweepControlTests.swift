// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRScan

/// The progress and cancellation hooks a UI needs to run a long sweep (SH-6): a sweep of a broadcast band is a few
/// hundred retunes, and Stop has to take effect within one hop.
struct SweepControlTests {

    private func makeScanner(_ receiver: SyntheticReceiver) throws -> BandScanner {
        try BandScanner(receiver: receiver, configuration: BandScanner.Configuration(range: 88_000_000...108_000_000))
    }

    @Test func progressIsReportedOnceForEachHopInOrder() throws {
        let receiver = SyntheticReceiver(sampleRate: 2_400_000)
        let scanner = try makeScanner(receiver)
        let centers = scanner.plan.centers
        #expect(centers.count > 4, "the FM band needs several hops at 2.4 MS/s")

        var reports: [SweepProgress] = []
        _ = try scanner.sweep(progress: { reports.append($0) })

        #expect(reports.map(\.hop) == Array(1...centers.count), "1-based, one report per hop, in tuning order")
        #expect(reports.map(\.centerHz) == centers)
        #expect(reports.allSatisfy { $0.hopCount == centers.count && $0.pllLocked })
        #expect(receiver.tuneLog == centers)
    }

    @Test func aCancelledSweepStopsBeforeTheNextHopIsTuned() throws {
        let receiver = SyntheticReceiver(sampleRate: 2_400_000)
        let scanner = try makeScanner(receiver)
        let centers = scanner.plan.centers

        var reports: [SweepProgress] = []
        // Cancellation is consulted before each hop is tuned: after three hops have been reported, hop 4 must not be tuned.
        do {
            _ = try scanner.sweep(progress: { reports.append($0) }, isCancelled: { reports.count >= 3 })
            Issue.record("a cancelled sweep returned a spectrum, which would look like a whole band")
        } catch {
            #expect(error as? ScanError == .cancelled)
        }
        #expect(reports.map(\.hop) == [1, 2, 3])
        #expect(receiver.tuneLog == Array(centers.prefix(3)), "hop 4 was never tuned")
    }

    @Test func aCancelledSweepBeforeTheFirstHopTunesNothing() throws {
        let receiver = SyntheticReceiver(sampleRate: 2_400_000)
        let scanner = try makeScanner(receiver)
        #expect(throws: ScanError.cancelled) { try scanner.sweep(isCancelled: { true }) }
        #expect(receiver.tuneLog.isEmpty)
    }

    @Test func aHopThatDidNotLockIsReportedAsSuchAndTheSweepContinues() throws {
        let receiver = SyntheticReceiver(sampleRate: 2_400_000)
        let scanner = try makeScanner(receiver)
        let second = scanner.plan.centers[1]
        receiver.unlockedFrequencies = [second]

        var reports: [SweepProgress] = []
        _ = try scanner.sweep(progress: { reports.append($0) })
        #expect(reports.count == scanner.plan.centers.count)
        #expect(reports.first(where: { $0.centerHz == second })?.pllLocked == false)
        #expect(scanner.unlockedHops == [second])
    }

    @Test func theDefaultsStillSweepWithoutAnyHooks() throws {
        let receiver = SyntheticReceiver(sampleRate: 2_400_000, tones: [.init(frequencyHz: 95_000_000, amplitude: 40)])
        let scanner = try makeScanner(receiver)
        let spectrum = try scanner.sweep()
        #expect(scanner.detect(in: spectrum).contains { abs($0.frequencyHz - 95_000_000) < 20_000 })
    }
}
