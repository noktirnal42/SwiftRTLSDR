// SPDX-License-Identifier: GPL-2.0-or-later
//
// M10 and M20 reception: frame synchronisation and bit decisions on a discriminator's output or a tone statistic.
// Written for this package.
import Foundation

/// Finds M10 and M20 frames in frequency-demodulated samples or in `FMFrontEnd`'s tone statistic.
///
/// The header (32 symbols) is found by a Pearson correlation with symbol integrals, as for the DFM. The bits after it
/// are Manchester coded (a bit is the second symbol's integral minus the first's) and then differentially coded (a data
/// bit is 1 where two bits in a row are alike), so polarity does not matter, and are read most significant bit first.
/// The first byte says how long the frame is; the last two are a checksum, which is what accepts a frame. Sondes send at
/// 9600 or at about 9616 symbols a second, which would walk a fixed clock off the data within a frame, so the frame is
/// read at a grid of rates, the one that gave the last good frame first, until one has a valid checksum.
public final class M10FrameSync {
    public struct Found: Sendable {
        public var frame: M10Frame
        /// Where the header starts, in samples since the stream began.
        public var sampleIndex: Double
        /// The header correlation (1 is perfect).
        public var correlation: Double
        /// The signal had the opposite polarity to the one the header pattern is written in.
        public var inverted: Bool
        /// The symbol rate the frame came out at.
        public var symbolRate: Double
        /// The frame's mean level: for a discriminator in hertz, the carrier offset.
        public var mean: Double
    }

    public typealias Input = SymbolInput

    public let sampleRate: Double
    public let input: SymbolInput
    public var threshold = 0.65
    /// Headers found whose frames had no valid checksum at any rate (noise, or a signal too weak to decode).
    public private(set) var rejected = 0
    /// The symbol rate of the last frame with a valid checksum.
    public private(set) var lastSymbolRate: Double?
    let samplesPerSymbol: Double
    private var buffer: SymbolBuffer
    private var searchFrom = 0.0

    /// The rates tried, as multiples of 9600: a fine grid, because a quarter of a symbol over a 1700-symbol frame is
    /// 150 parts per million.
    private static let rateGrid: [Double] = {
        let steps = Array(-30...30)
        return steps.sorted { abs($0) < abs($1) }.map { 1 + Double($0) * 0.00012 }
    }()

    public init(sampleRate: Double, input: SymbolInput = .frequency) {
        self.sampleRate = sampleRate
        self.input = input
        samplesPerSymbol = sampleRate / M10.symbolRate
        buffer = SymbolBuffer(input: input, samplesPerSymbol: samplesPerSymbol)
    }

    public func process(_ values: [Float], frequency: [Float]? = nil) -> [Found] {
        buffer.append(values, frequency: frequency)
        var found: [Found] = []
        let headerSpan = Double(M10.headerSymbols.count + 1) * samplesPerSymbol
        while searchFrom + headerSpan + samplesPerSymbol < Double(buffer.count) {
            // The first 12 symbols sort out most places cheaply.
            guard abs(buffer.correlation(of: M10.headerSymbols, at: searchFrom, symbols: 12)) >= 0.5 else { searchFrom += 1; continue }
            let r = buffer.correlation(of: M10.headerSymbols, at: searchFrom)
            guard abs(r) >= threshold else { searchFrom += 1; continue }
            var best = (start: searchFrom, r: r)
            var offset = -samplesPerSymbol
            while offset <= samplesPerSymbol {
                let start = searchFrom + offset
                if start >= 0 && start + headerSpan + samplesPerSymbol < Double(buffer.count) {
                    let candidate = buffer.correlation(of: M10.headerSymbols, at: start)
                    if abs(candidate) > abs(best.r) { best = (start, candidate) }
                }
                offset += 0.25
            }
            let data = best.start + Double(M10.headerSymbols.count) * samplesPerSymbol
            // The length byte, at the nominal rate (sixteen symbols cannot drift).
            guard data + 16 * samplesPerSymbol + samplesPerSymbol < Double(buffer.count) else { break }
            let polarity: Float = best.r < 0 ? -1 : 1
            guard let first = bytes(at: data, rate: M10.symbolRate, count: 1, polarity: polarity).first,
                  first >= 0x40, Int(first) <= M10.m10Length + M10.maxExtra else {
                rejected += 1
                searchFrom = best.start + samplesPerSymbol
                continue
            }
            let count = Int(first) + 1
            guard data + Double(count * 16) * samplesPerSymbol * 1.01 + samplesPerSymbol < Double(buffer.count) else { break }
            if let item = decode(data: data, start: best.start, count: count, polarity: polarity, correlation: best.r) {
                found.append(item)
                searchFrom = data + Double(count * 16) * samplesPerSymbol / (item.symbolRate / M10.symbolRate)
            } else {
                rejected += 1
                searchFrom = best.start + samplesPerSymbol
            }
        }
        let dropped = buffer.trim(before: searchFrom)
        searchFrom -= Double(dropped)
        return found
    }

