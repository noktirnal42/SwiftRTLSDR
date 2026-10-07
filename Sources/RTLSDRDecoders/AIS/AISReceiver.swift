// SPDX-License-Identifier: GPL-2.0-or-later
//
// AIS reception: GMSK at 9600 bit/s with NRZI and HDLC framing, from the discriminator's audio, on one or both channels.
// Written for this package.
import Foundation

/// Finds AIS frames in FM-demodulated samples.
///
/// A burst starts with 24 bits of 0101… (a clock) and a flag (0x7E): found by a Pearson correlation of the symbol
/// integrals with that pattern as the line carries it (NRZI: a 0 is a change of frequency, a 1 none; the correlation's sign
/// is the signal's polarity, which NRZI does not care about). After it, each bit is whether the symbol repeats the one
/// before; five 1s in a row are followed by a stuffed 0 which is dropped, six 1s and a 0 are a flag that ends the frame,
/// and the frame check sequence (the X.25 CRC, as AVLC has it) is what accepts a frame. At 9600 symbols a second a
/// frame of a thousand bits drifts by a twentieth of a symbol for a clock 50 parts per million off, so the grid found by
/// the header is kept to the end.
public final class AISFrameSync {
    public struct Found: Sendable {
        public var bits: AISBits
        public var sampleIndex: Double
        public var correlation: Double
        /// The frame's mean level: for a discriminator in hertz, the carrier offset.
        public var mean: Double
    }

    public let sampleRate: Double
    public var threshold = 0.7
    /// Headers found whose frames never ended in a flag with a good checksum.
    public private(set) var rejected = 0
    let samplesPerSymbol: Double
    private var buffer: SymbolBuffer
    private var searchFrom = 0.0
    /// The symbols before the data, ±1: the clock and the flag, run through NRZI.
    static let headerSymbols: [Double] = {
        var bits = (0..<24).map { $0 & 1 }                              // 0101… (a 0 first)
        bits += [0, 1, 1, 1, 1, 1, 1, 0]                                // the flag, least significant bit first
        var level = 1.0
        return bits.map { bit in if bit == 0 { level = -level }; return level }
    }()
    static let longestFrameBits = 1_300

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        samplesPerSymbol = sampleRate / AIS.baud
        buffer = SymbolBuffer(input: .frequency, samplesPerSymbol: samplesPerSymbol)
    }

    public func process(_ frequency: [Float]) -> [Found] {
        buffer.append(frequency, frequency: nil)
        var found: [Found] = []
        let sps = samplesPerSymbol
        let header = Self.headerSymbols
        let span = Double(header.count) * sps
        while searchFrom + span + 2 * sps < Double(buffer.count) {
            guard abs(buffer.correlation(of: header, at: searchFrom, symbols: 16)) >= 0.5 else { searchFrom += 1; continue }
            let r = buffer.correlation(of: header, at: searchFrom)
            guard abs(r) >= threshold else { searchFrom += 1; continue }
            var best = (start: searchFrom, r: r)
            var offset = -sps
            while offset <= sps {
                let start = searchFrom + offset
                if start >= 0 && start + span + sps < Double(buffer.count) {
                    let candidate = buffer.correlation(of: header, at: start)
                    if abs(candidate) > abs(best.r) { best = (start, candidate) }
                }
                offset += 0.25
            }
            let data = best.start + span
            // The header is balanced (the clock and the flag), so its mean is the carrier offset the symbols are read against.
            let centre = buffer.meanFrequency(from: best.start, to: data) * sps
            guard let read = readFrame(at: data, centre: centre) else { break }       // the rest has not arrived
            if let bits = read.bits {
                found.append(Found(bits: bits, sampleIndex: Double(buffer.base) + best.start, correlation: abs(best.r),
                                   mean: buffer.meanFrequency(from: best.start, to: read.end)))
                searchFrom = read.end
            } else {
                rejected += 1
                searchFrom = best.start + sps
            }
        }
        let dropped = buffer.trim(before: searchFrom)
        searchFrom -= Double(dropped)
        return found
    }

    /// The frame that starts at `data`, if a flag ends it and its checksum holds (`bits` nil otherwise); nil if more samples
    /// are needed to tell.
    private func readFrame(at data: Double, centre: Double) -> (bits: AISBits?, end: Double)? {
        let sps = samplesPerSymbol
        // The symbol before the data is the flag's last: the NRZI reference.
        var previous = buffer.symbol(data - sps) >= centre
        var payload: [UInt8] = []
        var ones = 0
        for k in 0..<Self.longestFrameBits {
            let at = data + Double(k) * sps
            guard at + sps + 1 < Double(buffer.count) else { return nil }
            let level = buffer.symbol(at) >= centre
            let bit: UInt8 = level == previous ? 1 : 0
            previous = level
            if bit == 1 {
                ones += 1
                payload.append(1)
                if ones >= 7 { return (nil, data + Double(k + 1) * sps) }       // an abort
            } else {
                if ones == 5 {
                    ones = 0                                                    // a stuffed 0
                } else if ones == 6 {
                    // The flag: its first 0 and six 1s are the last seven bits collected.
                    let end = data + Double(k + 1) * sps
                    guard payload.count >= 7 else { return (nil, end) }
                    payload.removeLast(7)
                    return (Self.accept(payload), end)
                } else {
                    payload.append(0)
                    ones = 0
                }
            }
        }
        return (nil, data + Double(Self.longestFrameBits) * sps)
    }

    /// The message of a frame's bits (data and check sequence), if the sequence holds.
    static func accept(_ frame: [UInt8]) -> AISBits? {
        guard frame.count >= 16 + 8, frame.count % 8 == 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: frame.count / 8)
        for (k, bit) in frame.enumerated() where bit == 1 { bytes[k >> 3] |= 1 << UInt8(k & 7) }
        guard AVLCFrame.fcsResidue(bytes) == 0xF0B8 else { return nil }
        return AISBits(bits: Array(frame.dropLast(16)))
    }
}

