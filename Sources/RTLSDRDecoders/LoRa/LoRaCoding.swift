// SPDX-License-Identifier: GPL-2.0-or-later
//
// The LoRa physical layer's coding, from chirp symbols to payload bytes: Gray mapping, the diagonal interleaver,
// Hamming codes, whitening, the explicit header and the payload CRC. Written for this package from the layer as
// published (M. Knight and B. Seeber's "Decoding LoRa" and J. Tapparel et al., "Towards an Open-Source LoRa Physical
// Layer" / "Design and Implementation of LoRa Physical Layer in GNU Radio"), with the bit conventions as EPFL's
// gr-lora_sdr (GPL-3.0) implements them, read for these facts only; gr-lora_sdr is the test oracle. See PROVENANCE.md.

/// LoRa link settings.
public struct LoRaParameters: Sendable, Equatable {
    /// Spreading factor, 7 … 12: each symbol carries this many bits (a chirp of 2^sf chips).
    public var spreadingFactor: Int
    /// Bandwidth in hertz (also the chip rate).
    public var bandwidth: Double
    /// Coding rate 1 … 4, for 4/5 … 4/8.
    public var codingRate: Int
    /// Low data rate optimisation: payload symbols carry two bits fewer (as the header always does).
    public var lowDataRate: Bool
    /// The network's sync word (Meshtastic 0x2B, LoRaWAN 0x34, private LoRa 0x12).
    public var syncWord: UInt8
    public var preambleLength: Int

    public init(spreadingFactor: Int, bandwidth: Double, codingRate: Int, lowDataRate: Bool? = nil, syncWord: UInt8 = 0x12,
                preambleLength: Int = 8) {
        self.spreadingFactor = spreadingFactor
        self.bandwidth = bandwidth
        self.codingRate = codingRate
        // Transceivers turn it on by themselves when a symbol lasts 16 ms or more.
        self.lowDataRate = lowDataRate ?? (Double(1 << spreadingFactor) / bandwidth >= 0.016)
        self.syncWord = syncWord
        self.preambleLength = preambleLength
    }

    public var chips: Int { 1 << spreadingFactor }
    public var symbolSeconds: Double { Double(chips) / bandwidth }
    /// The two sync-word symbols (chirp offsets) sent after the preamble.
    public var syncSymbols: (Int, Int) { (Int(syncWord >> 4) << 3, Int(syncWord & 0x0f) << 3) }
}

/// The explicit header: payload length, coding rate, CRC flag, protected by a 5-bit checksum.
public struct LoRaHeader: Sendable, Equatable {
    public var payloadLength: Int
    public var codingRate: Int
    public var hasCRC: Bool

    public init(payloadLength: Int, codingRate: Int, hasCRC: Bool) {
        self.payloadLength = payloadLength
        self.codingRate = codingRate
        self.hasCRC = hasCRC
    }

    /// The five header nibbles.
    var nibbles: [UInt8] {
        let n0 = UInt8(payloadLength >> 4), n1 = UInt8(payloadLength & 0x0f), n2 = UInt8(codingRate << 1) | (hasCRC ? 1 : 0)
        let c = Self.checksum(n0, n1, n2)
        return [n0, n1, n2, c >> 4, c & 0x0f]
    }

    static func checksum(_ n0: UInt8, _ n1: UInt8, _ n2: UInt8) -> UInt8 {
        func b(_ nibble: UInt8, _ bit: Int) -> UInt8 { nibble >> UInt8(bit) & 1 }
        let c4 = b(n0, 3) ^ b(n0, 2) ^ b(n0, 1) ^ b(n0, 0)
        let c3 = b(n0, 3) ^ b(n1, 3) ^ b(n1, 2) ^ b(n1, 1) ^ b(n2, 0)
        let c2 = b(n0, 2) ^ b(n1, 3) ^ b(n1, 0) ^ b(n2, 3) ^ b(n2, 1)
        let c1 = b(n0, 1) ^ b(n1, 2) ^ b(n1, 0) ^ b(n2, 2) ^ b(n2, 1) ^ b(n2, 0)
        let c0 = b(n0, 0) ^ b(n1, 1) ^ b(n2, 3) ^ b(n2, 2) ^ b(n2, 1) ^ b(n2, 0)
        return c4 << 4 | c3 << 3 | c2 << 2 | c1 << 1 | c0
    }

