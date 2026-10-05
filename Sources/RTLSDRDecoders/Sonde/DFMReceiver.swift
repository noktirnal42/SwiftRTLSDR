// SPDX-License-Identifier: GPL-2.0-or-later
//
// DFM reception: frame synchronisation and bit decisions on a discriminator's output. Written for this package.
import Foundation

/// Finds DFM frames in frequency-demodulated samples (a discriminator's output, or FM audio from any receiver).
///
/// Each Manchester symbol is the integral of the signal over its period, taken from a running sum so that the
/// samples per symbol need not be a whole number. The header is found by correlating its 32 symbols with such
/// integrals (a Pearson correlation, so offset, level and polarity do not matter), refined to a quarter sample. A bit
/// is the second symbol's integral minus the first's, which also cancels a carrier offset, so each frame's 280 bits
/// come out as soft decisions for the code to use.
///
/// With `FMFrontEnd`'s tone statistic instead of a frequency, the statistic is already an integral over a symbol: the
/// symbol that ends at a sample is the statistic there, and the frequency (which gives the carrier offset) comes along
/// as a second stream.
///
/// The header is short (32 symbols), so noise passes the correlation test now and then; a frame counts only if the
/// code finds at least two of its three blocks intact, or one with a very clean header. After a frame, the next
/// header is looked for where it should be, with a lower bar, because the sonde sends frame after frame without a gap.
public final class DFMFrameSync {
    public struct Found: Sendable {
        public var frame: DFMFrame
        /// Where the frame starts, in samples since the stream began.
        public var sampleIndex: Double
        /// The frame's place in the stream in frames (start over 560 symbols), for dating packets.
        public var frameCount: Double
        /// The header correlation (1 is perfect; the sign is folded into `inverted`).
        public var correlation: Double
        /// The signal had the opposite polarity to the one that decodes the DFM-06 (normally, a 1 is low then high).
        public var inverted: Bool
        /// The frame's mean level: for a discriminator in hertz, the carrier offset.
        public var mean: Double
    }

    /// What `process` is given: a discriminator's frequency (to be integrated over each symbol), or the front end's tone
    /// statistic (a symbol's worth already; its place is the sample where it ends).
    public enum Input: Sendable { case frequency, tones }

    public let sampleRate: Double
    public let input: Input
    public var threshold = 0.65
    /// Frames expected to follow the last one are accepted at this correlation.
    public var trackingThreshold = 0.5
    /// Whether a codeword with two bad bits is replaced by its likeliest neighbour (see `DFMFrame`).
    public var repairTwoBitErrors = false
    /// Headers found whose frames had too little intact (noise, or a signal too weak to decode).
    public private(set) var rejected = 0
    let samplesPerSymbol: Double
    private let frameSpan: Double
    private var samples: [Float] = []
    private var frequencies: [Float] = []           // tones input: the discriminator's frequency, for the carrier offset
    private var frequencyPrefix: [Double] = [0]
    private var prefix: [Double] = [0]              // prefix[n] = Σ samples[0 ..< n]
    private var base = 0                            // stream index of samples[0]
    private var searchFrom = 0.0                    // buffer index where the next header search starts
    private var expected: (start: Double, negative: Bool)?     // where the next frame should start

    public init(sampleRate: Double, input: Input = .frequency) {
        self.sampleRate = sampleRate
        self.input = input
        samplesPerSymbol = sampleRate / DFM.symbolRate
        frameSpan = Double(DFM.frameBits * 2) * samplesPerSymbol
    }

    @inline(__always)
    private func integral(_ x: Double) -> Double {
        let whole = Int(x)
        return prefix[whole] + (x - Double(whole)) * Double(samples[min(whole, samples.count - 1)])
    }

    @inline(__always)
    private func symbol(_ start: Double) -> Double {
        guard input == .tones else { return integral(start + samplesPerSymbol) - integral(start) }
        // The statistic over the window that ends with the symbol's last sample, between two samples.
        let x = start + samplesPerSymbol - 1
        let whole = Int(x), fraction = x - Double(whole)
        return Double(samples[whole]) * (1 - fraction) + Double(samples[min(whole + 1, samples.count - 1)]) * fraction
    }

    /// Pearson correlation of the first `count` header symbols with the integrals from `start` on.
    private func correlation(at start: Double, symbols count: Int = 32) -> Double {
        let header = DFM.headerSymbols
        var sum = 0.0, sumSquares = 0.0, cross = 0.0, sumH = 0.0
        for k in 0..<count {
            let v = symbol(start + Double(k) * samplesPerSymbol), h = header[k]
            sum += v; sumSquares += v * v; cross += v * h; sumH += h
        }
        let n = Double(count)
        let spread = sumSquares - sum * sum / n, spreadH = n - sumH * sumH / n
        guard spread > 0, spreadH > 0 else { return 0 }
        return (cross - sum * sumH / n) / (spread * spreadH).squareRoot()
    }

