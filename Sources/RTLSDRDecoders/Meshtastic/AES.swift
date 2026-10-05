// SPDX-License-Identifier: GPL-2.0-or-later
//
// AES (FIPS-197), the forward cipher only, and counter mode (NIST SP 800-38A) with a counter in the last bytes of
// the block, as Meshtastic encrypts its packets. Written for this package from the standards.

/// The AES block cipher with a 128, 192 or 256-bit key; encryption only (counter mode needs no more).
public struct AES: Sendable {
    private let roundKeys: [UInt32]
    private let rounds: Int

    /// nil unless the key is 16, 24 or 32 bytes.
    public init?(key: [UInt8]) {
        guard [16, 24, 32].contains(key.count) else { return nil }
        let words = key.count / 4
        rounds = words + 6
        var w = [UInt32](repeating: 0, count: 4 * (rounds + 1))
        for i in 0..<words {
            w[i] = UInt32(key[4 * i]) << 24 | UInt32(key[4 * i + 1]) << 16 | UInt32(key[4 * i + 2]) << 8 | UInt32(key[4 * i + 3])
        }
        var rcon: UInt8 = 1
        for i in words..<w.count {
            var t = w[i - 1]
            if i % words == 0 {
                t = AES.subWord(t << 8 | t >> 24) ^ UInt32(rcon) << 24
                rcon = AES.times2(rcon)
            } else if words > 6 && i % words == 4 {
                t = AES.subWord(t)
            }
            w[i] = w[i - words] ^ t
        }
        roundKeys = w
    }

    /// Encrypts one 16-byte block.
    public func encrypt(_ block: [UInt8]) -> [UInt8] {
        precondition(block.count == 16)
        var s = block
        addRoundKey(&s, 0)
        for round in 1..<rounds {
            substituteAndShift(&s)
            mixColumns(&s)
            addRoundKey(&s, round)
        }
        substituteAndShift(&s)
        addRoundKey(&s, rounds)
        return s
    }

    /// Counter mode: the keystream is the cipher of `iv`, then of `iv` with its last `counterBytes` bytes counted up
    /// as a big-endian number, block by block. The same call encrypts and decrypts.
    public func ctr(_ data: [UInt8], iv: [UInt8], counterBytes: Int = 4) -> [UInt8] {
        precondition(iv.count == 16 && (1...16).contains(counterBytes))
        var counter = iv, output = data, offset = 0
        while offset < data.count {
            let stream = encrypt(counter)
            for k in 0..<min(16, data.count - offset) { output[offset + k] ^= stream[k] }
            offset += 16
            for k in stride(from: 15, through: 16 - counterBytes, by: -1) {
                counter[k] &+= 1
                if counter[k] != 0 { break }
            }
        }
        return output
    }

    // MARK: Rounds

    private func addRoundKey(_ s: inout [UInt8], _ round: Int) {
        for column in 0..<4 {
            let k = roundKeys[4 * round + column]
            s[4 * column] ^= UInt8(k >> 24)
            s[4 * column + 1] ^= UInt8(truncatingIfNeeded: k >> 16)
            s[4 * column + 2] ^= UInt8(truncatingIfNeeded: k >> 8)
            s[4 * column + 3] ^= UInt8(truncatingIfNeeded: k)
        }
    }

    /// SubBytes and ShiftRows: row r (bytes r, r+4, r+8, r+12) turns left by r.
    private func substituteAndShift(_ s: inout [UInt8]) {
        let t = s.map { AES.sbox[Int($0)] }
        for row in 0..<4 {
            for column in 0..<4 { s[4 * column + row] = t[4 * ((column + row) % 4) + row] }
        }
    }

    private func mixColumns(_ s: inout [UInt8]) {
        for column in 0..<4 {
            let a = Array(s[(4 * column)..<(4 * column + 4)])
            let b = a.map(AES.times2)
            s[4 * column] = b[0] ^ a[1] ^ b[1] ^ a[2] ^ a[3]
            s[4 * column + 1] = a[0] ^ b[1] ^ a[2] ^ b[2] ^ a[3]
            s[4 * column + 2] = a[0] ^ a[1] ^ b[2] ^ a[3] ^ b[3]
            s[4 * column + 3] = a[0] ^ b[0] ^ a[1] ^ a[2] ^ b[3]
        }
    }

    // MARK: Tables

    private static func times2(_ x: UInt8) -> UInt8 { (x << 1) ^ (x & 0x80 != 0 ? 0x1b : 0) }

    private static func subWord(_ w: UInt32) -> UInt32 {
        UInt32(sbox[Int(w >> 24)]) << 24 | UInt32(sbox[Int(w >> 16 & 0xff)]) << 16
            | UInt32(sbox[Int(w >> 8 & 0xff)]) << 8 | UInt32(sbox[Int(w & 0xff)])
    }

    /// The S-box: the multiplicative inverse in GF(2^8) (0 for 0), then the affine map b ^ rotl(b, 1…4) ^ 0x63.
    private static let sbox: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for x in 0..<256 {
            var inverse: UInt8 = 0
            if x != 0 {
                for y in 1..<256 where multiply(UInt8(x), UInt8(y)) == 1 { inverse = UInt8(y); break }
            }
            var b = inverse
            for shift in 1...4 { b ^= inverse << shift | inverse >> (8 - shift) }
            table[x] = b ^ 0x63
        }
        return table
    }()

    private static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a, b = b, product: UInt8 = 0
        while b != 0 {
            if b & 1 != 0 { product ^= a }
            a = times2(a)
            b >>= 1
        }
        return product
    }
}
