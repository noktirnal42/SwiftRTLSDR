// SPDX-License-Identifier: GPL-2.0-or-later
//
// Checksums and bit helpers used by the ISM decoders, ported from rtl_433's bit_util.c (Tommy Vestermark;
// GPL-2.0-or-later, release 25.02). See PROVENANCE.md.

/// The integrity checks and bit tricks sensor protocols use.
public enum BitUtil {
    public static func reverse8(_ x: UInt8) -> UInt8 {
        var x = x
        x = (x & 0xf0) >> 4 | (x & 0x0f) << 4
        x = (x & 0xcc) >> 2 | (x & 0x33) << 2
        x = (x & 0xaa) >> 1 | (x & 0x55) << 1
        return x
    }

    /// Reverses the bit order within each nibble.
    public static func reflectNibbles(_ message: inout [UInt8], count: Int? = nil) {
        for index in 0..<min(count ?? message.count, message.count) {
            var x = message[index]
            x = (x & 0xcc) >> 2 | (x & 0x33) << 2
            x = (x & 0xaa) >> 1 | (x & 0x55) << 1
            message[index] = x
        }
    }

    /// CRC-8, MSB first.
    public static func crc8(_ message: some Collection<UInt8>, polynomial: UInt8, initial: UInt8) -> UInt8 {
        var remainder = initial
        for byte in message {
            remainder ^= byte
            for _ in 0..<8 { remainder = remainder & 0x80 != 0 ? remainder << 1 ^ polynomial : remainder << 1 }
        }
        return remainder
    }

    /// CRC-8, LSB first (polynomial and initial value given MSB first, as rtl_433 takes them).
    public static func crc8le(_ message: some Collection<UInt8>, polynomial: UInt8, initial: UInt8) -> UInt8 {
        var remainder = reverse8(initial)
        let polynomial = reverse8(polynomial)
        for byte in message {
            remainder ^= byte
            for _ in 0..<8 { remainder = remainder & 1 != 0 ? remainder >> 1 ^ polynomial : remainder >> 1 }
        }
        return remainder
    }

    /// CRC-16, MSB first.
    public static func crc16(_ message: some Collection<UInt8>, polynomial: UInt16, initial: UInt16) -> UInt16 {
        var remainder = initial
        for byte in message {
            remainder ^= UInt16(byte) << 8
            for _ in 0..<8 { remainder = remainder & 0x8000 != 0 ? remainder << 1 ^ polynomial : remainder << 1 }
        }
        return remainder
    }

    /// LFSR-based "digest" checksum: each set message bit (MSB first) XORs the current key into the sum; the key
    /// shifts right through the generator after every bit.
    public static func lfsrDigest8(_ message: some Collection<UInt8>, generator: UInt8, key: UInt8) -> UInt8 {
        var sum: UInt8 = 0
        var key = key
        for data in message {
            for bit in (0..<8).reversed() {
                if (data >> UInt8(bit)) & 1 != 0 { sum ^= key }
                key = key & 1 != 0 ? key >> 1 ^ generator : key >> 1
            }
        }
        return sum
    }

    /// The reflected variant: bytes from last to first, bits LSB first, the key shifting left.
    public static func lfsrDigest8Reflect(_ message: [UInt8], generator: UInt8, key: UInt8) -> UInt8 {
        var sum: UInt8 = 0
        var key = key
        for data in message.reversed() {
            for bit in 0..<8 {
                if (data >> UInt8(bit)) & 1 != 0 { sum ^= key }
                key = key & 0x80 != 0 ? key << 1 ^ generator : key << 1
            }
        }
        return sum
    }

    public static func lfsrDigest16(_ message: some Collection<UInt8>, generator: UInt16, key: UInt16) -> UInt16 {
        var sum: UInt16 = 0
        var key = key
        for data in message {
            for bit in (0..<8).reversed() {
                if (data >> UInt8(bit)) & 1 != 0 { sum ^= key }
                key = key & 1 != 0 ? key >> 1 ^ generator : key >> 1
            }
        }
        return sum
    }

    public static func parity8(_ byte: UInt8) -> Int {
        var byte = byte
        byte ^= byte >> 4
        byte &= 0x0f
        return (0x6996 >> Int(byte)) & 1
    }

    public static func parity(_ message: some Collection<UInt8>) -> Int {
        message.reduce(0) { $0 ^ parity8($1) }
    }

    public static func xorBytes(_ message: some Collection<UInt8>) -> UInt8 { message.reduce(0, ^) }

    public static func addBytes(_ message: some Collection<UInt8>) -> Int { message.reduce(0) { $0 + Int($1) } }
}
