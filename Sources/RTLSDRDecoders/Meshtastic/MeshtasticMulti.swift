// SPDX-License-Identifier: GPL-2.0-or-later
//
// Several Meshtastic presets or channels from one capture: a channelizer for each listener in front of the LoRa
// receiver, and the planning of what a capture can hold. Written for this package.
import Foundation
import Dispatch

/// One thing to listen for: a preset on a channel frequency.
public struct MeshtasticListener: Sendable, Equatable {
    public var preset: MeshtasticPreset
    /// The channel's centre, hertz.
    public var frequencyHz: Double

    public init(preset: MeshtasticPreset, frequencyHz: Double) {
        self.preset = preset
        self.frequencyHz = frequencyHz
    }

    public var parameters: LoRaParameters { preset.parameters }
    public var bandwidth: Double { preset.modulation.bandwidth }
}

/// A frame and the listener that got it.
public struct MeshtasticFrame: Sendable {
    public var listener: MeshtasticListener
    public var frame: LoRaFrame
    /// Where the frame's preamble was found, in input samples since the stream began.
    public var inputSample: Double
    /// The transmitter's frequency, hertz: the channel's centre plus the carrier offset the receiver measured.
    public var carrierHz: Double { listener.frequencyHz + frame.carrierOffsetHz }
}

/// What a capture can hold, and where to put it.
public enum MeshtasticPlan {
    /// The sample rates a capture may use. Each is a whole multiple of every LoRa bandwidth Meshtastic uses (62.5 to
    /// 500 kHz), and the dongle runs both reliably.
    public static let sampleRates = [1_000_000.0, 2_000_000.0]
    /// The share of the sample rate that holds a channel cleanly: the band's edges roll off.
    public static let usableShare = 0.8
    /// A channel's edge must be at least this far from the centre, which has the dongle's DC spike.
    public static let dcGuardHz = 25_000.0

    public struct Capture: Sendable, Equatable {
        public var centerHz: Double
        public var sampleRate: Double
        public init(centerHz: Double, sampleRate: Double) { self.centerHz = centerHz; self.sampleRate = sampleRate }
    }

    public enum Failure: Error, CustomStringConvertible {
        case tooWide(spanHz: Double, limitHz: Double)
        case none
        public var description: String {
            switch self {
            case .tooWide(let span, let limit):
                return String(format: "those channels span %.2f MHz, more than one capture holds (%.2f MHz)", span / 1e6, limit / 1e6)
            case .none: return "nothing to listen for"
            }
        }
    }

    /// The smallest sample rate whose usable band holds every listener's channel with room to keep clear of the DC
    /// spike, and a tuned frequency for it. The centre is as near the middle of the listeners as the spike allows.
    public static func capture(for listeners: [MeshtasticListener]) throws -> Capture {
        guard !listeners.isEmpty else { throw Failure.none }
        let low = listeners.map { $0.frequencyHz - $0.bandwidth / 2 }.min()!
        let high = listeners.map { $0.frequencyHz + $0.bandwidth / 2 }.max()!
        for rate in sampleRates {
            let half = rate * usableShare / 2
            guard high - low <= 2 * half else { continue }
            // Centres from the middle outwards in 12.5 kHz steps, the first that keeps every channel in the band and
            // out of the spike.
            let middle = (low + high) / 2
            for step in 0..<400 {
                for sign in (step == 0 ? [1.0] : [1.0, -1.0]) {
                    let center = (middle + sign * Double(step) * 12_500).rounded()
                    let fits = listeners.allSatisfy { listener in
                        let distance = abs(listener.frequencyHz - center)
                        return distance + listener.bandwidth / 2 <= half && distance - listener.bandwidth / 2 >= dcGuardHz
                    }
                    if fits { return Capture(centerHz: center, sampleRate: rate) }
                }
            }
        }
        let limit = sampleRates.last! * usableShare
        throw Failure.tooWide(spanHz: high - low, limitHz: limit)
    }

    /// Every slot of a region (for `preset`'s bandwidth) whose channel lies in `[lower, upper]`.
    public static func slots(of region: MeshtasticRegion, bandwidth: Double, from lower: Double, to upper: Double) -> [Double] {
        (0..<region.slotCount(bandwidth: bandwidth)).map { region.frequency(slot: $0, bandwidth: bandwidth) }
            .filter { $0 - bandwidth / 2 >= lower && $0 + bandwidth / 2 <= upper }
    }
}

