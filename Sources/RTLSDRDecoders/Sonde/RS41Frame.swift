// SPDX-License-Identifier: GPL-2.0-or-later
//
// The Vaisala RS41 radiosonde's frame: 4800 bit/s GFSK, one frame a second, bytes sent least significant bit first,
// whitened with a 64-byte sequence, two interleaved Reed-Solomon (255,231) codewords, then blocks of the form
// ID, length, data, CRC-16. Written for this package from the format as rs1729's RS project documents it (rs41.txt and
// the decoder rs41mod.c, GPL-3.0, read for these facts only; no code taken) and checked against rs41mod's output.
// See PROVENANCE.md.

public enum RS41 {
    public static let frequencyRange = 400_000_000...406_000_000
    public static let baudRate = 4800
    /// A frame without extra data, and the longest (extended frames carry an XDATA block for ozone sondes etc.).
    public static let standardFrameBytes = 320
    public static let extendedFrameBytes = 518
    static let headerBytes = 8
    static let parityStart = 8                    // 2 × 24 parity bytes
    static let messageStart = 56                  // the frame-type byte, then the blocks
    static let firstBlock = 57

    /// The eight header bytes as they go on air (the whitened form of 86 35 F4 40 93 DF 1A 60).
    static let header: [UInt8] = [0x10, 0xb6, 0xca, 0x11, 0x22, 0x96, 0x12, 0xf8]

    /// The whitening sequence XORed over every frame from its first byte on, repeating every 64 bytes. It comes from a
    /// shift register: from byte 24 to 63, each byte is the XOR of the bytes 16, 14, 12 and 10 places before it (the
    /// tests check that).
    static let whitening: [UInt8] = [
        0x96, 0x83, 0x3e, 0x51, 0xb1, 0x49, 0x08, 0x98, 0x32, 0x05, 0x59, 0x0e, 0xf9, 0x44, 0xc6, 0x26,
        0x21, 0x60, 0xc2, 0xea, 0x79, 0x5d, 0x6d, 0xa1, 0x54, 0x69, 0x47, 0x0c, 0xdc, 0xe8, 0x5c, 0xf1,
        0xf7, 0x76, 0x82, 0x7f, 0x07, 0x99, 0xa2, 0x2c, 0x93, 0x7c, 0x30, 0x63, 0xf5, 0x10, 0x2e, 0x61,
        0xd0, 0xbc, 0xb4, 0xb6, 0x06, 0xaa, 0xf4, 0x23, 0x78, 0x6e, 0x3b, 0xae, 0xbf, 0x7b, 0x4c, 0xc1,
    ]

    /// Header bits in transmission order (least significant bit of each byte first), as ±1 with 1 for a one.
    static let headerBits: [Float] = header.flatMap { byte in (0..<8).map { byte >> UInt8($0) & 1 == 1 ? 1 : -1 } }

    /// Each of the two codewords, shortened to the 132 message bytes of a standard frame and put in this package's
    /// order (highest power first): the message bytes backwards, then the parity backwards. GF(2⁸) with polynomial
    /// 0x11D, roots α⁰ … α²³.
    static let reedSolomon = ReedSolomon(length: 132 + 24, parityCount: 24, polynomial: 0x11d, firstRoot: 0)

    /// XORs the whitening sequence over `frame` (it undoes itself).
    static func dewhiten(_ frame: inout [UInt8]) {
        for index in frame.indices { frame[index] ^= whitening[index % whitening.count] }
    }

    /// CRC-16/CCITT-FALSE (polynomial 0x1021, initial value 0xFFFF), as each block carries it (little-endian).
    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? crc << 1 ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    /// Corrects a dewhitened standard frame's two codewords in place. Returns the bytes corrected, or nil if either
    /// codeword is beyond repair (the frame is then left as received). Extended frames' extra bytes are not covered.
    static func correct(_ frame: inout [UInt8]) -> Int? {
        var total = 0
        var fixed: [[UInt8]] = []
        for codeword in 0..<2 {
            let message = (0..<132).map { frame[messageStart + 2 * $0 + codeword] }
            let parity = (0..<24).map { frame[parityStart + 24 * codeword + $0] }
            var word = Array(message.reversed()) + parity.reversed()
            guard let count = reedSolomon.correct(&word) else { return nil }
            total += count
            fixed.append(word)
        }
        for (codeword, word) in fixed.enumerated() {
            for index in 0..<132 { frame[messageStart + 2 * index + codeword] = word[131 - index] }
            for index in 0..<24 { frame[parityStart + 24 * codeword + index] = word[155 - index] }
        }
        return total
    }

    /// Fills in the parity of a dewhitened standard frame (for making test signals).
    static func addParity(_ frame: inout [UInt8]) {
        for codeword in 0..<2 {
            let message = (0..<132).map { frame[messageStart + 2 * $0 + codeword] }
            let parity = reedSolomon.parity(for: Array(message.reversed()))
            for index in 0..<24 { frame[parityStart + 24 * codeword + index] = parity[23 - index] }
        }
    }

    /// The block headers (ID, length) of a standard frame and where they sit: known in advance, so a frame the code
    /// cannot repair gets a second try with them written in (they are data, so this can only remove errors).
    static let standardBlocks: [(position: Int, id: UInt8, length: UInt8)] = [
        (0x039, 0x79, 0x28), (0x065, 0x7a, 0x2a), (0x093, 0x7c, 0x1e), (0x0b5, 0x7d, 0x59), (0x112, 0x7b, 0x15), (0x12b, 0x76, 0x11),
    ]
    /// The last block of a standard frame is padding: 17 zero bytes and their CRC. Known too.
    static let padding: (position: Int, bytes: [UInt8]) = (0x12d, [UInt8](repeating: 0, count: 17) + [0xec, 0xc7])
}

