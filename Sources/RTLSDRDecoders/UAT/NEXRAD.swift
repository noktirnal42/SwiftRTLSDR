// SPDX-License-Identifier: GPL-2.0-or-later
//
// FIS-B NEXRAD "global block representation" (products 63 and 64), ported from extract_nexrad.c in dump978 by Oliver
// Jowett (GPL-2.0-or-later, https://github.com/mutability/dump978); the colours follow its plot_nexrad.py. See
// PROVENANCE.md.
import Foundation

/// One block of a FIS-B radar mosaic: 32 × 4 bins of precipitation intensity over a patch of the globe.
///
/// Blocks are numbered from 0 just north-east of (0°, 0°), eastward around each 4-arcminute ring of latitude (450
/// blocks of 48 arcminutes per ring below 60°; above 60° blocks are 96 arcminutes wide and only even numbers are used),
/// then northward; the southern hemisphere mirrors this and is flagged. Scale factors 1 and 2 make each bin 5 or 9
/// times larger in both directions, anchored at the same north-west corner.
public struct NEXRADBlock: Sendable, Equatable {
    public enum Product: String, Sendable {
        /// Product 63: around the ground station, finest resolution.
        case regional = "Regional"
        /// Product 64: the contiguous United States, coarser.
        case conus = "CONUS"
    }

    public var product: Product
    public var hours: Int
    public var minutes: Int
    public var scaleFactor: Int
    /// North edge, in arcminutes (negative south of the equator).
    public var northArcminutes: Int
    /// West edge, in arcminutes east of Greenwich, 0 ..< 21600 (subtract 21600 for the usual -180...180 range).
    public var westArcminutes: Int
    public var heightArcminutes: Int
    public var widthArcminutes: Int
    /// Intensities 0-7, west to east then north to south (32 per row); normally 128 of them.
    public var bins: [UInt8]

    static let blocksPerRing = 450
    static let wideBlockThreshold = 405_000             // the first block at 60°N

    /// The blocks in a product 63 or 64 APDU (a run-length coded block, or a list of empty blocks); [] otherwise.
    public static func blocks(in product: FISBProduct) -> [NEXRADBlock] {
        guard product.productID == 63 || product.productID == 64, product.payload.count >= 3 else { return [] }
        let kind: Product = product.productID == 63 ? .regional : .conus
        let data = product.payload
        let runLength = data[0] & 0x80 != 0
        let south = data[0] & 0x40 != 0
        let scale = Int(data[0] & 0x30) >> 4
        let blockNumber = Int(data[0] & 0x0f) << 16 | Int(data[1]) << 8 | Int(data[2])

        func block(_ number: Int, bins: [UInt8]) -> NEXRADBlock {
            let factor = scale == 1 ? 5 : scale == 2 ? 9 : 1
            let wide = number >= wideBlockThreshold
            let used = wide ? number & ~1 : number
            let ring = used / blocksPerRing
            return NEXRADBlock(product: kind, hours: product.hours, minutes: product.minutes, scaleFactor: scale,
                               northArcminutes: south ? -4 * ring : 4 * ring + 4, westArcminutes: (used % blocksPerRing) * 48,
                               heightArcminutes: 4 * factor, widthArcminutes: (wide ? 96 : 48) * factor, bins: bins)
        }

        if runLength {
            // Each byte: run length - 1 (5 bits), intensity (3 bits).
            var bins: [UInt8] = []
            for byte in data[3...] { bins += [UInt8](repeating: byte & 7, count: Int(byte >> 3) + 1) }
            return [block(blockNumber, bins: bins)]
        }

        // Empty blocks: the header's block, and a bitmap of the blocks after it on the same ring (wrapping around it).
        guard data.count >= 4 else { return [] }
        let bitmapBytes = Int(data[3] & 15)
        let rowSize = blockNumber >= wideBlockThreshold ? 225 : blocksPerRing
        let rowStart = blockNumber >= wideBlockThreshold
            ? blockNumber - (blockNumber - wideBlockThreshold) % 225
            : blockNumber - blockNumber % blocksPerRing
        let rowOffset = blockNumber - rowStart
        // An empty CONUS block is "valid data, no precipitation" (1); an empty regional one is below 5 dBZ (0).
        let empty = [UInt8](repeating: kind == .regional ? 0 : 1, count: 128)
        var blocks: [NEXRADBlock] = []
        for i in 0..<bitmapBytes {
            guard i == 0 || i + 3 < data.count else { break }
            // The first byte holds 4 flags beside the length; bit 3 stands for the header's own block.
            let bits = i == 0 ? (Int(data[3]) & 0xf0) | 0x08 : Int(data[i + 3])
            for j in 0..<8 where bits & (1 << j) != 0 {
                let x = (rowOffset + 8 * i + j - 3) % rowSize
                blocks.append(block(rowStart + x, bins: empty))
            }
        }
        return blocks
    }

    /// The line `extract_nexrad` prints for this block.
    public var extractNexradLine: String {
        "NEXRAD \(product.rawValue) " + String(format: "%02d:%02d %d %d %d %d %d ", hours, minutes, scaleFactor,
               northArcminutes, westArcminutes, heightArcminutes, widthArcminutes) + bins.map { String($0) }.joined()
    }
}

