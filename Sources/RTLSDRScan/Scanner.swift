// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRKit

/// What a scanner needs from a radio. `RTLSDRDevice` provides it; tests use a synthetic one.
public protocol ScanReceiver: AnyObject {
    /// The sample rate in effect, in samples per second.
    var sampleRate: Double { get }
    func tune(to hertz: Int) throws
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

        public init(range: ClosedRange<Int>) { self.range = range }
    }

    public let receiver: ScanReceiver
    public let configuration: Configuration
    public let plan: SweepPlan
    private let estimator: SpectrumEstimator

    public init(receiver: ScanReceiver, configuration: Configuration) throws {
        guard let estimator = SpectrumEstimator(fftSize: configuration.fftSize),
              let plan = SweepPlan(range: configuration.range, sampleRate: receiver.sampleRate, fftSize: configuration.fftSize,
                                   usableFraction: configuration.usableFraction, dcExclusionHz: configuration.dcExclusionHz,
                                   coverDCHoles: configuration.coverDCHoles)
        else { throw ScanError.invalidConfiguration }
        self.receiver = receiver
        self.configuration = configuration
        self.plan = plan
        self.estimator = estimator
    }

    /// Tunes through every hop once and returns the stitched spectrum.
    public func sweep() throws -> Spectrum {
        var stitcher = SpectrumStitcher(plan: plan)
        let settleBytes = Int(configuration.settleSeconds * receiver.sampleRate) * 2
        let wanted = configuration.framesPerHop * configuration.fftSize * 2
        for (index, center) in plan.centers.enumerated() {
            try receiver.tune(to: center)
            let bytes = try receiver.capture(byteCount: settleBytes + wanted)
            guard let power = estimator.averagePower(Array(bytes.dropFirst(settleBytes))) else { throw ScanError.shortCapture }
            stitcher.add(hop: index, power: power)
        }
        return stitcher.spectrum()
    }

    public func detect(in spectrum: Spectrum) -> [Detection] {
        configuration.detector.detect(in: spectrum)
    }
}

public enum ScanError: Error, Equatable, LocalizedError {
    case invalidConfiguration
    case shortCapture

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The scan settings do not fit together (set a sample rate first; the FFT size must be a power of two; each hop needs usable bins beside its DC gap)."
        case .shortCapture:
            return "The receiver returned fewer samples than one transform needs."
        }
    }
}
