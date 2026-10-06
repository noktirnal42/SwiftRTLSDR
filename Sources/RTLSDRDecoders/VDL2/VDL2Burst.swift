// SPDX-License-Identifier: GPL-2.0-or-later
//
// VDL Mode 2 bursts: the bits after the synchronisation sequence, to AVLC frames. Written for this package from the
// format as dumpvdl2 by Tomasz Lemiech (GPL-3.0) implements it, read for these facts only; see PROVENANCE.md.
import Foundation

/// The layer between the D8PSK symbols and the AVLC frames.
///
/// After the 16 synchronisation symbols come 25 header bits (three reserved, zero; the burst's length in bits, 17 bits
/// least significant first; five check bits of a (25, 20) code), then the data octets and Reed-Solomon (255, 249) check
/// octets, interleaved by column over the blocks; everything after the synchronisation is scrambled. The data are a bit
/// stream of HDLC frames between flags, bit-stuffed, each octet least significant bit first.
public enum VDL2Burst {
    static let headerLength = 25
    static let symbolRate = 10_500.0
    /// The bits each phase step carries (step k·π/4), first bit the most significant: a Gray code.
    static let gray: [UInt8] = [0, 1, 3, 2, 6, 7, 5, 4]
    /// The phase steps of the synchronisation sequence (in π/4), from the last ramp-up symbol.
    static let syncSteps: [Int] = [0, 3, 2, 4, 0, 1, 6, 4, 1, 7, 2, 5, 6, 5, 7, 3]
    /// The header code's check matrix, one row per check bit; bit 24 is the first header bit.
    static let checkRows: [UInt32] = [0b0000000011111111111110000, 0b0011111100001111111101000, 0b1100011100110000111100100,
                                      0b1101101101010011001100010, 0b0110100111100101010100001]
    static let code = ReedSolomon(length: 255, parityCount: 6)
    /// Bursts longer than this (bits) are taken for a false start: in practice they stay far shorter.
    static let longest = 0x3FFF, longestCorrected = 0x1FFF

    // MARK: Header

    static func syndrome(_ word: UInt32) -> UInt32 {
        checkRows.enumerated().reduce(0) { $0 | UInt32((word & $1.element).nonzeroBitCount & 1) << (4 - $1.offset) }
    }

    /// The burst length in bits from the 25 header bits (the first in bit 24), with one wrong bit repaired; nil if the
    /// header is beyond that. The three reserved bits are zero by definition, so they are taken as zero whatever
    /// arrives (dumpvdl2 does the same); a repair therefore reaches the other 22 bits.
    ///
    /// With `reliability` (one figure per header bit, larger is surer), the repair is the one or two bits whose turning
    /// leaves no syndrome and costs the least reliability, which reaches two wrong bits when the demodulator knows
    /// where they are. (A wrong length then fails the Reed-Solomon code, or changes only the padding.)
    static func length(header: UInt32, reliability: [Float]? = nil) -> (bits: Int, corrected: Bool)? {
        var word = header & 0x3F_FFFF                                   // the reserved bits are zero by definition
        let s = syndrome(word)
        if s != 0 {
            // A pattern of wrong bits must have the same syndrome; bit b of the word is header bit 24 - b.
            let column = (0..<22).map { syndrome(1 << UInt32($0)) }
            if let reliability, reliability.count == headerLength {
                func cost(_ b: Int) -> Float { reliability[headerLength - 1 - b] }
                var best: (Float, UInt32)?
                for a in 0..<22 {
                    if column[a] == s, best == nil || cost(a) < best!.0 { best = (cost(a), 1 << UInt32(a)) }
                    for b in (a + 1)..<22 where column[a] ^ column[b] == s {
                        let c = cost(a) + cost(b)
                        if best == nil || c < best!.0 { best = (c, 1 << UInt32(a) | 1 << UInt32(b)) }
                    }
                }
                guard let (_, pattern) = best else { return nil }
                word ^= pattern
            } else {
                guard let bit = column.firstIndex(of: s) else { return nil }
                word ^= 1 << UInt32(bit)
            }
        }
        let corrected = s != 0
        let field = (word >> 5) & 0x1_FFFF
        var bits = 0
        for i in 0..<17 where field >> UInt32(16 - i) & 1 == 1 { bits |= 1 << i }   // sent least significant first
        guard bits > 0, bits <= (corrected ? longestCorrected : longest) else { return nil }
        return (bits, corrected)
    }

