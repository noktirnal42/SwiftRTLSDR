// SPDX-License-Identifier: GPL-2.0-or-later
//
// iMet reception: the audio's two tones, the asynchronous bytes they carry and the frames those make. Written for this
// package.
import Foundation

/// Reads the iMet's audio frequency shift keying: for every audio sample, how much more of the last bit's worth of audio
/// is the 1200 Hz tone than the 2200 Hz one.
///
/// Each tone has a running correlation with a rotating reference over the window of one bit (the non-coherent matched
/// filter for each tone); the statistic is the difference of their magnitudes, positive for a 1. A slow average is
/// subtracted from the audio first: a carrier that is off frequency puts a constant into the discriminator's output, and
/// a constant leaks into the 2200 Hz correlation (which is not a whole number of cycles long).
public struct IMetToneDetector {
    public let sampleRate: Double
    let window: Int
    private var markPhase = 0.0, spacePhase = 0.0
    private let markStep: Double, spaceStep: Double
    private var markRing: [(Double, Double)], spaceRing: [(Double, Double)]
    private var markSum = (0.0, 0.0), spaceSum = (0.0, 0.0)
    private var index = 0
    private var average = 0.0
    private let averaging: Double
    private var sinceResum = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        window = max(4, Int((sampleRate / IMet.baud).rounded()))
        markStep = 2 * .pi * IMet.markHz / sampleRate
        spaceStep = 2 * .pi * IMet.spaceHz / sampleRate
        markRing = [(Double, Double)](repeating: (0, 0), count: window)
        spaceRing = markRing
        averaging = 1 / max(1, 0.003 * sampleRate)
    }

    /// One statistic per sample of `audio` (frequency in hertz or any FM audio).
    public mutating func process(_ audio: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: audio.count)
        for (n, sample) in audio.enumerated() {
            average += averaging * (Double(sample) - average)
            let x = Double(sample) - average
            markPhase += markStep; if markPhase > 2 * .pi { markPhase -= 2 * .pi }
            spacePhase += spaceStep; if spacePhase > 2 * .pi { spacePhase -= 2 * .pi }
            let m = (x * cos(markPhase), -x * sin(markPhase)), s = (x * cos(spacePhase), -x * sin(spacePhase))
            markSum.0 += m.0 - markRing[index].0; markSum.1 += m.1 - markRing[index].1
            spaceSum.0 += s.0 - spaceRing[index].0; spaceSum.1 += s.1 - spaceRing[index].1
            markRing[index] = m; spaceRing[index] = s
            index += 1; if index == window { index = 0 }
            let magnitudeMark = (markSum.0 * markSum.0 + markSum.1 * markSum.1).squareRoot()
            let magnitudeSpace = (spaceSum.0 * spaceSum.0 + spaceSum.1 * spaceSum.1).squareRoot()
            out[n] = Float((magnitudeMark - magnitudeSpace) / Double(window))
            // A running sum that adds and subtracts forever drifts by rounding: start it again now and then.
            sinceResum += 1
            if sinceResum == 1 << 18 { resum(); sinceResum = 0 }
        }
        return out
    }

    private mutating func resum() {
        markSum = markRing.reduce((0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1) }
        spaceSum = spaceRing.reduce((0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1) }
    }
}

/// Finds iMet frames in the tone statistic.
///
/// A frame starts with the idle line (the 1200 Hz tone) and the first byte, 0x01, as an asynchronous character. The
/// header is found by a Pearson correlation of the bit integrals with that pattern; the bytes after it are read one
/// character at a time, each aligned afresh to its start bit (the sonde's clock and the receiver's differ, and a
/// frame is a thousand bits long), until the line goes idle. The packets' checksums are what accept a frame.
public final class IMetFrameSync {
    public struct Found: Sendable {
        public var frame: IMetFrame
        /// Where the header starts, in samples since the stream began.
        public var sampleIndex: Double
        /// The header correlation (1 is perfect).
        public var correlation: Double
        /// The frame's mean audio level, hertz for a discriminator: the carrier offset.
        public var mean: Double
    }

