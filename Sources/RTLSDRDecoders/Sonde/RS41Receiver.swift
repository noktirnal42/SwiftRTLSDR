// SPDX-License-Identifier: GPL-2.0-or-later
//
// RS41 reception: FM discriminator, frame synchronisation and bit decisions. Written for this package.
import Foundation

/// Finds RS41 frames in frequency-demodulated samples (a discriminator's output, or FM audio from any receiver).
///
/// Each bit is the integral of the signal over one bit period, taken from a running sum so that the samples per bit
/// need not be a whole number. The header is found by correlating 64 such integrals, a bit apart, with the header's
/// bits (a Pearson correlation, so offset, level and polarity do not matter), refined to a quarter sample; the frame's
/// bits are then read at that timing, with the frame's own mean as the decision level (the whitened data is balanced).
/// A "frame" with nothing intact in it (no codeword repaired, no block's CRC good) was a false header: the search goes
/// on from just after it rather than a frame later, so that a real header close behind is not skipped.
public final class RS41FrameSync {
    public struct Found: Sendable {
        /// The frame's bytes as received (still whitened).
        public var raw: [UInt8]
        /// The frame dewhitened, corrected and split into blocks.
        public var frame: RS41Frame
        /// Where the frame starts, in samples since the stream began.
        public var sampleIndex: Double
        /// The header correlation (1 is perfect; negative polarity is folded in).
        public var correlation: Double
        /// The frame's mean level: for a discriminator in hertz, the carrier offset.
        public var mean: Double
    }

    public let sampleRate: Double
    public var threshold = 0.65
    /// Headers found whose frames had nothing intact (noise, or a signal too weak to decode).
    public private(set) var rejected = 0
    let samplesPerBit: Double
    private var samples: [Float] = []
    private var prefix: [Double] = [0]              // prefix[n] = Σ samples[0 ..< n]
    private var base = 0                            // stream index of samples[0]
    private var searchFrom = 0.0                    // buffer index where the next header search starts

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        samplesPerBit = sampleRate / Double(RS41.baudRate)
    }

    /// Σ samples over [x0, x1), for fractional positions (the samples taken as steps).
    @inline(__always)
    private func area(_ x0: Double, _ x1: Double) -> Double { integral(x1) - integral(x0) }

    @inline(__always)
    private func integral(_ x: Double) -> Double {
        let whole = Int(x)
        return prefix[whole] + (x - Double(whole)) * Double(samples[min(whole, samples.count - 1)])
    }

    @inline(__always)
    private func bit(_ start: Double) -> Double { area(start, start + samplesPerBit) }

    /// Pearson correlation of the first `count` header bits with the bit integrals from `start` on.
    private func correlation(at start: Double, bits count: Int = RS41.headerBits.count) -> Double {
        let bits = RS41.headerBits
        var sum = 0.0, sumSquares = 0.0, cross = 0.0, sumH = 0.0
        for k in 0..<count {
            let v = bit(start + Double(k) * samplesPerBit), h = Double(bits[k])
            sum += v; sumSquares += v * v; cross += v * h; sumH += h
        }
        let n = Double(count)
        let spread = sumSquares - sum * sum / n, spreadH = n - sumH * sumH / n
        guard spread > 0, spreadH > 0 else { return 0 }
        return (cross - sum * sumH / n) / (spread * spreadH).squareRoot()
    }

    public func process(_ input: [Float]) -> [Found] {
        samples.reserveCapacity(samples.count + input.count)
        prefix.reserveCapacity(prefix.count + input.count)
        var running = prefix[prefix.count - 1]
        for value in input {
            samples.append(value)
            running += Double(value)
            prefix.append(running)
        }
        var found: [Found] = []
        let headerSpan = Double(RS41.headerBits.count + 1) * samplesPerBit
        let standardSpan = Double(RS41.standardFrameBytes * 8 + 1) * samplesPerBit
        while searchFrom + headerSpan + samplesPerBit < Double(samples.count) {
            // The first 16 bits sort out most places cheaply (noise passes 0.5 about one time in twenty).
            guard abs(correlation(at: searchFrom, bits: 16)) >= 0.5 else { searchFrom += 1; continue }
            let r = correlation(at: searchFrom)
            guard abs(r) >= threshold else { searchFrom += 1; continue }
            // Refine: the best correlation within half a bit either side, in quarter samples.
            var best = (start: searchFrom, r: r)
            var offset = -samplesPerBit / 2
            while offset <= samplesPerBit / 2 {
                let start = searchFrom + offset
                if start >= 0 && start + headerSpan + samplesPerBit < Double(samples.count) {
                    let candidate = correlation(at: start)
                    if abs(candidate) > abs(best.r) { best = (start, candidate) }
                }
                offset += 0.25
            }
            // Wait for the whole frame (an extended one if byte 56 says so).
            guard best.start + standardSpan < Double(samples.count) else { break }
            var bytes = read(from: best.start, count: RS41.standardFrameBytes, polarity: best.r)
            if (bytes[RS41.messageStart] ^ RS41.whitening[RS41.messageStart]) == 0xf0 {
                let extendedSpan = Double(RS41.extendedFrameBytes * 8 + 1) * samplesPerBit
                guard best.start + extendedSpan < Double(samples.count) else { break }
                bytes = read(from: best.start, count: RS41.extendedFrameBytes, polarity: best.r)
            }
            let frame = RS41Frame(raw: bytes)
            guard frame.corrected != nil || frame.blocks.values.contains(where: \.valid) else {
                rejected += 1
                searchFrom = best.start + samplesPerBit
                continue
            }
            let span = Double(bytes.count * 8) * samplesPerBit
            let mean = area(best.start, best.start + span) / span
            found.append(Found(raw: bytes, frame: frame, sampleIndex: Double(base) + best.start, correlation: abs(best.r), mean: mean))
            searchFrom = best.start + span
        }
        trim()
        return found
    }

    /// Bytes from bit decisions at `start`, least significant bit first.
    private func read(from start: Double, count: Int, polarity: Double) -> [UInt8] {
        let bits = count * 8
        var values = [Double](repeating: 0, count: bits)
        for k in 0..<bits { values[k] = bit(start + Double(k) * samplesPerBit) }
        let level = values.reduce(0, +) / Double(bits)
        var bytes = [UInt8](repeating: 0, count: count)
        for k in 0..<bits where (values[k] - level) * polarity > 0 { bytes[k >> 3] |= 1 << UInt8(k & 7) }
        return bytes
    }

    /// Drops what no search can need again (in large steps, so that shifting the buffers stays cheap).
    private func trim() {
        let drop = Int(searchFrom) - 16
        guard drop > 100_000 else { return }
        samples.removeFirst(drop)
        let offset = prefix[drop]
        prefix.removeFirst(drop)
        for index in prefix.indices { prefix[index] -= offset }
        base += drop
        searchFrom -= Double(drop)
    }
}

