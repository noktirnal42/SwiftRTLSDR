// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRKit

/// What a scanner needs from a radio. `RTLSDRDevice` provides it; tests use a synthetic one.
public protocol ScanReceiver: AnyObject {
    /// The sample rate in effect, in samples per second.
    var sampleRate: Double { get }
    func tune(to hertz: Int) throws
    /// Whether the most recent `tune(to:)` locked the oscillator; samples from an unlocked retune are off-frequency.
    var pllLocked: Bool { get }
    /// Interleaved unsigned 8-bit I/Q, all sampled after the most recent `tune(to:)` returned.
    func capture(byteCount: Int) throws -> [UInt8]
}

extension RTLSDRDevice: ScanReceiver {
    public func tune(to hertz: Int) throws { try setCenterFrequency(hertz) }

    /// Starts a fresh stream (so nothing sampled before the retune can leak in) with blocks sized to the request.
    public func capture(byteCount: Int) throws -> [UInt8] {
        let block = min(65_536, max(512, (byteCount + 511) / 512 * 512))
        return try readSamples(byteCount: byteCount, blockSize: block)
    }
}

/// Sweeps a frequency range and finds the signals in it.
public final class BandScanner {
    public struct Configuration: Sendable {
        public var range: ClosedRange<Int>
        public var fftSize = 1024
        /// Transforms averaged per hop. More gives a smoother floor and slower sweeps.
        public var framesPerHop = 16
        public var usableFraction = 0.75
        public var dcExclusionHz = 10_000.0
        public var coverDCHoles = true
        /// Samples thrown away after each retune while the oscillator settles. Two milliseconds is a guess: the settling
        /// time has not been measured.
        public var settleSeconds = 0.002
        public var detector = PeakDetector()
        /// Hops are kept inside this range (nil: no limit).
        public var tunableRange: ClosedRange<Int>? = RTLSDRDevice.tunableRange

        public init(range: ClosedRange<Int>) { self.range = range }
    }

    public let receiver: ScanReceiver
    public let configuration: Configuration
    public let plan: SweepPlan
    private let estimator: SpectrumEstimator
    /// Hop centres whose oscillator did not lock in the last sweep. Their bins came only from neighbouring hops (with
    /// overlapping hops, everything but the edges of the swept range).
    public private(set) var unlockedHops: [Int] = []

    public init(receiver: ScanReceiver, configuration: Configuration) throws {
        guard let estimator = SpectrumEstimator(fftSize: configuration.fftSize),
              let plan = SweepPlan(range: configuration.range, sampleRate: receiver.sampleRate, fftSize: configuration.fftSize,
                                   usableFraction: configuration.usableFraction, dcExclusionHz: configuration.dcExclusionHz,
                                   coverDCHoles: configuration.coverDCHoles, tunableRange: configuration.tunableRange)
        else { throw ScanError.invalidConfiguration }
        self.receiver = receiver
        self.configuration = configuration
        self.plan = plan
        self.estimator = estimator
    }

    /// Tunes through every hop once and returns the stitched spectrum.
    ///
    /// `progress` is called once per hop, after that hop is measured (or found unlocked), in tuning order. `isCancelled`
    /// is asked before each hop is tuned, so a cancel takes effect within one hop. A cancelled sweep throws
    /// `ScanError.cancelled` and returns no spectrum: a partial one would look like a whole band.
    public func sweep(
        progress: (SweepProgress) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> Spectrum {
        var stitcher = SpectrumStitcher(plan: plan)
        let settleBytes = Int(configuration.settleSeconds * receiver.sampleRate) * 2
        let wanted = configuration.framesPerHop * configuration.fftSize * 2
        unlockedHops = []
        for (index, center) in plan.centers.enumerated() {
            if isCancelled() { throw ScanError.cancelled }
            try receiver.tune(to: center)
            let locked = receiver.pllLocked
            if locked {
                let bytes = try receiver.capture(byteCount: settleBytes + wanted)
                guard let power = estimator.averagePower(Array(bytes.dropFirst(settleBytes))) else { throw ScanError.shortCapture }
                stitcher.add(hop: index, power: power)
            } else {
                unlockedHops.append(center)
            }
            progress(SweepProgress(hop: index + 1, hopCount: plan.centers.count, centerHz: center, pllLocked: locked))
        }
        return stitcher.spectrum()
    }

    public func detect(in spectrum: Spectrum) -> [Detection] {
        configuration.detector.detect(in: spectrum)
    }
}

/// Where a sweep is, reported after each hop (see `BandScanner.sweep(progress:isCancelled:)`).
public struct SweepProgress: Sendable, Equatable {
    /// The 1-based number of the hop just measured.
    public var hop: Int
    public var hopCount: Int
    /// The hop's centre frequency.
    public var centerHz: Int
    /// Whether the oscillator locked on this hop. An unlocked hop contributes no power of its own.
    public var pllLocked: Bool

    public init(hop: Int, hopCount: Int, centerHz: Int, pllLocked: Bool) {
        self.hop = hop
        self.hopCount = hopCount
        self.centerHz = centerHz
        self.pllLocked = pllLocked
    }
}

public enum ScanError: Error, Equatable, LocalizedError {
    case invalidConfiguration
    case shortCapture
    /// The caller asked a sweep to stop; no spectrum was produced.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The scan settings do not fit together (set a sample rate first; the FFT size must be a power of two; each hop needs usable bins beside its DC gap)."
        case .shortCapture:
            return "The receiver returned fewer samples than one transform needs."
        case .cancelled:
            return "The sweep was stopped before it finished."
        }
    }
}