    public let sampleRate: Double
    public var threshold = 0.7
    /// Headers found whose frames had no packet with a good checksum.
    public private(set) var rejected = 0
    let samplesPerBit: Double
    private var buffer: SymbolBuffer
    private var searchFrom = 0.0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        samplesPerBit = sampleRate / IMet.baud
        buffer = SymbolBuffer(input: .tones, samplesPerSymbol: samplesPerBit)
    }

    /// `statistic` is the tone detector's output for `audio`'s samples; `audio` gives the carrier offset.
    public func process(_ statistic: [Float], audio: [Float]) -> [Found] {
        buffer.append(statistic, frequency: audio)
        var found: [Found] = []
        let sps = samplesPerBit
        let headerBits = IMet.headerSymbols.count
        while searchFrom + Double(headerBits + 2) * sps < Double(buffer.count) {
            // The start bit, the 1 after it and the 0 after that, with the last idle bit before and the stop bit at the end:
            // most places fail here, cheaply.
            func level(_ bit: Int, from start: Double) -> Double { buffer.symbol(start + Double(bit) * sps) }
            guard level(IMet.idleMarks - 1, from: searchFrom) > 0, level(IMet.idleMarks, from: searchFrom) < 0,
                  level(IMet.idleMarks + 1, from: searchFrom) > 0, level(IMet.idleMarks + 2, from: searchFrom) < 0,
                  level(headerBits - 1, from: searchFrom) > 0 else { searchFrom += 1; continue }
            let r = buffer.correlation(of: IMet.headerSymbols, at: searchFrom)
            guard r >= threshold else { searchFrom += 1; continue }
            var best = (start: searchFrom, r: r)
            var offset = -sps
            while offset <= sps {
                let start = searchFrom + offset
                if start >= 0 && start + Double(headerBits + 1) * sps < Double(buffer.count) {
                    let candidate = buffer.correlation(of: IMet.headerSymbols, at: start)
                    if candidate > best.r { best = (start, candidate) }
                }
                offset += 0.25
            }
            guard let read = readFrame(header: best.start) else { break }       // the rest has not arrived
            let frame = IMetFrame(bytes: read.bytes)
            if frame.packets.isEmpty {
                rejected += 1
                searchFrom = best.start + sps
                continue
            }
            let mean = buffer.meanFrequency(from: best.start, to: read.end)
            found.append(Found(frame: frame, sampleIndex: Double(buffer.base) + best.start, correlation: best.r, mean: mean))
            searchFrom = read.end
        }
        let dropped = buffer.trim(before: searchFrom)
        searchFrom -= Double(dropped)
        return found
    }

    /// The bytes after the header at `header` (the first byte, 0x01, among them), up to the idle line or the longest frame,
    /// and where they end; nil if the samples that decide have not arrived.
    private func readFrame(header: Double) -> (bytes: [UInt8], end: Double)? {
        let sps = samplesPerBit
        var bytes: [UInt8] = [IMet.soh]
        var start = header + Double(IMet.idleMarks) * sps            // the start bit of the byte being read
        while bytes.count < IMet.maxFrameBytes {
            let nominal = start + 10 * sps
            guard nominal + 11.5 * sps + 2 < Double(buffer.count) else { return nil }
            // The character's alignment: within half a bit of where the last one left off, the one that puts the start
            // bit at the space tone, the stop bit at the mark tone and the most energy in the data bits.
            var best = (shift: 0.0, score: -Double.infinity)
            var shift = -0.5 * sps
            while shift <= 0.5 * sps {
                let at = nominal + shift
                var score = buffer.symbol(at + 9 * sps) - buffer.symbol(at)
                for bit in 1...8 { score += abs(buffer.symbol(at + Double(bit) * sps)) }
                if score > best.score { best = (shift, score) }
                shift += 0.125 * sps
            }
            let at = nominal + best.shift
            guard buffer.symbol(at) < 0 else { break }              // no start bit: the line is idle
            var byte: UInt8 = 0
            for bit in 0..<8 where buffer.symbol(at + Double(bit + 1) * sps) > 0 { byte |= 1 << UInt8(bit) }
            bytes.append(byte)
            start = at
        }
        return (bytes, start + 10 * sps)
    }
}