/// One RS41 frame, dewhitened and (if possible) corrected, with its blocks.
public struct RS41Frame: Sendable {
    public var bytes: [UInt8]
    /// Bytes the Reed-Solomon code corrected, or nil if it could not.
    public var corrected: Int?
    /// Blocks found, with their CRC check: ID → (offset of the data, length, CRC good).
    public var blocks: [UInt8: (offset: Int, length: Int, valid: Bool)] = [:]

    public var isExtended: Bool { bytes.count > RS41.messageStart && bytes[RS41.messageStart] == 0xf0 }

    /// Dewhitens, corrects and splits `raw` (a whole frame as received, header included).
    public init(raw: [UInt8]) {
        var frame = raw
        RS41.dewhiten(&frame)
        var corrected = frame.count >= RS41.standardFrameBytes ? RS41.correct(&frame) : nil
        if corrected == nil && frame.count >= RS41.standardFrameBytes {
            var retry = frame
            // The frame's length says its type; extended frames end in an XDATA block instead of the padding.
            let standard = frame.count == RS41.standardFrameBytes
            retry[RS41.messageStart] = standard ? 0x0f : 0xf0
            for block in RS41.standardBlocks.dropLast() {
                retry[block.position] = block.id
                retry[block.position + 1] = block.length
            }
            if standard {
                let last = RS41.standardBlocks[RS41.standardBlocks.count - 1]
                retry[last.position] = last.id
                retry[last.position + 1] = last.length
                for (index, byte) in RS41.padding.bytes.enumerated() { retry[RS41.padding.position + index] = byte }
            }
            if let count = RS41.correct(&retry) { frame = retry; corrected = count }
        }
        bytes = frame
        self.corrected = corrected
        blocks = Self.split(frame)
    }

    /// Walks the blocks from the first; stops at the end of the frame or at a block that cannot be one.
    private static func split(_ frame: [UInt8]) -> [UInt8: (offset: Int, length: Int, valid: Bool)] {
        var found: [UInt8: (offset: Int, length: Int, valid: Bool)] = [:]
        var position = RS41.firstBlock
        while position + 4 <= frame.count {
            let id = frame[position], length = Int(frame[position + 1])
            let end = position + 2 + length
            guard end + 2 <= frame.count else { break }
            let crc = UInt16(frame[end]) | UInt16(frame[end + 1]) << 8
            let valid = RS41.crc16(frame[(position + 2)..<end]) == crc
            if found[id] == nil || valid { found[id] = (position + 2, length, valid) }
            position = end + 2
        }
        return found
    }

    /// A block's data, if its CRC is good.
    func block(_ id: UInt8) -> ArraySlice<UInt8>? {
        guard let block = blocks[id], block.valid else { return nil }
        return bytes[block.offset..<(block.offset + block.length)]
    }

    private func u16(_ data: ArraySlice<UInt8>, _ at: Int) -> Int { Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8 }
    private func i16(_ data: ArraySlice<UInt8>, _ at: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(data, at)))) }
    private func u24(_ data: ArraySlice<UInt8>, _ at: Int) -> Int { u16(data, at) | Int(data[data.startIndex + at + 2]) << 16 }
    private func i32(_ data: ArraySlice<UInt8>, _ at: Int) -> Int {
        Int(Int32(bitPattern: UInt32(u16(data, at)) | UInt32(u16(data, at + 2)) << 16))
    }

    // Status block (0x79): frame number, serial, battery, one 16-byte piece of the calibration table.
    public var frameNumber: Int? { block(0x79).map { u16($0, 0) } }
    public var serial: String? {
        block(0x79).map { data in String(decoding: data[(data.startIndex + 2)..<(data.startIndex + 10)].filter { $0 >= 0x20 && $0 < 0x7f }, as: UTF8.self) }
    }
    public var batteryVolts: Double? { block(0x79).map { Double($0[$0.startIndex + 10]) / 10 } }
    /// The calibration subframe: its index (0 … 50) and its 16 bytes.
    public var calibration: (index: Int, bytes: [UInt8])? {
        block(0x79).map { data in (Int(data[data.startIndex + 23]), Array(data[(data.startIndex + 24)..<(data.startIndex + 40)])) }
    }

    /// PTU block (0x7A): twelve 24-bit measurement counts (temperature sensor and its two references, humidity,
    /// humidity-sensor temperature, pressure, each with references).
    public var measurements: [Int]? { block(0x7a).map { data in (0..<12).map { u24(data, 3 * $0) } } }

    /// GPS time (0x7C): full GPS week and milliseconds into it.
    public var gpsTime: (week: Int, milliseconds: Int)? {
        block(0x7c).map { data in (u16(data, 0), Int(UInt32(u16(data, 2)) | UInt32(u16(data, 4)) << 16)) }
    }

    /// GPS position (0x7B): ECEF metres and metres per second, satellites used.
    public var ecef: (position: (Double, Double, Double), velocity: (Double, Double, Double), satellites: Int)? {
        block(0x7b).map { data in
            ((Double(i32(data, 0)) / 100, Double(i32(data, 4)) / 100, Double(i32(data, 8)) / 100),
             (Double(i16(data, 12)) / 100, Double(i16(data, 14)) / 100, Double(i16(data, 16)) / 100),
             Int(data[data.startIndex + 18]))
        }
    }
}
