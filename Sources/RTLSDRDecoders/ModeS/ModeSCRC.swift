// SPDX-License-Identifier: GPL-2.0-or-later

/// The Mode S parity check: a 24-bit CRC with generator polynomial 0x1FFF409 (ICAO Annex 10, Vol. IV).
///
/// For an extended squitter (DF17/18) the last 24 bits are the plain CRC of the rest, so a valid message has a
/// syndrome of zero. DF11 replies overlay an interrogator code on the low 7 bits. Most other replies overlay the
/// aircraft address on the whole CRC ("address/parity"), so their syndrome *is* the address.
public enum ModeSCRC {
    static let polynomial: UInt32 = 0xFFF409

    static let table: [UInt32] = (0..<256).map { byte in
        var crc = UInt32(byte) << 16
        for _ in 0..<8 {
            crc = crc & 0x800000 != 0 ? (crc << 1) ^ polynomial : crc << 1
        }
        return crc & 0xFFFFFF
    }

    /// The CRC of `data` (every byte, MSB first).
    public static func checksum<C: Collection>(_ data: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0
        for byte in data {
            crc = ((crc << 8) ^ table[Int(((crc >> 16) ^ UInt32(byte)) & 0xff)]) & 0xFFFFFF
        }
        return crc
    }

    /// CRC of the message body XOR its parity field: 0 for a clean DF17, the address for address/parity replies.
    public static func syndrome(_ message: [UInt8]) -> UInt32 {
        precondition(message.count == 7 || message.count == 14, "Mode S messages are 56 or 112 bits")
        let body = message.dropLast(3)
        let parity = UInt32(message[message.count - 3]) << 16 | UInt32(message[message.count - 2]) << 8 | UInt32(message[message.count - 1])
        return checksum(body) ^ parity
    }

    /// For each length, the syndrome a single flipped bit produces, mapped to that bit's index.
    private static let singleBitSyndromes: [Int: [UInt32: Int]] = {
        var tables: [Int: [UInt32: Int]] = [:]
        for bytes in [7, 14] {
            var table: [UInt32: Int] = [:]
            for bit in 0..<(bytes * 8) {
                var message = [UInt8](repeating: 0, count: bytes)
                message[bit / 8] = 0x80 >> UInt8(bit % 8)
                table[syndrome(message)] = bit
            }
            tables[bytes] = table
        }
        return tables
    }()

    /// Repairs a message whose parity is a plain CRC (DF17/18) if exactly one bit is wrong, never touching the first
    /// five bits (the downlink format). Returns the index of the bit repaired, or nil if it cannot be.
    public static func correctSingleBit(_ message: inout [UInt8]) -> Int? {
        let current = syndrome(message)
        guard current != 0, let bit = singleBitSyndromes[message.count]?[current], bit >= 5 else { return nil }
        message[bit / 8] ^= 0x80 >> UInt8(bit % 8)
        return bit
    }
}