    static func header(length: Int) -> UInt32 {
        var field: UInt32 = 0
        for i in 0..<17 where length >> i & 1 == 1 { field |= 1 << UInt32(16 - i) }
        var word = field << 5
        for (i, row) in checkRows.enumerated() where (word & row).nonzeroBitCount & 1 == 1 { word |= 1 << UInt32(4 - i) }
        return word
    }

    // MARK: Scrambler

    /// x^15 + x + 1, from 0x6959 at the first header bit.
    struct Scrambler {
        var state: UInt16 = 0x6959
        mutating func next() -> UInt8 {
            let out = UInt8((state ^ state >> 14) & 1)
            state = state >> 1 | UInt16(out) << 14
            return out
        }
    }

    // MARK: Blocks

    /// How a burst of `bits` data bits is laid out.
    struct Layout: Equatable {
        let bits: Int
        var dataOctets: Int { (bits + 7) / 8 }
        var blocks: Int { (dataOctets + 248) / 249 }
        var lastBlock: Int { dataOctets - 249 * (blocks - 1) }
        /// Check octets of the last block: a short block sends fewer (the rest of the six are not sent).
        var lastChecks: Int { lastBlock < 3 ? 0 : lastBlock < 31 ? 2 : lastBlock < 68 ? 4 : 6 }
        var checkOctets: Int { 6 * (blocks - 1) + lastChecks }
        /// Everything after the header, bits.
        var totalBits: Int { 8 * (dataOctets + checkOctets) }
    }

    /// The data octets back in order, repaired: `octets` as received (data, then check octets), nil if a block is
    /// beyond repair. `corrected` counts the octets changed.
    ///
    /// With `reliability` (one figure per octet, larger is surer), a block the code cannot repair as it stands is tried
    /// again with its least reliable octets erased, one more each time up to four erasures in all (counting the check
    /// octets a short block does not send), taking a repair only if erasures e and errors t leave two syndromes over
    /// (e + 2t ≤ 4, where the code reaches e + 2t ≤ 6): those two keep a wrong repair unlikely. `bold` uses the code to
    /// its limit instead, for a second try whose frames must then all pass their FCS.
    static func deinterleave(_ octets: [UInt8], reliability: [Float]? = nil, bold: Bool = false,
                             layout: Layout) -> (data: [UInt8], corrected: Int)? {
        let rows = layout.blocks
        var words = [[UInt8]](repeating: [UInt8](repeating: 0, count: 255), count: rows)
        var sure = [[Float]](repeating: [Float](repeating: .infinity, count: 255), count: rows)
        var index = 0
        for column in 0..<249 {
            for row in 0..<rows where row < rows - 1 || column < layout.lastBlock {
                words[row][column] = octets[index]
                sure[row][column] = reliability?[index] ?? .infinity
                index += 1
            }
        }
        for column in 0..<6 {
            for row in 0..<rows where row < rows - 1 || column < layout.lastChecks {
                words[row][249 + column] = octets[index]
                sure[row][249 + column] = reliability?[index] ?? .infinity
                index += 1
            }
        }
        var data: [UInt8] = []
        var corrected = 0
        for row in 0..<rows {
            let checks = row < rows - 1 ? 6 : layout.lastChecks
            let length = row < rows - 1 ? 249 : layout.lastBlock
            if checks > 0 {
                let unsent = Array((249 + checks)..<255)
                let sent = Array(0..<length) + Array(249..<(249 + checks))
                let received = words[row]
                // Erasures and errors together leave two syndromes unused (e + 2t ≤ 4): with fewer to spare almost any
                // word would come out as some codeword (two syndromes always fit one error somewhere in 255). Bold: up
                // to five erasures and no syndromes over, the erasures tried first (a block beyond three errors comes
                // out of the plain decoder as the wrong codeword about one time in six, and the FCS will judge).
                let most = bold ? 5 : 4, budget = bold ? 6 : 4
                var attempts: [[Int]] = []
                if let reliability, reliability.count == octets.count, unsent.count < most {
                    let doubtful = sent.sorted { sure[row][$0] < sure[row][$1] }
                    attempts = (1...(most - unsent.count)).map { unsent + doubtful.prefix($0) }
                }
                attempts = bold ? attempts + [unsent] : [unsent] + attempts
                var repaired = false
                for erasures in attempts where !repaired {
                    words[row] = received
                    let limit = erasures == unsent ? nil : (budget - erasures.count) / 2
                    repaired = code.correct(&words[row], erasures: erasures, maximumErrors: limit) != nil
                    // A short block is padded with zeros that were never sent: a repair that changes them is a wrong one
                    // (the full-length code does not know that), and the next attempt gets its turn.
                    if repaired && length < 249 && words[row][length..<249].contains(where: { $0 != 0 }) { repaired = false }
                }
                guard repaired else { return nil }
                corrected += sent.filter { words[row][$0] != received[$0] }.count
            }
            data += words[row][0..<length]
        }
        return (data, corrected)
    }