/// Paints NEXRAD blocks from one product and time into a picture (plate carrée: latitude and longitude linear).
public struct NEXRADComposite: Sendable {
    public let product: NEXRADBlock.Product
    public let hours: Int
    public let minutes: Int
    public private(set) var blocks: [NEXRADBlock] = []

    public init(product: NEXRADBlock.Product, hours: Int, minutes: Int) {
        self.product = product
        self.hours = hours
        self.minutes = minutes
    }

    /// Adds a block if it belongs to this composite; returns whether it did.
    @discardableResult
    public mutating func add(_ block: NEXRADBlock) -> Bool {
        guard block.product == product, block.hours == hours, block.minutes == minutes else { return false }
        blocks.append(block)
        return true
    }

    /// The area covered, in arcminutes: north, south, west, east (west/east in the -180...180° convention).
    public var bounds: (north: Int, south: Int, west: Int, east: Int)? {
        guard !blocks.isEmpty else { return nil }
        let west = blocks.map { signedWest($0) }.min()!
        let east = blocks.map { signedWest($0) + $0.widthArcminutes }.max()!
        let north = blocks.map(\.northArcminutes).max()!
        let south = blocks.map { $0.northArcminutes - $0.heightArcminutes }.min()!
        return (north, south, west, east)
    }

    private func signedWest(_ block: NEXRADBlock) -> Int {
        block.westArcminutes >= 10_800 ? block.westArcminutes - 21_600 : block.westArcminutes
    }

    /// Colours for intensities 0-7, as plot_nexrad.py draws them (dark blue for no echo up to red for the strongest).
    public static let palette: [(UInt8, UInt8, UInt8)] = [
        (0, 0, 76), (0, 0, 102), (0, 136, 204), (0, 204, 136), (0, 255, 0), (170, 255, 0), (255, 187, 51), (255, 102, 102),
    ]

    /// Renders the composite at the finest scale present: one pixel per bin of that scale (1.5 × 1 arcminute for scale
    /// 0 below 60°). Coarser blocks are painted first, finer ones over them; uncovered pixels are black.
    public func image() -> RGBImage? {
        guard let bounds else { return nil }
        let finest = blocks.map(\.scaleFactor).min()!
        let factor = finest == 1 ? 5 : finest == 2 ? 9 : 1
        // 1.5' × 1' per pixel at scale 0: a block is 32 × 4 pixels (64 × 4 for the wide blocks above 60°).
        let pixelWidth = 1.5 * Double(factor), pixelHeight = 1.0 * Double(factor)
        let width = Int((Double(bounds.east - bounds.west) / pixelWidth).rounded(.up))
        let height = Int((Double(bounds.north - bounds.south) / pixelHeight).rounded(.up))
        guard width > 0, height > 0, width * height <= 50_000_000 else { return nil }
        var image = RGBImage(width: width, height: height)
        for block in blocks.sorted(by: { $0.scaleFactor > $1.scaleFactor }) {
            let binWidth = Double(block.widthArcminutes) / 32, binHeight = Double(block.heightArcminutes) / 4
            for (index, intensity) in block.bins.prefix(128).enumerated() {
                let column = index % 32, row = index / 32
                let west = Double(signedWest(block)) + Double(column) * binWidth
                let north = Double(block.northArcminutes) - Double(row) * binHeight
                let x0 = Int(((west - Double(bounds.west)) / pixelWidth).rounded())
                let x1 = Int(((west + binWidth - Double(bounds.west)) / pixelWidth).rounded())
                let y0 = Int(((Double(bounds.north) - north) / pixelHeight).rounded())
                let y1 = Int(((Double(bounds.north) - north + binHeight) / pixelHeight).rounded())
                let colour = Self.palette[Int(min(intensity, 7))]
                for y in max(0, y0)..<min(height, max(y0 + 1, y1)) {
                    for x in max(0, x0)..<min(width, max(x0 + 1, x1)) { image.set(x, y, colour) }
                }
            }
        }
        return image
    }
}

/// A plain 8-bit RGB raster.
public struct RGBImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public private(set) var pixels: [UInt8]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 3)
    }

    public mutating func set(_ x: Int, _ y: Int, _ colour: (UInt8, UInt8, UInt8)) {
        let offset = (y * width + x) * 3
        pixels[offset] = colour.0
        pixels[offset + 1] = colour.1
        pixels[offset + 2] = colour.2
    }

    public func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let offset = (y * width + x) * 3
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
    }

    /// The image as a PNG file (uncompressed deflate blocks: simple, and radar images are small).
    public var png: [UInt8] {
        var raw: [UInt8] = []
        raw.reserveCapacity((width * 3 + 1) * height)
        for y in 0..<height {
            raw.append(0)                                          // filter: none
            raw += pixels[(y * width * 3)..<((y + 1) * width * 3)]
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
        chunk("IHDR", bigEndian(UInt32(width)) + bigEndian(UInt32(height)) + [8, 2, 0, 0, 0])
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
