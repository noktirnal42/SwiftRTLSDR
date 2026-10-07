// SPDX-License-Identifier: GPL-2.0-or-later
//
// POCSAG reception: bits from the discriminator's audio, at each of the three bit rates. Written for this package.
import Foundation

/// Turns FM-demodulated audio into bits at a known bit rate: a low-pass filter takes the high-frequency noise a
/// discriminator makes (it rises with frequency, and would put false zero crossings in the timing loop), a slow average
/// takes the carrier offset off, the timing loop is pulled toward the signal's zero crossings, and each bit is the sign of
/// the audio's integral over its period.
public struct BitSlicer {
    public let sampleRate: Double
    public let baud: Double
    let samplesPerBit: Double
    /// The audio's slow average: the carrier's offset from where the receiver listens, hertz.
    public private(set) var average = 0.0
    private let averaging: Double
    private var clock = 0.0                // samples since the bit boundary the loop believes in
    private var sum = 0.0
    private var previousSign = 0.0
    // A second-order Butterworth low-pass at 0.8 of the bit rate (a direct form II transposed biquad).
    private let filter: (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double)
    private var z1 = 0.0, z2 = 0.0
    private var warmedUp = 0

    public init(sampleRate: Double, baud: Double) {
        self.sampleRate = sampleRate
        self.baud = baud
        samplesPerBit = sampleRate / baud
        // About thirty bits: the preamble's alternating bits set the threshold before the first codeword.
        averaging = 1 / (30 * samplesPerBit)
        let w = 2 * Double.pi * min(0.8 * baud, 0.45 * sampleRate) / sampleRate
        let alpha = sin(w) / (2 * 0.7071), a0 = 1 + alpha
        filter = ((1 - cos(w)) / 2 / a0, (1 - cos(w)) / a0, (1 - cos(w)) / 2 / a0, -2 * cos(w) / a0, (1 - alpha) / a0)
    }

    /// The bits the audio completes. A positive audio value (the higher frequency) is a 0, as POCSAG sends it.
    public mutating func process(_ audio: [Float]) -> [UInt8] {
        var bits: [UInt8] = []
        for sample in audio {
            let input = Double(sample)
            let x = filter.b0 * input + z1
            z1 = filter.b1 * input - filter.a1 * x + z2
            z2 = filter.b2 * input - filter.a2 * x
            if warmedUp < Int(2 * samplesPerBit) { average = x; warmedUp += 1 } else { average += averaging * (x - average) }
            let centred = x - average
            let sign: Double = centred >= 0 ? 1 : -1
            if sign != previousSign && previousSign != 0 {
                // A zero crossing should fall on a bit boundary: the clock's error is how far it is from one.
                let error = clock < samplesPerBit / 2 ? clock : clock - samplesPerBit
                clock -= 0.25 * error
            }
            previousSign = sign
            sum += centred
            clock += 1
            if clock >= samplesPerBit {
                clock -= samplesPerBit
                bits.append(sum > 0 ? 0 : 1)
                sum = 0
            }
        }
        return bits
    }
}

/// One page received, with where it was heard.
public struct POCSAGEvent: Sendable {
    public var message: POCSAGMessage
    /// Carrier offset from where the receiver listened, hertz (I/Q input only).
    public var frequencyOffsetHz: Double?
}

/// Receives pages from u8 I/Q (tuned near the channel) or from FM audio, at each of 512, 1200 and 2400 bit/s.
///
/// The I/Q path is an `FMFrontEnd` giving the discriminator's audio at about 48 kHz with a ±8.5 kHz channel (the carrier
/// deviates by ±4.5 kHz); each page found fine-tunes the listening frequency. A paging channel is silent most of the time,
/// so the carrier search is off unless asked for (`searchesForCarrier`): it would move on noise or an adjacent channel.
public final class POCSAGReceiver {
    public enum Failure: Error, CustomStringConvertible {
        case wrongInput(String)
        public var description: String { switch self { case .wrongInput(let text): return text } }
    }

    private var slicers: [BitSlicer]
    private let decoders: [POCSAGDecoder]
    private let front: FMFrontEnd?
    private static let afcLimitHz = 3_000.0

    public var decoder: [POCSAGDecoder] { decoders }

    /// I/Q input at `sampleRate`, the channel `offsetHz` above the tuned frequency.
    public init(sampleRate: Double, offsetHz: Double = 0, channelCutoffHz: Double = 8_500, searchesForCarrier: Bool = false,
                bauds: [Double] = POCSAG.baudRates) {
        let front = FMFrontEnd(sampleRate: sampleRate, offsetHz: offsetHz, channelCutoffHz: channelCutoffHz, targetAudioRate: 48_000,
                               searchSpanHz: 6_000)
        front.searchMoves = searchesForCarrier
        self.front = front
        slicers = bauds.map { BitSlicer(sampleRate: front.audioRate, baud: $0) }
        decoders = bauds.map { POCSAGDecoder(baud: $0) }
    }

    /// FM-demodulated audio at `audioRate`.
    public init(audioRate: Double, bauds: [Double] = POCSAG.baudRates) {
        front = nil
        slicers = bauds.map { BitSlicer(sampleRate: audioRate, baud: $0) }
        decoders = bauds.map { POCSAGDecoder(baud: $0) }
    }

    public var listeningOffsetHz: Double { front?.listeningOffsetHz ?? 0 }
    public var lastSearch: (offsetHz: Double, snrDB: Double)? { front?.lastSearch }

    public func process(iq block: [UInt8]) throws -> [POCSAGEvent] {
        guard let front else { throw Failure.wrongInput("this receiver was made for audio") }
        return handle(audio: front.process(iq: block), front: front)
    }

    public func process(audio: [Float]) throws -> [POCSAGEvent] {
        guard front == nil else { throw Failure.wrongInput("this receiver was made for I/Q") }
        return handle(audio: audio, front: nil)
    }

    private func handle(audio: [Float], front: FMFrontEnd?) -> [POCSAGEvent] {
        var events: [POCSAGEvent] = []
        for index in slicers.indices {
            let bits = slicers[index].process(audio)
            for message in decoders[index].process(bits: bits) {
                var offset: Double?
                if let front {
                    // The audio's average is the carrier's offset; only a small one is followed (a long run of equal bits
                    // moves the average too).
                    let carrier = slicers[index].average
                    offset = front.listeningOffsetHz + carrier
                    if abs(carrier) < Self.afcLimitHz { front.listen(at: offset!) }
                    front.noteGoodFrame()
                }
                events.append(POCSAGEvent(message: message, frequencyOffsetHz: offset))
            }
        }
        return events
    }
}