    // MARK: HDLC

    /// The frames between flags in `bits` (data octets' bits, least significant first), stuffing removed; nil if the
    /// stream breaks the rules (seven ones, or a frame not a whole number of octets).
    static func frames(bits: [UInt8]) -> [[UInt8]]? {
        var frames: [[UInt8]] = []
        var current: [UInt8] = []
        var ones = 0
        var started = false
        for bit in bits {
            if bit == 1 {
                ones += 1
                if ones > 6 { return frames.isEmpty ? nil : frames }
                current.append(1)
                continue
            }
            if ones == 6 {                                              // a flag: 0111 1110
                current.removeLast(min(7, current.count))
                if started && !current.isEmpty {
                    guard current.count % 8 == 0 else { return frames.isEmpty ? nil : frames }
                    frames.append(stride(from: 0, to: current.count, by: 8).map { i in
                        (0..<8).reduce(UInt8(0)) { $0 | current[i + $1] << UInt8($1) }
                    })
                }
                started = true
                current = []
            } else if ones != 5 {                                       // after five ones, a stuffed zero
                current.append(0)
            }
            ones = 0
        }
        return frames
    }

    // MARK: Building bursts (for tests)

    /// The octets as sent for `data` (`layout.dataOctets` of them): blocks of 249 with their check octets (the last
    /// block's cut short), data and then check octets taken by column across the blocks.
    static func interleave(_ data: [UInt8], layout: Layout) -> [UInt8] {
        var words: [[UInt8]] = []
        var checks: [[UInt8]] = []
        for row in 0..<layout.blocks {
            let part = Array(data[(249 * row)..<min(data.count, 249 * row + 249)])
            words.append(part)
            let count = row < layout.blocks - 1 ? 6 : layout.lastChecks
            checks.append(Array(code.parity(for: part + [UInt8](repeating: 0, count: 249 - part.count)).prefix(count)))
        }
        var octets: [UInt8] = []
        for column in 0..<249 { for word in words where column < word.count { octets.append(word[column]) } }
        for column in 0..<6 { for check in checks where column < check.count { octets.append(check[column]) } }
        return octets
    }

    /// The bits after the synchronisation sequence for `frames` (each with its FCS), scrambled, padded to whole symbols.
    static func bits(frames: [[UInt8]]) -> [UInt8] {
        let flag: [UInt8] = [0, 1, 1, 1, 1, 1, 1, 0]
        var stream = flag
        for frame in frames {
            var ones = 0
            for byte in frame {
                for j in 0..<8 {
                    let bit = byte >> UInt8(j) & 1
                    stream.append(bit)
                    ones = bit == 1 ? ones + 1 : 0
                    if ones == 5 { stream.append(0); ones = 0 }
                }
            }
            stream += flag
        }
        let layout = Layout(bits: stream.count)
        var data = [UInt8](repeating: 0, count: layout.dataOctets)
        for (i, bit) in stream.enumerated() { data[i / 8] |= bit << UInt8(i % 8) }
        let word = header(length: stream.count)
        var bits = (0..<headerLength).map { UInt8(word >> UInt32(24 - $0) & 1) }
        for octet in interleave(data, layout: layout) { bits += (0..<8).map { octet >> UInt8($0) & 1 } }
        var scrambler = Scrambler()
        for i in bits.indices { bits[i] ^= scrambler.next() }
        return bits + [UInt8](repeating: 0, count: (3 - bits.count % 3) % 3)
    }
}

