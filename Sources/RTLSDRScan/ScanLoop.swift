// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRKit

/// Something that can make sense of a signal the scanner found: a protocol decoder, a recorder, a logger.
public protocol SignalDecoder: AnyObject {
    var name: String { get }
    /// How long to listen to one detection, in seconds.
    var dwellSeconds: Double { get }
    /// Whether this decoder wants a dwell on `detection` (by frequency, bandwidth, strength ...).
    func wants(_ detection: Detection) -> Bool
    /// Called with a dwell's samples. Returns what it recognised; empty means nothing was.
    func decode(_ dwell: Dwell) -> [DecodedMessage]
}

/// The samples of one dwell on a detection, and where the signal sits in them.
public struct Dwell: Sendable {
    public var detection: Detection
    /// Where the receiver was tuned. Deliberately not the signal's frequency, so the signal avoids the DC spike.
    public var tunedHz: Int
    public var sampleRate: Double
    /// The signal's offset from `tunedHz` (detection frequency − tuned frequency).
    public var signalOffsetHz: Double
    /// Interleaved unsigned 8-bit I/Q.
    public var samples: [UInt8]

    public init(detection: Detection, tunedHz: Int, sampleRate: Double, signalOffsetHz: Double, samples: [UInt8]) {
        self.detection = detection
        self.tunedHz = tunedHz
        self.sampleRate = sampleRate
        self.signalOffsetHz = signalOffsetHz
        self.samples = samples
    }

    /// Complex baseband scaled to ±1, mixed so that the detected signal sits at 0 Hz.
    public func basebandIQ() -> (i: [Float], q: [Float]) {
        let count = samples.count / 2
        var i = [Float](repeating: 0, count: count), q = [Float](repeating: 0, count: count)
        // Multiply by e^(−2πj·offset·n/rate), stepping a unit phasor (renormalised now and then against drift).
        let step = -2 * Double.pi * signalOffsetHz / sampleRate
        let stepRe = cos(step), stepIm = sin(step)
        var re = 1.0, im = 0.0
        for n in 0..<count {
            let x = (Double(samples[2 * n]) - 127.5) / 127.5, y = (Double(samples[2 * n + 1]) - 127.5) / 127.5
            i[n] = Float(x * re - y * im)
            q[n] = Float(x * im + y * re)
            (re, im) = (re * stepRe - im * stepIm, re * stepIm + im * stepRe)
            if n % 1024 == 1023 {
                let magnitude = (re * re + im * im).squareRoot()
                re /= magnitude
                im /= magnitude
            }
        }
        return (i, q)
    }
}

/// One thing a decoder recognised.
public struct DecodedMessage: Sendable, Equatable {
    public var decoder: String
    public var frequencyHz: Double
    public var text: String

    public init(decoder: String, frequencyHz: Double, text: String) {
        self.decoder = decoder
        self.frequencyHz = frequencyHz
        self.text = text
    }
}

/// Scan, then decode: sweep the range, pick the strongest signals a decoder is interested in, listen to each for a
/// while, and remember which frequencies gave nothing so the next rounds skip them for a time. This is the loop
/// `radiosonde_auto_rx` runs (peak search, then decode); the decoders are pluggable and none ships yet.
public final class ScanLoop {
    public struct Configuration: Sendable {
        /// How far from the signal to tune for a dwell, as a fraction of the sample rate. 0.25 puts the signal halfway
        /// between the DC spike and the band edge.
        public var dwellOffsetFraction = 0.25
        public var maximumDwellsPerRound = 4
        /// A frequency whose dwell decoded nothing is skipped for this many rounds.
        public var lockoutRounds = 3
        /// Detections this close count as the same signal (for lockouts and for remembering successes).
        public var sameSignalHz = 25_000.0
        /// Dwells never tune outside this range; the offset flips to the other side instead.
        public var tunableRange: ClosedRange<Int> = RTLSDRDevice.tunableRange

        public init() {}
    }

    /// What one dwell produced.
    public struct DwellReport: Sendable {
        public var detection: Detection
        public var decoder: String
        public var tunedHz: Int
        public var messages: [DecodedMessage]
    }

    /// What one round saw and did.
    public struct Round: Sendable {
        public var number: Int
        public var spectrum: Spectrum
        public var detections: [Detection]
        public var dwells: [DwellReport]
    }

    public let scanner: BandScanner
    public let configuration: Configuration
    private let decoders: [SignalDecoder]
    private var round = 0
    /// Frequencies to skip, and the first round in which they may be tried again.
    private var lockouts: [(frequencyHz: Double, untilRound: Int)] = []
    /// Frequencies that decoded something, and when they last did.
    private var successes: [(frequencyHz: Double, round: Int)] = []

    public init(scanner: BandScanner, decoders: [SignalDecoder], configuration: Configuration = Configuration()) {
        self.scanner = scanner
        self.decoders = decoders
        self.configuration = configuration
    }

    /// Whether `frequency` is currently skipped.
    public func isLockedOut(_ frequency: Double) -> Bool {
        lockouts.contains { abs($0.frequencyHz - frequency) < configuration.sameSignalHz && $0.untilRound > round }
    }

    /// Runs one round: a sweep, then dwells.
    public func runRound() throws -> Round {
        round += 1
        lockouts.removeAll { $0.untilRound <= round }
        let spectrum = try scanner.sweep()
        let detections = scanner.detect(in: spectrum)

        // Signals that decoded before go first, then the strongest.
        func decodedBefore(_ detection: Detection) -> Bool {
            successes.contains { abs($0.frequencyHz - detection.frequencyHz) < configuration.sameSignalHz }
        }
        let candidates = detections
            .filter { !isLockedOut($0.frequencyHz) }
            .sorted { (decodedBefore($0) ? 1 : 0, $0.snrDB) > (decodedBefore($1) ? 1 : 0, $1.snrDB) }

        var dwells: [DwellReport] = []
        for detection in candidates {
            guard dwells.count < configuration.maximumDwellsPerRound else { break }
            guard let decoder = decoders.first(where: { $0.wants(detection) }) else { continue }
            let dwell = try listen(to: detection, for: decoder.dwellSeconds)
            let messages = decoder.decode(dwell)
            dwells.append(DwellReport(detection: detection, decoder: decoder.name, tunedHz: dwell.tunedHz, messages: messages))
            successes.removeAll { abs($0.frequencyHz - detection.frequencyHz) < configuration.sameSignalHz }
            if messages.isEmpty {
                lockouts.append((detection.frequencyHz, round + 1 + configuration.lockoutRounds))
            } else {
                successes.append((detection.frequencyHz, round))
            }
        }
        return Round(number: round, spectrum: spectrum, detections: detections, dwells: dwells)
    }

    /// Tunes beside the signal and records it.
    func listen(to detection: Detection, for seconds: Double) throws -> Dwell {
        let receiver = scanner.receiver
        let offset = Int((configuration.dwellOffsetFraction * receiver.sampleRate).rounded())
        let frequency = Int(detection.frequencyHz.rounded())
        var tuned = frequency + offset
        if !configuration.tunableRange.contains(tuned) { tuned = frequency - offset }
        try receiver.tune(to: tuned)
        let settleBytes = Int(scanner.configuration.settleSeconds * receiver.sampleRate) * 2
        let wanted = max(2, Int(seconds * receiver.sampleRate) * 2)
        let bytes = try receiver.capture(byteCount: settleBytes + wanted)
        return Dwell(detection: detection, tunedHz: tuned, sampleRate: receiver.sampleRate,
                     signalOffsetHz: detection.frequencyHz - Double(tuned), samples: Array(bytes.dropFirst(settleBytes)))
    }
}
