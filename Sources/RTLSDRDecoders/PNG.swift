// SPDX-License-Identifier: GPL-2.0-or-later

/// A minimal PNG writer: 8-bit greyscale or RGB, stored (uncompressed) deflate blocks. Simple, and enough for radar
/// mosaics and satellite images.
public enum PNG {
    public static func encode(width: Int, height: Int, channels: Int, pixels: [UInt8]) -> [UInt8] {
        precondition(channels == 1 || channels == 3, "greyscale or RGB")
        precondition(pixels.count >= width * height * channels)
        let stride = width * channels
        var raw: [UInt8] = []
        raw.reserveCapacity((stride + 1) * height)
        for y in 0..<height {
            raw.append(0)                                          // filter: none
            raw += pixels[(y * stride)..<((y + 1) * stride)]
        }
        var zlib: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let size = min(65_535, raw.count - offset)
            let last: UInt8 = offset + size >= raw.count ? 1 : 0
            zlib += [last, UInt8(size & 0xff), UInt8(size >> 8), UInt8(~size & 0xff), UInt8((~size >> 8) & 0xff)]
            zlib += raw[offset..<(offset + size)]
            offset += size
        } while offset < raw.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
        zlib += bigEndian(b << 16 | a)

        var file: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        func chunk(_ type: String, _ data: [UInt8]) {
            let body = Array(type.utf8) + data
            file += bigEndian(UInt32(data.count)) + body + bigEndian(crc32(body))
        }
        chunk("IHDR", bigEndian(UInt32(width)) + bigEndian(UInt32(height)) + [8, channels == 1 ? 0 : 2, 0, 0, 0])
        chunk("IDAT", zlib)
        chunk("IEND", [])
        return file
    }
}

private func bigEndian(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
}

private let crcTable: [UInt32] = (0..<256).map { n in
    var c = UInt32(n)
    for _ in 0..<8 { c = c & 1 != 0 ? 0xedb8_8320 ^ (c >> 1) : c >> 1 }
    return c
}

func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
    return crc ^ 0xffff_ffff
}