/// Collects a burst's symbols after the synchronisation sequence and returns its frames when it is complete.
final class VDL2BurstDecoder {
    enum Result { case more, failed, frames([[UInt8]], corrected: Int, headerCorrected: Bool, octets: Int) }

    private var scrambler = VDL2Burst.Scrambler()
    private var bits: [UInt8] = []
    private var sure: [Float] = []
    private var layout: VDL2Burst.Layout?
    private var headerCorrected = false

    /// Feeds one symbol (its phase step, 0-7, in π/4) and how sure the demodulator is of it (larger is surer).
    func push(step: Int, reliability: Float = .infinity) -> Result {
        let value = VDL2Burst.gray[step & 7]
        for shift in [2, 1, 0] { bits.append(value >> UInt8(shift) & 1 ^ scrambler.next()) }
        sure += [reliability, reliability, reliability]
        if layout == nil {
            guard bits.count >= VDL2Burst.headerLength else { return .more }
            let word = bits[0..<VDL2Burst.headerLength].reduce(UInt32(0)) { $0 << 1 | UInt32($1) }
            let known = sure[0..<VDL2Burst.headerLength].allSatisfy { $0.isFinite }
            let header = VDL2Burst.length(header: word, reliability: known ? Array(sure[0..<VDL2Burst.headerLength]) : nil)
            guard let length = header else { return .failed }
            layout = VDL2Burst.Layout(bits: length.bits)
            headerCorrected = length.corrected
        }
        guard let layout, bits.count >= VDL2Burst.headerLength + layout.totalBits else { return .more }
        var octets = [UInt8](repeating: 0, count: layout.dataOctets + layout.checkOctets)
        var reliability = [Float](repeating: .infinity, count: octets.count)
        for i in 0..<layout.totalBits {
            octets[i / 8] |= bits[VDL2Burst.headerLength + i] << UInt8(i % 8)
            reliability[i / 8] = min(reliability[i / 8], sure[VDL2Burst.headerLength + i])
        }
        // First with a margin kept on every repair; if a frame then fails, once more using the code to its limit,
        // taken only if every frame's FCS then holds.
        let careful = Self.frames(octets, reliability, bold: false, layout)
        if let careful, careful.frames.allSatisfy({ AVLCFrame.fcsResidue($0) == 0xF0B8 }) {
            return .frames(careful.frames, corrected: careful.corrected, headerCorrected: headerCorrected, octets: layout.dataOctets)
        }
        if let bold = Self.frames(octets, reliability, bold: true, layout),
           bold.frames.allSatisfy({ AVLCFrame.fcsResidue($0) == 0xF0B8 }) {
            return .frames(bold.frames, corrected: bold.corrected, headerCorrected: headerCorrected, octets: layout.dataOctets)
        }
        guard let careful else { return .failed }
        return .frames(careful.frames, corrected: careful.corrected, headerCorrected: headerCorrected, octets: layout.dataOctets)
    }

    private static func frames(_ octets: [UInt8], _ reliability: [Float], bold: Bool,
                               _ layout: VDL2Burst.Layout) -> (frames: [[UInt8]], corrected: Int)? {
        guard let (data, corrected) = VDL2Burst.deinterleave(octets, reliability: reliability, bold: bold, layout: layout) else { return nil }
        // Every bit of the data octets, not only the `layout.bits` the header gave: frames end at flags, so a length
        // wrong in its last bits (one the header code could not see) costs nothing.
        var stream: [UInt8] = []
        stream.reserveCapacity(8 * data.count)
        for octet in data { for j in 0..<8 { stream.append(octet >> UInt8(j) & 1) } }
        guard let frames = VDL2Burst.frames(bits: stream), !frames.isEmpty else { return nil }
        return (frames, corrected)
    }
}