    @inline(__always)
    private func frequencyIntegral(_ x: Double) -> Double {
        let whole = Int(x)
        return frequencyPrefix[whole] + (x - Double(whole)) * Double(frequencies[min(whole, frequencies.count - 1)])
    }

    /// The samples a frame at `start` needs, past its end by one symbol.
    @inline(__always)
    private func hasFrame(at start: Double) -> Bool { start + frameSpan + samplesPerSymbol < Double(samples.count) }

    /// Adds samples: a discriminator's frequency (`.frequency`), or the statistic (`.tones`, which also needs the
    /// frequency, one value for each, for the carrier offset).
    public func process(_ values: [Float], frequency: [Float]? = nil) -> [Found] {
        samples.reserveCapacity(samples.count + values.count)
        prefix.reserveCapacity(prefix.count + values.count)
        var running = prefix[prefix.count - 1]
        for value in values {
            samples.append(value)
            running += Double(value)
            prefix.append(running)
        }
        if input == .tones, let frequency {
            precondition(frequency.count == values.count)
            var total = frequencyPrefix[frequencyPrefix.count - 1]
            for value in frequency {
                frequencies.append(value)
                total += Double(value)
                frequencyPrefix.append(total)
            }
        }
        var found: [Found] = []
        let headerSpan = Double(DFM.headerSymbols.count + 1) * samplesPerSymbol
        search: while true {
            // Where the last frame says the next one is: a nearby header, with a lower bar.
            if let next = expected {
                guard hasFrame(at: next.start + samplesPerSymbol) else { break }
                var best: (start: Double, r: Double)?
                var offset = -samplesPerSymbol / 4
                while offset <= samplesPerSymbol / 4 {
                    let start = next.start + offset
                    let r = correlation(at: start)
                    if (r < 0) == next.negative && abs(r) >= trackingThreshold && (best == nil || abs(r) > abs(best!.r)) { best = (start, r) }
                    offset += 0.25
                }
                if let best, let item = read(at: best.start, correlation: best.r, minimumIntact: 1) {
                    found.append(item)
                    expected = (best.start + frameSpan, best.r < 0)
                    searchFrom = best.start + frameSpan - 2 * samplesPerSymbol
                    continue search
                }
                expected = nil
                searchFrom = max(searchFrom, next.start - 2 * samplesPerSymbol)
            }
            while searchFrom + headerSpan + samplesPerSymbol < Double(samples.count) {
                // The first 12 symbols sort out most places cheaply.
                guard abs(correlation(at: searchFrom, symbols: 12)) >= 0.5 else { searchFrom += 1; continue }
                let r = correlation(at: searchFrom)
                guard abs(r) >= threshold else { searchFrom += 1; continue }
                var best = (start: searchFrom, r: r)
                var offset = -samplesPerSymbol / 2
                while offset <= samplesPerSymbol / 2 {
                    let start = searchFrom + offset
                    if start >= 0 && start + headerSpan + samplesPerSymbol < Double(samples.count) {
                        let candidate = correlation(at: start)
                        if abs(candidate) > abs(best.r) { best = (start, candidate) }
                    }
                    offset += 0.25
                }
                guard hasFrame(at: best.start) else { break search }
                if let item = read(at: best.start, correlation: best.r, minimumIntact: abs(best.r) >= 0.85 ? 1 : 2) {
                    found.append(item)
                    expected = (best.start + frameSpan, best.r < 0)
                    searchFrom = best.start + frameSpan - 2 * samplesPerSymbol
                    continue search
                }
                rejected += 1
                searchFrom = best.start + samplesPerSymbol
            }
            break
        }
        trim()
        return found
    }

    /// The frame at `start`, if enough of its blocks came through the code.
    private func read(at start: Double, correlation r: Double, minimumIntact: Int) -> Found? {
        let polarity: Float = r < 0 ? -1 : 1
        var soft = [Float](repeating: 0, count: DFM.frameBits)
        for k in 0..<DFM.frameBits {
            let first = symbol(start + Double(2 * k) * samplesPerSymbol)
            let second = symbol(start + Double(2 * k + 1) * samplesPerSymbol)
            soft[k] = Float(second - first) * polarity
        }
        let frame = DFMFrame(soft: soft, repairTwoBitErrors: repairTwoBitErrors)
        guard frame.intactBlocks >= minimumIntact else { return nil }
        let mean: Double
        if input == .tones {
            mean = (frequencyIntegral(start + frameSpan) - frequencyIntegral(start)) / frameSpan
        } else {
            mean = (integral(start + frameSpan) - integral(start)) / frameSpan
        }
        return Found(frame: frame, sampleIndex: Double(base) + start, frameCount: (Double(base) + start) / frameSpan,
                     correlation: abs(r), inverted: r < 0, mean: mean)
    }