/// One iMet frame received, with the report it gives.
public struct IMetEvent: Sendable {
    public var frame: IMetFrame
    public var report: IMetReport?
    public var sampleIndex: Double
    public var correlation: Double
    /// Carrier offset from where the receiver listened, hertz (I/Q input only).
    public var frequencyOffsetHz: Double?
}

/// Receives iMet radiosondes from u8 I/Q (tuned near the sonde) or from FM audio.
///
/// The I/Q path is an `FMFrontEnd` giving the discriminator's audio at about 48 kHz with a ±5 kHz channel (the carrier
/// is modulated by the 1200 and 2200 Hz tones with a deviation of about ±3 kHz); each frame fine-tunes the listening
/// frequency.
public final class IMetReceiver {
    public let decoder: IMetDecoder
    public let sync: IMetFrameSync
    private var tones: IMetToneDetector
    private let front: FMFrontEnd?
    private static let afcLimitHz = 2_500.0

    /// I/Q input at `sampleRate`, the sonde `offsetHz` above the tuned frequency.
    public init(sampleRate: Double, offsetHz: Double = 0, channelCutoffHz: Double = 5_000, decoder: IMetDecoder = IMetDecoder()) {
        self.decoder = decoder
        let front = FMFrontEnd(sampleRate: sampleRate, offsetHz: offsetHz, channelCutoffHz: channelCutoffHz, targetAudioRate: 48_000,
                               searchSpanHz: 5_000)
        self.front = front
        tones = IMetToneDetector(sampleRate: front.audioRate)
        sync = IMetFrameSync(sampleRate: front.audioRate)
    }

    /// FM-demodulated audio at `audioRate` (a WAV from a scanner or SDR program).
    public init(audioRate: Double, decoder: IMetDecoder = IMetDecoder()) {
        self.decoder = decoder
        front = nil
        tones = IMetToneDetector(sampleRate: audioRate)
        sync = IMetFrameSync(sampleRate: audioRate)
    }

    public var listeningOffsetHz: Double { front?.listeningOffsetHz ?? 0 }
    public var lastSearch: (offsetHz: Double, snrDB: Double)? { front?.lastSearch }
    public var rejectedHeaders: Int { sync.rejected }

    public func process(iq block: [UInt8]) throws -> [IMetEvent] {
        guard let front else { throw Failure.wrongInput("this receiver was made for audio") }
        let audio = front.process(iq: block)
        return handle(sync.process(tones.process(audio), audio: audio))
    }

    public func process(audio: [Float]) throws -> [IMetEvent] {
        guard front == nil else { throw Failure.wrongInput("this receiver was made for I/Q") }
        return handle(sync.process(tones.process(audio), audio: audio))
    }

    public enum Failure: Error, CustomStringConvertible {
        case wrongInput(String)
        public var description: String { switch self { case .wrongInput(let text): return text } }
    }

    private func handle(_ found: [IMetFrameSync.Found]) -> [IMetEvent] {
        found.map { item in
            var offset: Double?
            if let front {
                offset = front.listeningOffset(atSample: item.sampleIndex) + item.mean
                // Only a carrier already near is followed; one far off is for the carrier search to bring in.
                if abs(item.mean) < Self.afcLimitHz { front.listen(at: offset!) }
                front.noteGoodFrame()
            }
            return IMetEvent(frame: item.frame, report: decoder.report(item.frame), sampleIndex: item.sampleIndex * Double(front?.decimation ?? 1),
                             correlation: item.correlation, frequencyOffsetHz: offset)
        }
    }
}
