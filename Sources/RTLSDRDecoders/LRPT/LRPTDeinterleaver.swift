// SPDX-License-Identifier: GPL-2.0-or-later
//
// The 80 ksym/s LRPT mode that Meteor-M N2-3 and N2-4 sometimes use: the channel bits go through a convolutional
// interleaver of 36 branches, and every 72 interleaved bits follow an 8-bit marker. The deinterleaver (its branch
// delays and memory layout) is ported from meteor_decode by dbdexter-dev (MIT, `deinterleave/deinterleave.c`; notice in
// NOTICE). The marker synchronisation is new: meteor_decode correlates hard bits with themselves one marker apart and
// knows four rotations; this correlates the soft samples with the marker under all eight rotations and mirrors a QPSK or
// OQPSK demodulator can settle in, 64 markers at a time, and follows slips of the symbol clock. See PROVENANCE.md.

/// Deinterleaves the 80k LRPT mode's soft samples (I then Q, as the demodulator gives them) for `LRPTDecoder`.
///
/// What comes out is the channel bit stream of the 72k mode, about 18 s (`latency` samples) later: the interleaver holds
/// that much, so the first frames need that long to appear, and `flush()` pushes out the rest at the end of a recording.
public final class LRPTDeinterleaver {
    public static let markerSpacing = 80
    static let markerLength = 8
    static let dataLength = 72
    static let branches = 36
    /// Samples a branch's delay grows by: each branch's cells (2048 of them) hold one sample every 36.
    let step: Int
    /// Samples from entering the interleaver to leaving the deinterleaver (what the last branch adds, the first takes):
    /// 2 580 480, about 18 s of the 80k mode.
    public let latency: Int
    /// The marker's bits (0x27) as soft signs (bit 1 is negative), I then Q.
    static let marker: [Int] = (0..<8).map { 0x27 >> (7 - $0) & 1 == 1 ? -1 : 1 }
    /// Samples searched for markers at a time.
    static let window = 64 * markerSpacing

    // Deinterleaver.
    private var memory: [Int8]
    private var written = 0                         // data samples written so far, modulo the memory size
    private var branch = 0                          // position in the current block of 72

    // Marker synchronisation.
    private var buffer: [Int8] = []
    private var bufferStart = 0                     // stream index of buffer[0]
    private var nextMarker: Int?                    // stream index of the next marker; nil until acquired
    private var transform = 0
    /// How well the last window's markers matched where they were expected, 0 … 1 (1: every sample's sign right).
    public private(set) var markerScore = 0.0
    /// Times the markers were found away from where the last ones put them (symbol slips, phase jumps).
    public private(set) var resynchronisations = 0
    public var isSynchronised: Bool { nextMarker != nil }

    public convenience init() { self.init(branchDelay: 2048) }

    /// `branchDelay` cells a branch (2048 in the satellites' interleaver; smaller for tests).
    init(branchDelay: Int) {
        step = Self.branches * branchDelay
        latency = (Self.branches - 1) * step
        memory = [Int8](repeating: 0, count: Self.branches * step)
    }

    public func process(_ soft: [Int8]) -> [Int8] {
        buffer += soft
        var output: [Int8] = []
        output.reserveCapacity(soft.count)
        let reach = Self.markerSpacing / 2
        while true {
            if nextMarker == nil {
                // Acquire: the best of all 80 phases over a window.
                guard buffer.count >= reach + Self.window + reach else { break }
                let best = search(around: reach)
                var first = reach + best.offset
                if first < reach { first += Self.markerSpacing }        // room before it for a slip backwards
                nextMarker = bufferStart + first
                transform = best.transform
                markerScore = best.score
            }
            guard let marker = nextMarker else { break }
            var local = marker - bufferStart
            guard local - reach >= 0, local + reach + Self.window <= buffer.count else { break }
            // Where are the markers of this window? Follow the best phase and rotation: the marker looks almost the same
            // turned half a circle as turned a quarter and moved a sample (7 of its 8 samples agree), so a wide margin
            // would keep the wrong one after a phase jump. 64 markers tell the two apart by several standard deviations
            // even at 0 dB; a window that straddles a jump may pick wrongly, and the next one puts it right.
            let best = search(around: local)
            let current = score(around: local, offset: 0, transform: transform)
            if best.score > current + 0.02 && (best.offset != 0 || best.transform != transform) {
                local += best.offset
                transform = best.transform
                resynchronisations += 1
                markerScore = best.score
            } else {
                markerScore = current
            }
            guard local + Self.window <= buffer.count else { nextMarker = bufferStart + local; break }
            for block in 0..<(Self.window / Self.markerSpacing) {
                deinterleave(block: local + block * Self.markerSpacing + Self.markerLength, into: &output)
            }
            nextMarker = bufferStart + local + Self.window
            // Keep half a marker spacing before the next marker, for a slip backwards.
            let drop = local + Self.window - reach
            buffer.removeFirst(drop)
            bufferStart += drop
        }
        return output
    }