    /// Drops what no search can need again (in large steps, so that shifting the buffers stays cheap).
    private func trim() {
        let keep = min(searchFrom, expected.map { $0.start - 2 * samplesPerSymbol } ?? searchFrom)
        let drop = Int(keep) - 16
        guard drop > 100_000 else { return }
        samples.removeFirst(drop)
        let offset = prefix[drop]
        prefix.removeFirst(drop)
        for index in prefix.indices { prefix[index] -= offset }
        if input == .tones {
            frequencies.removeFirst(drop)
            let frequencyOffset = frequencyPrefix[drop]
            frequencyPrefix.removeFirst(drop)
            for index in frequencyPrefix.indices { frequencyPrefix[index] -= frequencyOffset }
        }
        base += drop
        searchFrom -= Double(drop)
        if let next = expected { expected = (next.start - Double(drop), next.negative) }
    }
}

/// One DFM frame received, with the report it completes (about one frame in four).
public struct DFMEvent: Sendable {
    public var frame: DFMFrame
    public var report: DFMReport?
    public var sampleIndex: Double
    public var correlation: Double
    public var inverted: Bool
    /// Carrier offset from where the receiver listened, hertz (I/Q input only).
    public var frequencyOffsetHz: Double?
}

/// Receives DFM-06/09/17 radiosondes from u8 I/Q (tuned near the sonde) or from FM audio.
///
/// The I/Q path is an `FMFrontEnd` with a ±4.5 kHz channel (the signal deviates about 2.4 kHz at 2500 symbols a second)
/// giving the tone statistic (or the frequency) that `DFMFrameSync` reads; once frames arrive, each one fine-tunes the
/// listening frequency.
public final class DFMReceiver {
    /// Keeps each sonde's configuration; share one between receivers (dwells on the same sonde) to keep filling it.
    public let decoder: DFMDecoder
    public let sync: DFMFrameSync
    private let front: FMFrontEnd?
    private let tones: Bool

    /// The tones' distance from the carrier, hertz: the signal's deviation. The sondes' is about 2.4 kHz.
    public static let defaultDeviationHz = 2_400.0

    /// I/Q input at `sampleRate`, the sonde `offsetHz` above the tuned frequency. By default the front end gives the
    /// tone statistic for a signal deviating `deviationHz`, which works to lower signal levels than the discriminator
    /// (`useTones: false`).
    public init(sampleRate: Double, offsetHz: Double = 0, channelCutoffHz: Double = 4_500, deviationHz: Double = DFMReceiver.defaultDeviationHz,
                useTones: Bool = true, decoder: DFMDecoder = DFMDecoder()) {
        self.decoder = decoder
        tones = useTones
        let rate = FMFrontEnd.audioRate(sampleRate: sampleRate, targetAudioRate: 48_000)
        let detector = useTones ? FMFrontEnd.ToneDetector(offsetHz: deviationHz, window: Int((rate / DFM.symbolRate).rounded())) : nil
        let front = FMFrontEnd(sampleRate: sampleRate, offsetHz: offsetHz, channelCutoffHz: channelCutoffHz, tones: detector)
        self.front = front
        sync = DFMFrameSync(sampleRate: front.audioRate, input: useTones ? .tones : .frequency)
    }

    /// FM-demodulated audio at `audioRate` (a WAV from a scanner or SDR program).
    public init(audioRate: Double, decoder: DFMDecoder = DFMDecoder()) {
        self.decoder = decoder
        front = nil
        tones = false
        sync = DFMFrameSync(sampleRate: audioRate)
    }

    public var listeningOffsetHz: Double { front?.listeningOffsetHz ?? 0 }
    public var lastSearch: (offsetHz: Double, snrDB: Double)? { front?.lastSearch }
    public var rejectedHeaders: Int { sync.rejected }

    public func process(iq block: [UInt8]) -> [DFMEvent] {
        guard let front else { preconditionFailure("this receiver was made for audio") }
        let (frequency, statistic) = front.processBlock(iq: block)
        return handle(tones ? sync.process(statistic, frequency: frequency) : sync.process(frequency))
    }

    public func process(audio: [Float]) -> [DFMEvent] {
        precondition(front == nil, "this receiver was made for I/Q")
        return handle(sync.process(audio))
    }

    private func handle(_ found: [DFMFrameSync.Found]) -> [DFMEvent] {
        found.map { item in
            var offset: Double?
            if let front {
                offset = front.listeningOffsetHz + item.mean
                // Follow the sonde: listen where the last clear frame was.
                if item.frame.intactBlocks == 3 && item.correlation >= 0.75 { front.listen(at: offset!) }
                if item.frame.intactBlocks >= 2 { front.noteGoodFrame() }
            }
            return DFMEvent(frame: item.frame, report: decoder.ingest(item.frame, frameCount: item.frameCount),
                            sampleIndex: item.sampleIndex * Double(front?.decimation ?? 1), correlation: item.correlation,
                            inverted: item.inverted, frequencyOffsetHz: offset)
        }
    }
}