/// One RS41 frame received, with the report it gives if its blocks are intact.
public struct RS41Event: Sendable {
    public var frame: RS41Frame
    public var report: RS41Report?
    public var sampleIndex: Double
    public var correlation: Double
    /// Carrier offset from where the receiver listened, hertz (I/Q input only).
    public var frequencyOffsetHz: Double?
}

/// Receives RS41 radiosondes from u8 I/Q (tuned near the sonde) or from FM audio.
///
/// The I/Q path is an `FMFrontEnd` with a ±3.7 kHz channel (the bandwidth rs41mod uses on real sondes: about ±2.4 kHz
/// deviation and little noise) giving the frequency that `RS41FrameSync` reads; once frames arrive, each header found
/// fine-tunes the listening frequency.
public final class RS41Receiver {
    /// Keeps each sonde's calibration; share one between receivers (dwells on the same sonde) to keep filling it.
    public let decoder: RS41Decoder
    private let sync: RS41FrameSync
    private let front: FMFrontEnd?

    /// I/Q input at `sampleRate`, the sonde `offsetHz` above the tuned frequency.
    public init(sampleRate: Double, offsetHz: Double = 0, channelCutoffHz: Double = 3_700, decoder: RS41Decoder = RS41Decoder()) {
        self.decoder = decoder
        let front = FMFrontEnd(sampleRate: sampleRate, offsetHz: offsetHz, channelCutoffHz: channelCutoffHz)
        self.front = front
        sync = RS41FrameSync(sampleRate: front.audioRate)
    }

    /// FM-demodulated audio at `audioRate` (a WAV from a scanner or SDR program).
    public init(audioRate: Double, decoder: RS41Decoder = RS41Decoder()) {
        self.decoder = decoder
        front = nil
        sync = RS41FrameSync(sampleRate: audioRate)
    }

    /// Where the receiver is listening, relative to the tuned frequency (it follows the sonde's drift).
    public var listeningOffsetHz: Double { front?.listeningOffsetHz ?? 0 }

    /// The last carrier search: offset from where the receiver was listening (hertz) and how far the signal stood
    /// above the noise (dB); nil until the first half second.
    public var lastSearch: (offsetHz: Double, snrDB: Double)? { front?.lastSearch }

    /// Headers found whose frames had nothing intact.
    public var rejectedHeaders: Int { sync.rejected }

    public func process(iq block: [UInt8]) -> [RS41Event] {
        guard let front else { preconditionFailure("this receiver was made for audio") }
        return handle(sync.process(front.process(iq: block)))
    }

    public func process(audio: [Float]) -> [RS41Event] {
        precondition(front == nil, "this receiver was made for I/Q")
        return handle(sync.process(audio))
    }

    private func handle(_ found: [RS41FrameSync.Found]) -> [RS41Event] {
        found.map { item in
            let frame = item.frame
            var offset: Double?
            if let front {
                offset = front.listeningOffsetHz + item.mean
                // Follow the sonde: listen where the last clear header was.
                if frame.corrected != nil || item.correlation >= 0.75 { front.listen(at: offset!) }
                if frame.corrected != nil { front.noteGoodFrame() }
            }
            return RS41Event(frame: frame, report: decoder.report(frame), sampleIndex: item.sampleIndex * Double(front?.decimation ?? 1),
                             correlation: item.correlation, frequencyOffsetHz: offset)
        }
    }
}