/// Receives several Meshtastic presets or channels from one capture of u8 I/Q.
///
/// Each listener gets a channelizer: the channel is mixed to zero, low-passed (by a windowed sinc that keeps ±0.75
/// bandwidths and stops what would fold into that) and decimated to two or more samples per chip, and a `LoRaReceiver`
/// reads the result. A transmission heard on neighbouring channels (a strong signal leaks over) is reported once, by the
/// listener whose centre it is nearest, and only once if the same payload comes again within a second.
public final class MeshtasticMultiReceiver: @unchecked Sendable {
    /// Why a receiver could not be made for a capture.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// A listener's bandwidth does not divide the capture's sample rate into a whole number of samples a chip.
        case rateNotMultipleOfBandwidth(sampleRate: Double, bandwidth: Double)
        public var description: String {
            switch self {
            case .rateNotMultipleOfBandwidth(let rate, let bandwidth):
                return String(format: "a capture at %.0f S/s cannot hold a %.1f kHz channel: the rate must be a whole multiple of the bandwidth",
                              rate, bandwidth / 1000)
            }
        }
    }

    private final class Channel: @unchecked Sendable {
        let listener: MeshtasticListener
        let receiver: LoRaReceiver
        let decimation: Int
        let channelRate: Double
        private let taps: [Float]
        private var ringI: [Float], ringQ: [Float]       // each twice the filter's length, so that the window is contiguous
        private var position = 0, countdown: Int
        private var oscillator = (1.0, 0.0)
        private let rotation: (Double, Double)
        private var rotations = 0

        init(listener: MeshtasticListener, inputRate: Double, tunedHz: Double) throws {
            self.listener = listener
            let bandwidth = listener.bandwidth
            guard inputRate.isFinite, bandwidth > 0, (inputRate / bandwidth).rounded() >= 1,
                  abs((inputRate / bandwidth).rounded() * bandwidth - inputRate) < 1 else {
                throw Failure.rateNotMultipleOfBandwidth(sampleRate: inputRate, bandwidth: bandwidth)
            }
            // The largest decimation that leaves two or more samples a chip, a whole number of them.
            let ratio = Int((inputRate / bandwidth).rounded())
            var best = 1
            for d in 1...max(1, ratio / 2) where ratio % d == 0 && ratio / d >= 2 { best = d }
            decimation = best
            channelRate = inputRate / Double(best)
            let offset = listener.frequencyHz - tunedHz
            let step = -2 * Double.pi * offset / inputRate
            rotation = (cos(step), sin(step))
            // Windowed sinc: pass ±0.75 bandwidths, stop at the channel rate less that.
            let transition = max(channelRate - 1.5 * bandwidth, 0.25 * bandwidth)
            if best == 1 {
                taps = [1]                                   // no decimation: the LoRa receiver's own filter does it all
            } else {
                let count = Int((3.3 * inputRate / transition).rounded()) | 1
                let cutoff = (0.75 * bandwidth + 0.5 * transition) / inputRate
                let raw: [Double] = (0..<count).map { n in
                    let t = Double(n - count / 2)
                    let sinc = t == 0 ? 2 * cutoff : sin(2 * Double.pi * cutoff * t) / (Double.pi * t)
                    return sinc * (0.54 - 0.46 * cos(2 * Double.pi * Double(n) / Double(count - 1)))
                }
                let gain = raw.reduce(0, +)
                taps = raw.map { Float($0 / gain) }
            }
            let count = taps.count
            ringI = [Float](repeating: 0, count: 2 * count)
            ringQ = [Float](repeating: 0, count: 2 * count)
            countdown = best
            receiver = LoRaReceiver(parameters: listener.parameters, sampleRate: channelRate, offsetHz: 0, centerFrequencyHz: listener.frequencyHz)
        }

        /// Mixes, filters and decimates a block (interleaved I and Q, as complex floats at the channel rate).
        func channelize(_ i: [Float], _ q: [Float]) -> [Float] {
            var out: [Float] = []
            out.reserveCapacity(2 * (i.count / decimation + 1))
            let n = taps.count
            var position = self.position, countdown = self.countdown
            var (c, s) = oscillator
            var rotations = self.rotations
            ringI.withUnsafeMutableBufferPointer { ri in
                ringQ.withUnsafeMutableBufferPointer { rq in
                    taps.withUnsafeBufferPointer { t in
                        for k in 0..<i.count {
                            let x = Float(Double(i[k]) * c - Double(q[k]) * s), y = Float(Double(i[k]) * s + Double(q[k]) * c)
                            (c, s) = (c * rotation.0 - s * rotation.1, c * rotation.1 + s * rotation.0)
                            rotations += 1
                            if rotations == 4096 {                        // keep it on the unit circle
                                let norm = (c * c + s * s).squareRoot()
                                c /= norm; s /= norm
                                rotations = 0
                            }
                            ri[position] = x; ri[position + n] = x
                            rq[position] = y; rq[position + n] = y
                            position += 1
                            if position == n { position = 0 }
                            countdown -= 1
                            guard countdown == 0 else { continue }
                            countdown = decimation
                            // The window is the n samples from `position` in the doubled ring, oldest first (the taps
                            // are symmetric, so the order does not matter).
                            var accI: Float = 0, accQ: Float = 0
                            for j in 0..<n { accI += t[j] * ri[position + j]; accQ += t[j] * rq[position + j] }
                            out.append(accI)
                            out.append(accQ)
                        }
                    }
                }
            }
            self.position = position; self.countdown = countdown
            oscillator = (c, s); self.rotations = rotations
            return out
        }
    }

    /// Where concurrent work leaves its results.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [[LoRaFrame]]
        init(count: Int) { frames = [[LoRaFrame]](repeating: [], count: count) }
        func set(_ index: Int, _ value: [LoRaFrame]) { lock.lock(); frames[index] = value; lock.unlock() }
        func all() -> [[LoRaFrame]] { lock.lock(); defer { lock.unlock() }; return frames }
    }

    private let channels: [Channel]
    public let sampleRate: Double
    public let centerHz: Double
    private var leftover: UInt8?
    private var recent: [(payload: [UInt8], sample: Double, listener: Int)] = []
    private var inputSamples = 0.0

    /// Listeners for I/Q at `sampleRate` tuned to `centerHz`. Throws `Failure.rateNotMultipleOfBandwidth` when the rate
    /// is not a whole multiple of a listener's bandwidth.
    public init(listeners: [MeshtasticListener], sampleRate: Double, centerHz: Double) throws {
        self.sampleRate = sampleRate
        self.centerHz = centerHz
        channels = try listeners.map { try Channel(listener: $0, inputRate: sampleRate, tunedHz: centerHz) }
    }

    /// A receiver for a capture planned by `MeshtasticPlan`.
    public convenience init(listeners: [MeshtasticListener], capture: MeshtasticPlan.Capture) throws {
        try self.init(listeners: listeners, sampleRate: capture.sampleRate, centerHz: capture.centerHz)
    }

    public var listeners: [MeshtasticListener] { channels.map(\.listener) }

    /// Frames from a block of interleaved u8 I/Q; a block may end between the I and Q of a sample.
    public func process(iq block: [UInt8]) -> [MeshtasticFrame] {
        var bytes = block
        if let i = leftover { bytes.insert(i, at: 0); leftover = nil }
        if bytes.count % 2 == 1 { leftover = bytes.removeLast() }
        let count = bytes.count / 2
        var i = [Float](repeating: 0, count: count), q = [Float](repeating: 0, count: count)
        for k in 0..<count { i[k] = Float(bytes[2 * k]) - 127.5; q[k] = Float(bytes[2 * k + 1]) - 127.5 }

        let box = ResultBox(count: channels.count)
        let channels = self.channels
        let samplesI = i, samplesQ = q
        if channels.count > 1 {
            DispatchQueue.concurrentPerform(iterations: channels.count) { index in
                box.set(index, channels[index].receiver.process(complex: channels[index].channelize(samplesI, samplesQ)))
            }
        } else if let channel = channels.first {
            box.set(0, channel.receiver.process(complex: channel.channelize(i, q)))
        }
        inputSamples += Double(count)
        var found: [(index: Int, frame: LoRaFrame, sample: Double)] = []
        for (index, frames) in box.all().enumerated() {
            for frame in frames { found.append((index, frame, frame.sampleIndex * Double(channels[index].decimation))) }
        }
        return dedupe(found).map { MeshtasticFrame(listener: channels[$0.index].listener, frame: $0.frame, inputSample: $0.sample) }
    }

    /// One report for a payload heard by several listeners: the one whose centre the carrier is nearest. A payload
    /// already reported in the last second is a repeat.
    private func dedupe(_ found: [(index: Int, frame: LoRaFrame, sample: Double)]) -> [(index: Int, frame: LoRaFrame, sample: Double)] {
        let window = sampleRate        // one second of input samples
        recent.removeAll { inputSamples - $0.sample > 3 * window }
        var kept: [(index: Int, frame: LoRaFrame, sample: Double)] = []
        for item in found {
            guard item.frame.crcValid == true else { kept.append(item); continue }
            if let at = kept.firstIndex(where: { $0.frame.crcValid == true && $0.frame.payload == item.frame.payload && abs($0.sample - item.sample) < window }) {
                if abs(item.frame.carrierOffsetHz) < abs(kept[at].frame.carrierOffsetHz) { kept[at] = item }
            } else {
                kept.append(item)
            }
        }
        // A frame whose CRC failed, at the same moment as a good one from another listener of the same preset, is that
        // transmission leaking into a neighbouring slot, not another one.
        let symbols = 3 * Double(1 << 12) / 125_000 * sampleRate        // generous: three symbols of the slowest preset
        let good = kept.filter { $0.frame.crcValid == true }
        kept.removeAll { item in
            guard item.frame.crcValid != true else { return false }
            return good.contains { other in
                other.index != item.index && channels[other.index].listener.preset == channels[item.index].listener.preset
                    && abs(other.sample - item.sample) < symbols
            }
        }
        var out: [(index: Int, frame: LoRaFrame, sample: Double)] = []
        for item in kept {
            if item.frame.crcValid == true {
                if recent.contains(where: { $0.payload == item.frame.payload && abs($0.sample - item.sample) < window && $0.listener != item.index }) { continue }
                recent.append((item.frame.payload, item.sample, item.index))
            }
            out.append(item)
        }
        return out
    }
}