    /// Reads a header from its five nibbles; nil if the checksum fails or the values cannot be.
    init?(nibbles n: [UInt8]) {
        guard n.count >= 5, Self.checksum(n[0], n[1], n[2]) == ((n[3] & 1) << 4 | n[4]) else { return nil }
        payloadLength = Int(n[0]) << 4 | Int(n[1])
        codingRate = Int(n[2] >> 1)
        hasCRC = n[2] & 1 == 1
        guard (1...4).contains(codingRate), payloadLength > 0 else { return nil }
    }
}

/// Symbols to bytes and back.
public enum LoRaCoding {
    /// The whitening sequence XORed over the payload: a shift register (feedback from bits 7, 5, 4 and 3) from 0xFF.
    static let whitening: [UInt8] = {
        var state: UInt8 = 0xff
        return (0..<255).map { _ in
            defer { state = state << 1 | ((state >> 7 ^ state >> 5 ^ state >> 4 ^ state >> 3) & 1) }
            return state
        }
    }()

    /// CRC-16 (polynomial 0x1021, initial 0) of all but the last two bytes, XORed with those two: the LoRa payload CRC.
    static func crc(_ payload: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in payload.dropLast(2) {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? crc << 1 ^ 0x1021 : crc << 1 }
        }
        var tail: UInt16 = 0                                // the last two bytes, big-endian (fewer if there are not two)
        for byte in payload.suffix(2) { tail = tail << 8 | UInt16(byte) }
        return crc ^ tail
    }

    /// A nibble's codeword, most significant bit first, 4 + `rate` bits: the data bits least significant first, then
    /// parity (one bit for 4/5, the Hamming bits for 4/6 … 4/8).
    static func hamming(_ nibble: UInt8, rate: Int) -> UInt8 {
        let d0 = nibble & 1, d1 = nibble >> 1 & 1, d2 = nibble >> 2 & 1, d3 = nibble >> 3 & 1
        if rate == 1 { return d0 << 4 | d1 << 3 | d2 << 2 | d3 << 1 | (d0 ^ d1 ^ d2 ^ d3) }
        let p0 = d0 ^ d1 ^ d2, p1 = d1 ^ d2 ^ d3, p2 = d0 ^ d1 ^ d3, p3 = d0 ^ d2 ^ d3
        let full = d0 << 7 | d1 << 6 | d2 << 5 | d3 << 4 | p0 << 3 | p1 << 2 | p2 << 1 | p3
        return full >> UInt8(4 - rate)
    }

    /// The nibble of the nearest codeword (4/7 and 4/8 correct one error; a tie, or 4/5 and 4/6, keeps the data bits).
    static func unhamming(_ codeword: UInt8, rate: Int) -> UInt8 {
        let length = 4 + rate
        let received = UInt8(codeword >> UInt8(length - 4) & 0x0f)
        let asSent = (received & 8) >> 3 | (received & 4) >> 1 | (received & 2) << 1 | (received & 1) << 3
        guard rate >= 3 else { return asSent }
        var best = asSent, bestDistance = Int.max, ties = 0
        for nibble in UInt8(0)..<16 {
            let distance = (hamming(nibble, rate: rate) ^ codeword).nonzeroBitCount
            if distance < bestDistance { best = nibble; bestDistance = distance; ties = 1 } else if distance == bestDistance { ties += 1 }
        }
        return ties == 1 ? best : asSent
    }

    static func grayToBinary(_ gray: Int) -> Int {
        var value = gray, shift = gray >> 1
        while shift != 0 { value ^= shift; shift >>= 1 }
        return value
    }

    /// Symbols (chirp offsets) for a frame with an explicit header and a CRC.
    public static func encode(_ payload: [UInt8], _ p: LoRaParameters) -> [Int] {
        precondition(payload.count <= 255, "a LoRa payload is at most 255 bytes")
        let sf = p.spreadingFactor
        var nibbles = LoRaHeader(payloadLength: payload.count, codingRate: p.codingRate, hasCRC: true).nibbles
        for (index, byte) in payload.enumerated() {
            let whitened = byte ^ whitening[index]
            nibbles += [whitened & 0x0f, whitened >> 4]
        }
        let crc = crc(payload)
        nibbles += [UInt8(crc & 0xf), UInt8(crc >> 4 & 0xf), UInt8(crc >> 8 & 0xf), UInt8(crc >> 12)]
        var symbols: [Int] = []
        var index = 0
        var first = true
        while index < nibbles.count {
            let reduced = first || p.lowDataRate
            let bitsPerSymbol = reduced ? sf - 2 : sf
            let rate = first ? 4 : p.codingRate
            let block = (0..<bitsPerSymbol).map { index + $0 < nibbles.count ? hamming(nibbles[index + $0], rate: rate) : 0 }
            index += bitsPerSymbol
            let length = 4 + rate
            for i in 0..<length {
                var value = 0
                for j in 0..<bitsPerSymbol {
                    let codeword = block[((i - j - 1) % bitsPerSymbol + bitsPerSymbol) % bitsPerSymbol]
                    value = value << 1 | Int(codeword >> UInt8(length - 1 - i) & 1)
                }
                if reduced { value = value << 2 | (value.nonzeroBitCount & 1) << 1 }
                symbols.append((grayToBinary(value) + 1) % p.chips)
            }
            first = false
        }
        return symbols
    }

    /// The nibbles of one block of symbols: `reduced` for the header block and low-data-rate blocks.
    static func nibbles(_ symbols: ArraySlice<Int>, rate: Int, reduced: Bool, _ p: LoRaParameters) -> [UInt8] {
        let bitsPerSymbol = reduced ? p.spreadingFactor - 2 : p.spreadingFactor
        let length = 4 + rate
        var codewords = [UInt8](repeating: 0, count: bitsPerSymbol)
        for (i, symbol) in symbols.enumerated() {
            var value = ((symbol - 1) % p.chips + p.chips) % p.chips
            if reduced { value >>= 2 }
            let gray = value ^ value >> 1
            for j in 0..<bitsPerSymbol where gray >> (bitsPerSymbol - 1 - j) & 1 == 1 {
                codewords[((i - j - 1) % bitsPerSymbol + bitsPerSymbol) % bitsPerSymbol] |= 1 << UInt8(length - 1 - i)
            }
        }
        return codewords.map { unhamming($0, rate: rate) }
    }

    /// Symbols a frame occupies after its header block.
    public static func payloadSymbols(_ header: LoRaHeader, _ p: LoRaParameters) -> Int {
        let nibbles = 2 * header.payloadLength + (header.hasCRC ? 4 : 0) - (p.spreadingFactor - 7)
        let perBlock = p.lowDataRate ? p.spreadingFactor - 2 : p.spreadingFactor
        return max(0, (nibbles + perBlock - 1) / perBlock) * (4 + header.codingRate)
    }

    /// The header from the first eight symbols, and the payload nibbles those symbols also carry.
    public static func header(_ symbols: ArraySlice<Int>, _ p: LoRaParameters) -> (LoRaHeader, [UInt8])? {
        guard symbols.count >= 8 else { return nil }
        let nibbles = nibbles(symbols.prefix(8), rate: 4, reduced: true, p)
        guard let header = LoRaHeader(nibbles: nibbles) else { return nil }
        return (header, Array(nibbles.dropFirst(5)))
    }

    /// The payload, and whether its CRC holds (nil without a CRC), from a frame's symbols (header block included).
    public static func decode(_ symbols: [Int], _ p: LoRaParameters) -> (payload: [UInt8], crcValid: Bool?)? {
        guard let (header, first) = header(symbols[...], p) else { return nil }
        let needed = payloadSymbols(header, p)
        guard symbols.count >= 8 + needed else { return nil }
        var nibbles = first
        var index = 8
        while index < 8 + needed {
            nibbles += Self.nibbles(symbols[index..<(index + 4 + header.codingRate)], rate: header.codingRate, reduced: p.lowDataRate, p)
            index += 4 + header.codingRate
        }
        let length = header.payloadLength
        guard nibbles.count >= 2 * length + (header.hasCRC ? 4 : 0) else { return nil }
        let payload: [UInt8] = (0..<length).map { index in
            let byte: UInt8 = nibbles[2 * index] | nibbles[2 * index + 1] << 4
            return byte ^ whitening[index]
        }
        guard header.hasCRC, length >= 2 else { return (payload, nil) }
        let c: [UInt16] = nibbles[(2 * length)..<(2 * length + 4)].map { UInt16($0) }
        let received: UInt16 = c[0] | c[1] << 4 | c[2] << 8 | c[3] << 12
        return (payload, received == crc(payload))
    }
}