    /// The samples still in the deinterleaver (and whole blocks still waiting for their window), pushed out with
    /// erasures behind them: for the end of a recording.
    public func flush() -> [Int8] {
        var output: [Int8] = []
        if let marker = nextMarker {
            var local = marker - bufferStart
            while local + Self.markerSpacing <= buffer.count {
                deinterleave(block: local + Self.markerLength, into: &output)
                local += Self.markerSpacing
            }
        }
        buffer = []
        nextMarker = nil
        let zeros = [Int8](repeating: 0, count: Self.dataLength)
        for _ in 0..<((latency + Self.dataLength - 1) / Self.dataLength) { core(zeros, into: &output) }
        return output
    }

    // MARK: Markers

    /// The best marker phase near `local` (−39 … +40 samples) and rotation, by soft correlation over a window.
    private func search(around local: Int) -> (offset: Int, transform: Int, score: Double) {
        var best = (offset: 0, transform: 0, score: -2.0)
        for offset in (1 - Self.markerSpacing / 2)...(Self.markerSpacing / 2) {
            let (sums, magnitude) = markerSums(at: local + offset)
            for t in 0..<8 {
                let s = Self.score(sums, magnitude, transform: t)
                if s > best.score { best = (offset, t, s) }
            }
        }
        return best
    }

    private func score(around local: Int, offset: Int, transform t: Int) -> Double {
        let (sums, magnitude) = markerSums(at: local + offset)
        return Self.score(sums, magnitude, transform: t)
    }

    /// The window's samples at each of the 8 marker positions added up, and their total magnitude.
    private func markerSums(at start: Int) -> ([Int], Int) {
        var sums = [Int](repeating: 0, count: Self.markerLength)
        var magnitude = 0
        var at = start
        for _ in 0..<(Self.window / Self.markerSpacing) {
            for k in 0..<Self.markerLength {
                let v = Int(buffer[at + k])
                sums[k] += v
                magnitude += abs(v)
            }
            at += Self.markerSpacing
        }
        return (sums, magnitude)
    }

    /// Agreement of those samples with the marker as `transform` shows it, −1 … 1.
    static func score(_ sums: [Int], _ magnitude: Int, transform t: Int) -> Double {
        var total = 0
        for pair in 0..<4 {
            let (x, y) = apply(t, marker[2 * pair], marker[2 * pair + 1])
            total += x * sums[2 * pair] + y * sums[2 * pair + 1]
        }
        return magnitude > 0 ? Double(total) / Double(magnitude) : 0
    }

    /// The eight ways a demodulator can settle on a QPSK constellation: four rotations, and four mirrored (an OQPSK
    /// loop a quarter turn off also moves the pairs one sample, which the marker phase takes care of).
    static func apply(_ t: Int, _ x: Int, _ y: Int) -> (Int, Int) {
        switch t {
        case 0: return (x, y)
        case 1: return (-y, x)
        case 2: return (-x, -y)
        case 3: return (y, -x)
        case 4: return (x, -y)
        case 5: return (y, x)
        case 6: return (-x, y)
        default: return (-y, -x)
        }
    }

    /// Which transform undoes each one.
    static let inverse = [0, 3, 2, 1, 4, 5, 6, 7]

    // MARK: Deinterleaving

    /// Undoes the rotation on one block's 72 data samples (from `start` in the buffer) and deinterleaves them.
    private func deinterleave(block start: Int, into output: inout [Int8]) {
        let undo = Self.inverse[transform]
        var data = [Int8](repeating: 0, count: Self.dataLength)
        for pair in 0..<(Self.dataLength / 2) {
            let x = Int(max(-127, buffer[start + 2 * pair])), y = Int(max(-127, buffer[start + 2 * pair + 1]))
            let (a, b) = Self.apply(undo, x, y)
            data[2 * pair] = Int8(a)
            data[2 * pair + 1] = Int8(b)
        }
        core(data, into: &output)
    }

    /// meteor_decode's deinterleaver: a sample on branch b is written b × 36 × 2048 cells back from the write position,
    /// and the output is read 36 × 2048 cells ahead of it, so branch b waits (35 − b) × 36 × 2048 samples.
    private func core(_ data: [Int8], into output: inout [Int8]) {
        let size = memory.count
        var read = (written + step) % size
        for sample in data {
            let delay = (branch % Self.branches) * step
            memory[(written - delay + size) % size] = sample
            written = (written + 1) % size
            branch = (branch + 1) % Self.dataLength
        }
        for _ in 0..<data.count {
            output.append(memory[read])
            read = (read + 1) % size
        }
    }
}