/// One frame received.
public struct AISEvent: Sendable {
    public var packet: AISPacket
    public var sampleIndex: Double
    public var correlation: Double
    /// Carrier offset from where the receiver listened, hertz (I/Q input only).
    public var frequencyOffsetHz: Double?
}

/// Receives AIS from u8 I/Q (tuned near the channels) or FM audio, on one or several channels.
///
/// Each I/Q channel is an `FMFrontEnd` at about 120 kHz with a ±8 kHz channel (GMSK at 9600 bit/s deviates by ±2.4 kHz); the
/// carrier search is off (a ship's burst lasts 26 ms and a channel is mostly silent), and each frame found re-tunes the
/// receiver by the carrier offset it measured.
public final class AISReceiver {
    public enum Failure: Error, CustomStringConvertible {
        case wrongInput(String)
        public var description: String { switch self { case .wrongInput(let text): return text } }
    }

    private struct Channel {
        let name: String?
        let front: FMFrontEnd?
        let sync: AISFrameSync
    }
    private let channels: [Channel]
    private static let afcLimitHz = 2_000.0

    /// The frequencies (hertz) each channel is at, as `(offset above the tuned frequency, name)`.
    public init(sampleRate: Double, channels: [(offsetHz: Double, name: String?)], channelCutoffHz: Double = 8_000) {
        self.channels = channels.map { channel in
            let front = FMFrontEnd(sampleRate: sampleRate, offsetHz: channel.offsetHz, channelCutoffHz: channelCutoffHz, targetAudioRate: 120_000,
                                   searchSpanHz: 6_000)
            front.searchMoves = false
            return Channel(name: channel.name, front: front, sync: AISFrameSync(sampleRate: front.audioRate))
        }
    }

    /// FM audio at `audioRate`: one channel.
    public init(audioRate: Double, name: String? = nil) {
        channels = [Channel(name: name, front: nil, sync: AISFrameSync(sampleRate: audioRate))]
    }

    public var rejectedHeaders: Int { channels.map(\.sync.rejected).reduce(0, +) }
    public var listeningOffsetsHz: [Double] { channels.map { $0.front?.listeningOffsetHz ?? 0 } }

    public func process(iq block: [UInt8]) throws -> [AISEvent] {
        guard channels.allSatisfy({ $0.front != nil }) else { throw Failure.wrongInput("this receiver was made for audio") }
        var events: [AISEvent] = []
        for channel in channels {
            let front = channel.front!
            for item in channel.sync.process(front.process(iq: block)) {
                let offset = front.listeningOffset(atSample: item.sampleIndex) + item.mean
                if abs(item.mean) < Self.afcLimitHz { front.listen(at: offset) }
                events.append(event(item, channel: channel, offset: offset, decimation: front.decimation))
            }
        }
        return events.sorted { $0.sampleIndex < $1.sampleIndex }                 // in the order they were heard, whatever the channel
    }

    public func process(audio: [Float]) throws -> [AISEvent] {
        guard channels.allSatisfy({ $0.front == nil }) else { throw Failure.wrongInput("this receiver was made for I/Q") }
        return channels.flatMap { channel in channel.sync.process(audio).map { event($0, channel: channel, offset: nil, decimation: 1) } }
    }

    private func event(_ item: AISFrameSync.Found, channel: Channel, offset: Double?, decimation: Int) -> AISEvent {
        AISEvent(packet: AISPacket(bits: item.bits, message: AISMessage(item.bits), channel: channel.name), sampleIndex: item.sampleIndex * Double(decimation),
                 correlation: item.correlation, frequencyOffsetHz: offset)
    }
}