    /// The frame at `data` (the first symbol after the header) at the first rate that gives a valid checksum.
    private func decode(data: Double, start: Double, count: Int, polarity: Float, correlation r: Double) -> Found? {
        var rates = Self.rateGrid.map { M10.symbolRate * $0 }
        if let last = lastSymbolRate { rates.insert(last, at: 0) }
        for rate in rates {
            for flip: Float in [1, -1] {
                let raw = bytes(at: data, rate: rate, count: count, polarity: polarity * flip)
                guard let frame = M10Frame(bytes: raw), frame.length == count - 1, frame.kind != nil, frame.isValid else { continue }
                lastSymbolRate = rate
                let period = sampleRate / rate
                let mean = buffer.meanFrequency(from: data, to: data + Double(count * 16) * period)
                return Found(frame: frame, sampleIndex: Double(buffer.base) + start, correlation: abs(r), inverted: (r < 0) != (flip < 0),
                             symbolRate: rate, mean: mean)
            }
        }
        return nil
    }

    /// `count` bytes from the symbols at `data`, read at `rate`: Manchester, then differential, most significant bit
    /// first.
    private func bytes(at data: Double, rate: Double, count: Int, polarity: Float) -> [UInt8] {
        let period = sampleRate / rate
        var out = [UInt8](repeating: 0, count: count)
        var previous = 0
        for n in 0..<(count * 8) {
            let first = buffer.symbol(data + Double(2 * n) * period, period: period)
            let second = buffer.symbol(data + Double(2 * n + 1) * period, period: period)
            let bit = Float(second - first) * polarity > 0 ? 1 : 0
            if 1 ^ (bit ^ previous) == 1 { out[n >> 3] |= 0x80 >> UInt8(n & 7) }
            previous = bit
        }
        return out
    }
}

/// One M10 or M20 frame received, with the report it gives.
public struct M10Event: Sendable {
    public var frame: M10Frame
    public var report: M10Report?
    public var sampleIndex: Double
    public var correlation: Double
    public var inverted: Bool
    public var symbolRate: Double
    /// Carrier offset from where the receiver listened, hertz (I/Q input only).
    public var frequencyOffsetHz: Double?
}

/// Receives M10 and M20 radiosondes from u8 I/Q (tuned near the sonde) or from FM audio.
///
/// The I/Q path is an `FMFrontEnd` giving the tone statistic (or the frequency) at about 96 kHz with a ±9 kHz channel
/// (the signal deviates about 4.3 kHz at 9600 symbols a second); each valid frame fine-tunes the listening frequency.
public final class M10Receiver {
    public let decoder: M10Decoder
    public let sync: M10FrameSync
    private let front: FMFrontEnd?
    private let tones: Bool
    private static let afcLimitHz = 2_000.0

    /// The tones' distance from the carrier, hertz: the signal's deviation.
    public static let defaultDeviationHz = 4_320.0

    /// I/Q input at `sampleRate`, the sonde `offsetHz` above the tuned frequency.
    public init(sampleRate: Double, offsetHz: Double = 0, channelCutoffHz: Double = 9_000, deviationHz: Double = M10Receiver.defaultDeviationHz,
                useTones: Bool = true, decoder: M10Decoder = M10Decoder()) {
        self.decoder = decoder
        tones = useTones
        let rate = FMFrontEnd.audioRate(sampleRate: sampleRate, targetAudioRate: 96_000)
        let detector = useTones ? FMFrontEnd.ToneDetector(offsetHz: deviationHz, window: Int((rate / M10.symbolRate).rounded())) : nil
        let front = FMFrontEnd(sampleRate: sampleRate, offsetHz: offsetHz, channelCutoffHz: channelCutoffHz,
                               targetAudioRate: 96_000, searchSpanHz: 11_000, tones: detector)
        self.front = front
        sync = M10FrameSync(sampleRate: front.audioRate, input: useTones ? .tones : .frequency)
    }

    /// FM-demodulated audio at `audioRate` (a WAV from a scanner or SDR program).
    public init(audioRate: Double, decoder: M10Decoder = M10Decoder()) {
        self.decoder = decoder
        front = nil
        tones = false
        sync = M10FrameSync(sampleRate: audioRate)
    }

    public var listeningOffsetHz: Double { front?.listeningOffsetHz ?? 0 }
    public var lastSearch: (offsetHz: Double, snrDB: Double)? { front?.lastSearch }
    public var rejectedHeaders: Int { sync.rejected }

    public func process(iq block: [UInt8]) -> [M10Event] {
        guard let front else { preconditionFailure("this receiver was made for audio") }
        let (frequency, statistic) = front.processBlock(iq: block)
        return handle(tones ? sync.process(statistic, frequency: frequency) : sync.process(frequency))
    }

    public func process(audio: [Float]) -> [M10Event] {
        precondition(front == nil, "this receiver was made for I/Q")
        return handle(sync.process(audio))
    }

    private func handle(_ found: [M10FrameSync.Found]) -> [M10Event] {
        found.map { item in
            var offset: Double?
            if let front {
                offset = front.listeningOffset(atSample: item.sampleIndex) + item.mean
                // A valid checksum is as clear a sign as there is; but only a carrier already near is followed (a clipped
                // tone biases a discriminator's mean), a carrier far off is for the carrier search to bring in.
                if abs(item.mean) < Self.afcLimitHz { front.listen(at: offset!) }
                front.noteGoodFrame()
            }
            return M10Event(frame: item.frame, report: decoder.report(item.frame), sampleIndex: item.sampleIndex * Double(front?.decimation ?? 1),
                            correlation: item.correlation, inverted: item.inverted, symbolRate: item.symbolRate, frequencyOffsetHz: offset)
        }
    }
}
