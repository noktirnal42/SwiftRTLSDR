// SPDX-License-Identifier: GPL-2.0-or-later
//
// DFM-06/09/17 radiosonde frames (Graw, 400-406 MHz). The frame layout, interleaver and code follow rs1729's RS
// project (dfm09mod, GPL-3.0; read for these facts only, no code taken). Written for this package. See PROVENANCE.md.
import Foundation

/// The DFM radiosondes' signal: 2-FSK, Manchester coded, 2500 symbols a second (1250 bit/s), in frames of 280 bits.
///
/// A frame is a 16-bit header (0x45CF) and three blocks of Hamming(8,4) codewords, each block interleaved on its own:
/// a configuration block of 7 codewords and two data blocks of 13. A codeword is four data bits, most significant
/// first, then four parity bits. There is no CRC over the frame: the code (distance 4) mends one bad bit in a codeword
/// and notices two, and everything else is judged by what the data says.
public enum DFM {
    /// Manchester symbols a second; each bit takes two.
    public static let symbolRate = 2500.0
    public static let bitRate = 1250.0
    public static let frameBits = 280
    public static let headerBits = 16
    public static let headerWord = 0x45CF
    public static let configCodewords = 7
    public static let dataCodewords = 13
    /// The sondes transmit between 400 and 406 MHz, like the RS41.
    public static let frequencyRange = 400_000_000...406_000_000

    /// The header as 32 symbols, +1 for the higher frequency: a 1 is sent as low then high, a 0 as high then low.
    static let headerSymbols: [Double] = {
        var symbols: [Double] = []
        for k in 0..<headerBits {
            let bit = (headerWord >> (headerBits - 1 - k)) & 1
            symbols.append(bit == 1 ? -1 : 1)
            symbols.append(bit == 1 ? 1 : -1)
        }
        return symbols
    }()

    /// The Hamming(8,4) codewords, indexed by data nibble; the first bit sent is the most significant.
    static let codewords: [UInt8] = (0..<16).map { encode(nibble: $0) }

    /// The codeword for a data nibble: its four bits, then p0 = d1+d2+d3, p1 = d0+d2+d3, p2 = d0+d1+d3, p3 = d0+d1+d2.
    static func encode(nibble: Int) -> UInt8 {
        let d0 = (nibble >> 3) & 1, d1 = (nibble >> 2) & 1, d2 = (nibble >> 1) & 1, d3 = nibble & 1
        let p0 = d1 ^ d2 ^ d3, p1 = d0 ^ d2 ^ d3, p2 = d0 ^ d1 ^ d3, p3 = d0 ^ d1 ^ d2
        return UInt8(nibble << 4 | p0 << 3 | p1 << 2 | p2 << 1 | p3)
    }

    /// The syndrome of a received word; a single bad bit at position `j` (0 is the first sent) gives
    /// `errorSyndromes[j]`.
    static func syndrome(_ word: UInt8) -> Int {
        func bit(_ i: Int) -> Int { Int(word >> UInt8(7 - i)) & 1 }
        let s0 = bit(1) ^ bit(2) ^ bit(3) ^ bit(4)
        let s1 = bit(0) ^ bit(2) ^ bit(3) ^ bit(5)
        let s2 = bit(0) ^ bit(1) ^ bit(3) ^ bit(6)
        let s3 = bit(0) ^ bit(1) ^ bit(2) ^ bit(7)
        return s0 << 3 | s1 << 2 | s2 << 1 | s3
    }

    static let errorSyndromes: [Int] = (0..<8).map { syndrome(UInt8(1) << UInt8(7 - $0)) }
}

/// One DFM frame, read from 280 soft bits (positive for a 1, header included).
public struct DFMFrame: Sendable {
    /// A block of codewords after error correction.
    public struct Block: Sendable {
        /// The data nibbles, one per codeword.
        public var nibbles: [UInt8]
        /// Codewords with one bad bit, repaired.
        public var corrected = 0
        /// Codewords with two bad bits whose four equally near neighbours were told apart by the soft decisions.
        public var rescued = 0
        /// Codewords with an error the code cannot mend; their data nibbles are as received.
        public var failed = 0
        /// Nothing was beyond repair.
        public var isIntact: Bool { failed == 0 }
        /// Nothing needed repair either.
        public var isClean: Bool { failed == 0 && corrected == 0 && rescued == 0 }
        /// The data nibbles as one bit string, most significant first.
        var bits: DFMBits { DFMBits(nibbles: nibbles) }
    }

