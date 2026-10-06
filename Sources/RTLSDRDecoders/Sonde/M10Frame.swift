// SPDX-License-Identifier: GPL-2.0-or-later
//
// Meteomodem M10 and M20 radiosonde frames. The layout, the checksum and the sensor formulas follow rs1729's RS project
// (m10m20mod, GPL-3.0; read for these facts only, no code taken). Written for this package. See PROVENANCE.md.
import Foundation

/// The M10 and M20: 2-FSK at about 9600 symbols a second, Manchester coded and then differentially coded, in frames of
/// up to 165 bytes once a second. A frame starts with its length byte (the bytes after it, so 0x64 for 101 in all) and a
/// type byte, and ends with a 16-bit checksum of everything before it.
public enum M10 {
    /// The sondes transmit between 400 and 406 MHz, like the RS41.
    public static let frequencyRange = 400_000_000...406_000_000
    /// Symbols a second: 9600 on the M20 and some M10s, 9616 on other M10s.
    public static let symbolRate = 9600.0
    /// The standard lengths (the length byte): the M10's 0x64 and the M20's 0x45, with up to 64 more bytes of extra data.
    public static let m10Length = 0x64, m20Length = 0x45, maxExtra = 0x40
    public static let maxFrameBytes = m10Length + maxExtra + 1

    /// The 32 symbols that come before a frame (+1 for the higher frequency): a clock of 1001 pairs, then a pattern
    /// no data can make.
    static let headerSymbols: [Double] = "10011001100110010100110010011001".map { $0 == "1" ? 1 : -1 }

    /// One byte into the checksum. A linear map over GF(2): the byte is rotated right by one and has itself shifted
    /// right by two folded in; the 16-bit state's low six bits are kept, the next two are replaced by the parity of
    /// the even and of the odd bits among its low six; and the state's high byte is shifted right by seven, with
    /// itself shifted right by two folded in. The high byte of the result is the old low byte.
    static func update(_ c: Int, with byte: UInt8) -> Int {
        var b = Int(byte)
        b = (b >> 1) | ((b & 1) << 7)
        b ^= (b >> 2) & 0xff
        let t6 = (c & 1) ^ ((c >> 2) & 1) ^ ((c >> 4) & 1)
        let t7 = ((c >> 1) & 1) ^ ((c >> 3) & 1) ^ ((c >> 5) & 1)
        let t = (c & 0x3f) | (t6 << 6) | (t7 << 7)
        var s = (c >> 7) & 0xff
        s ^= (s >> 2) & 0xff
        let low = b ^ t ^ s
        return (((c & 0xff) << 8) | low) & 0xffff
    }

    /// The checksum of `bytes`.
    static func checksum(_ bytes: ArraySlice<UInt8>) -> Int {
        var c = 0
        for byte in bytes { c = update(c, with: byte) }
        return c
    }
}

/// An M10 or M20 frame: the length byte and the bytes it counts.
public struct M10Frame: Sendable {
    public enum Kind: UInt8, Sendable {
        /// M10 with a Trimble GPS receiver (the common one).
        case m10 = 0x9f
        /// The M2K2, which has the M10's layout.
        case m2k2 = 0x8f
        /// M10 with a Gtop GPS receiver ("M10+").
        case m10Plus = 0xaf
        case m20 = 0x20
        /// The second kind of frame, sent every ten seconds with signal levels instead of a position.
        case doubleFrame = 0x49
    }

    public var bytes: [UInt8]

    /// A frame from its bytes, if there are as many as the length byte says.
    public init?(bytes: [UInt8]) {
        guard let length = bytes.first, length >= 4, bytes.count >= Int(length) + 1 else { return nil }
        self.bytes = Array(bytes.prefix(Int(length) + 1))
    }

    public var length: Int { Int(bytes[0]) }
    public var kind: Kind? { Kind(rawValue: bytes[1]) }

    /// What the last two bytes say the checksum is.
    var storedChecksum: Int { Int(bytes[length - 1]) << 8 | Int(bytes[length]) }
    /// The checksum of everything before them.
    var computedChecksum: Int { M10.checksum(bytes[0..<(length - 1)]) }
    public var isValid: Bool { storedChecksum == computedChecksum }

    func byte(_ offset: Int) -> Int { offset < bytes.count ? Int(bytes[offset]) : 0 }
    /// Big-endian unsigned integer of `count` bytes at `offset`.
    func unsigned(_ offset: Int, _ count: Int) -> Int {
        var value = 0
        for k in 0..<count { value = value << 8 | byte(offset + k) }
        return value
    }
    /// Big-endian two's-complement integer of `count` bytes at `offset`.
    func signed(_ offset: Int, _ count: Int) -> Int {
        let value = unsigned(offset, count)
        return value >= 1 << (8 * count - 1) ? value - (1 << (8 * count)) : value
    }
}