    /// Whether the header, as received, was the DFM header (a sanity check on the timing; the receiver already
    /// correlated it).
    public var headerErrors: Int
    public var config: Block
    public var data: [Block]

    /// Reads a frame from 280 soft bits. With `repairTwoBitErrors`, a codeword with two bad bits is replaced by the
    /// nearest of its four equally distant neighbours, which is right about half the time: a weak signal gets more
    /// frames, and the frames cannot be trusted as far.
    public init(soft: [Float], repairTwoBitErrors: Bool = false) {
        precondition(soft.count == DFM.frameBits)
        var errors = 0
        for k in 0..<DFM.headerBits {
            let expected = (DFM.headerWord >> (DFM.headerBits - 1 - k)) & 1
            if (soft[k] > 0 ? 1 : 0) != expected { errors += 1 }
        }
        headerErrors = errors
        let configStart = DFM.headerBits
        let firstData = configStart + 8 * DFM.configCodewords
        let secondData = firstData + 8 * DFM.dataCodewords
        config = Self.block(soft[configStart..<firstData], codewords: DFM.configCodewords, repair: repairTwoBitErrors)
        data = [
            Self.block(soft[firstData..<secondData], codewords: DFM.dataCodewords, repair: repairTwoBitErrors),
            Self.block(soft[secondData..<DFM.frameBits], codewords: DFM.dataCodewords, repair: repairTwoBitErrors),
        ]
    }

    /// Blocks that came through with nothing beyond repair.
    public var intactBlocks: Int { ([config] + data).filter(\.isIntact).count }

    /// Deinterleaves a block (bit `j` of codeword `i` is the `L * j + i`th sent) and corrects each codeword.
    static func block(_ soft: ArraySlice<Float>, codewords count: Int, repair: Bool) -> Block {
        let base = soft.startIndex
        var block = Block(nibbles: [])
        block.nibbles.reserveCapacity(count)
        for i in 0..<count {
            var word: UInt8 = 0
            var values = [Float](repeating: 0, count: 8)
            for j in 0..<8 {
                let value = soft[base + count * j + i]
                values[j] = value
                if value > 0 { word |= UInt8(1) << UInt8(7 - j) }
            }
            let syndrome = DFM.syndrome(word)
            if syndrome == 0 {
                block.nibbles.append(word >> 4)
            } else if let bit = DFM.errorSyndromes.firstIndex(of: syndrome) {
                word ^= UInt8(1) << UInt8(7 - bit)
                block.corrected += 1
                block.nibbles.append(word >> 4)
            } else if repair, let nearest = nearestAtDistanceTwo(word, soft: values) {
                block.rescued += 1
                block.nibbles.append(nearest >> 4)
            } else {
                block.failed += 1
                block.nibbles.append(word >> 4)
            }
        }
        return block
    }

    /// Of the codewords two bit flips from `word`, the one that agrees best with the soft decisions.
    private static func nearestAtDistanceTwo(_ word: UInt8, soft: [Float]) -> UInt8? {
        var best: (word: UInt8, score: Float)?
        for candidate in DFM.codewords where (candidate ^ word).nonzeroBitCount == 2 {
            var score: Float = 0
            for j in 0..<8 {
                let sign: Float = (candidate >> UInt8(7 - j)) & 1 == 1 ? 1 : -1
                score += sign * soft[j]
            }
            if best == nil || score > best!.score { best = (candidate, score) }
        }
        return best?.word
    }
}

/// A big-endian bit string (up to 64 bits) with field extraction.
struct DFMBits {
    let value: UInt64
    let count: Int

    init(nibbles: [UInt8]) {
        var v: UInt64 = 0
        for nibble in nibbles { v = v << 4 | UInt64(nibble & 0xf) }
        value = v
        count = 4 * nibbles.count
    }

    /// `length` bits from bit `offset` (0 is the first), as an unsigned number.
    func field(_ offset: Int, _ length: Int) -> Int {
        let shift = count - offset - length
        let mask: UInt64 = length >= 64 ? ~0 : (UInt64(1) << UInt64(length)) - 1
        return Int((value >> UInt64(shift)) & mask)
    }

    /// The same field as a two's-complement number.
    func signed(_ offset: Int, _ length: Int) -> Int {
        let raw = field(offset, length)
        return raw >= 1 << (length - 1) ? raw - (1 << length) : raw
    }
}
