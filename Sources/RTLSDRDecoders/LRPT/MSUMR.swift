// SPDX-License-Identifier: GPL-2.0-or-later
//
// MSU-MR imagery from LRPT packets: each packet of APIDs 64-69 carries 14 8×8 blocks compressed like baseline JPEG
// (standard Huffman tables, the standard quantisation table scaled by a per-packet quality). Ported from meteor_decode by
// dbdexter-dev (MIT licence, https://github.com/dbdexter-dev/meteor_decode: jpeg/huffman.c, jpeg/jpeg.c,
// parser/mcu_parser.c, channel.c and the packet dispatch in main.c; copyright notice in NOTICE), keeping its
// fixed-point inverse DCT so that both produce the same pixels. See PROVENANCE.md.

/// An 8-bit greyscale raster.
public struct GrayImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var png: [UInt8] { PNG.encode(width: width, height: height, channels: 1, pixels: pixels) }
}

enum MSUMRCompression {
    static let blocksPerPacket = 14
    private static let dcPrefixSize: [Int] = [2, 3, 3, 3, 3, 3, 4, 5, 6, 7, 8, 9]
    private static let acTableSize: [UInt32] = [0, 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125]
    private static let acTable: [UInt32] = [
        1, 2, 3, 0, 4, 17, 5, 18, 33, 49, 65, 6, 19, 81, 97, 7, 34, 113, 20, 50, 129, 145, 161, 8, 35, 66, 177, 193,
        21, 82, 209, 240, 36, 51, 98, 114, 130, 9, 10, 22, 23, 24, 25, 26, 37, 38, 39, 40, 41, 42, 52, 53, 54, 55, 56,
        57, 58, 67, 68, 69, 70, 71, 72, 73, 74, 83, 84, 85, 86, 87, 88, 89, 90, 99, 100, 101, 102, 103, 104, 105, 106,
        115, 116, 117, 118, 119, 120, 121, 122, 131, 132, 133, 134, 135, 136, 137, 138, 146, 147, 148, 149, 150, 151,
        152, 153, 154, 162, 163, 164, 165, 166, 167, 168, 169, 170, 178, 179, 180, 181, 182, 183, 184, 185, 186, 194,
        195, 196, 197, 198, 199, 200, 201, 202, 210, 211, 212, 213, 214, 215, 216, 217, 218, 225, 226, 227, 228, 229,
        230, 231, 232, 233, 234, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250,
    ]
    private static let quantization: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
    ]
    private static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34,
        27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]
    // cos((2x+1)uπ/16) in Q14.
    private static let cosine: [Int32] = [
        0x4000, 0x3ec5, 0x3b21, 0x3537, 0x2d41, 0x238e, 0x187e, 0x0c7c,
        0x4000, 0x3537, 0x187e, -0x0c7c, -0x2d41, -0x3ec5, -0x3b21, -0x238e,
        0x4000, 0x238e, -0x187e, -0x3ec5, -0x2d41, 0x0c7c, 0x3b21, 0x3537,
        0x4000, 0x0c7c, -0x3b21, -0x238e, 0x2d41, 0x3537, -0x187e, -0x3ec5,
        0x4000, -0x0c7c, -0x3b21, 0x238e, 0x2d41, -0x3537, -0x187e, 0x3ec5,
        0x4000, -0x238e, -0x187e, 0x3ec5, -0x2d41, -0x0c7c, 0x3b21, -0x3537,
        0x4000, -0x3537, 0x187e, 0x0c7c, -0x2d41, 0x3ec5, -0x3b21, 0x238e,
        0x4000, -0x3ec5, 0x3b21, -0x3537, 0x2d41, -0x238e, 0x187e, -0x0c7c,
    ]

    /// Up to 32 bits from `data` at `bit`, MSB first (bytes past the end read as zero).
    @inline(__always)
    private static func bits(_ data: UnsafeBufferPointer<UInt8>, _ bit: Int, _ count: Int) -> UInt32 {
        guard count > 0 else { return 0 }
        var byte = bit >> 3
        let skip = bit & 7
        func at(_ index: Int) -> UInt64 { index < data.count ? UInt64(data[index]) : 0 }
        var value = at(byte) & ((1 << (8 - skip)) - 1)
        var remaining = count - (8 - skip)
        byte += 1
        while remaining > 0 {
            value = value << 8 | at(byte)
            byte += 1
            remaining -= 8
        }
        return UInt32(truncatingIfNeeded: value >> UInt64(-remaining))
    }

    private static func dcCategory(_ codeword: UInt32) -> Int? {
        if codeword >> 14 == 0 { return 0 }
        if codeword >> 13 < 7 { return Int(codeword >> 13) - 1 }
        if codeword >> 12 < 0xf { return 6 }
        if codeword >> 11 < 0x1f { return 7 }
        if codeword >> 10 < 0x3f { return 8 }
        if codeword >> 9 < 0x7f { return 9 }
        if codeword >> 8 < 0xff { return 10 }
        if codeword >> 7 < 0x1ff { return 11 }
        return nil
    }

    /// Huffman-decodes 14 blocks of coefficients (zig-zag order) from `data`, at most `maximum` bytes of it.
    static func huffman(_ data: UnsafeBufferPointer<UInt8>, maximum: Int) -> [[Int16]] {
        var blocks = [[Int16]](repeating: [Int16](repeating: 0, count: 64), count: blocksPerPacket)
        var base = 0                               // byte where `bit` counts from
        var bit = 0
        var bytes = 0
        var dc = 0
        func view() -> UnsafeBufferPointer<UInt8> { UnsafeBufferPointer(rebasing: data[min(base, data.count)...]) }
        blockLoop: for block in 0..<blocksPerPacket {
            let dcInfo = bits(view(), bit, 32)
            guard let category = dcCategory(dcInfo >> 16) else { break }
            let prefix = dcPrefixSize[category]
            if category > 0 {
                let sign = (dcInfo >> UInt32(31 - prefix)) & 1
                let extra = Int((dcInfo >> UInt32(31 - prefix - category + 1)) & ((1 << UInt32(category - 1)) - 1))
                dc += extra + (sign != 0 ? 1 << (category - 1) : 1 - (1 << category))
            }
            blocks[block][0] = Int16(truncatingIfNeeded: dc)
            bit += prefix + category
            base += bit / 8; bytes += bit / 8; bit %= 8
            if bytes >= maximum { break }

            var r = 1
            while r < 64 {
                let acBuffer = bits(view(), bit, 32)
                var first: UInt32 = 0
                var index = 0
                var acInfo: UInt32 = 0
                var length = 2
                while length < acTableSize.count {
                    acInfo = acBuffer >> UInt32(32 - length)
                    if acInfo &- first < acTableSize[length] {
                        acInfo = acTable[index + Int(acInfo &- first)]
                        break
                    }
                    first = (first &+ acTableSize[length]) << 1
                    index += Int(acTableSize[length])
                    length += 1
                }
                bit += length
                if acInfo == 0 {                           // end of block
                    while r < 64 { blocks[block][r] = 0; r += 1 }
                } else {
                    var run = Int(acInfo >> 4 & 0x0f)
                    let category = Int(acInfo & 0x0f)
                    let sign = bits(view(), bit, 1)
                    let extra = Int(bits(view(), bit + 1, category - 1))
                    let coefficient = category > 0 ? extra + (sign != 0 ? 1 << (category - 1) : 1 - (1 << category)) : 0
                    while run > 0 && r < 63 { blocks[block][r] = 0; run -= 1; r += 1 }
                    blocks[block][r] = Int16(truncatingIfNeeded: coefficient)
                    bit += category
                }
                base += bit / 8; bytes += bit / 8; bit %= 8
                if bytes >= maximum { break blockLoop }
                r += 1
            }
        }
        return blocks
    }

    private static func quantizer(_ quality: Int, _ index: Int) -> Int {
        let ratio = quality < 50 ? 5000 / quality : 200 - 2 * quality
        return max(1, ((quantization[index] * ratio / 50) + 1) / 2)
    }

    @inline(__always)
    private static func qmul(_ x: Int32, _ y: Int32) -> Int32 { Int32(Int16(truncatingIfNeeded: (x &* y) >> 14)) }

    /// One block: un-zig-zag, dequantise, fixed-point inverse DCT; 64 pixels, row-major.
    static func decode(_ block: [Int16], quality: Int) -> [UInt8] {
        var coefficients = [Int16](repeating: 0, count: 64)
        for index in 0..<64 { coefficients[zigzag[index]] = block[index] }
        for index in 0..<64 {
            coefficients[index] = Int16(truncatingIfNeeded: Int32(coefficients[index]) &* Int32(quantizer(quality, index)))
        }
        var work = [Int32](repeating: 0, count: 64)
        for i in 0..<8 {
            let alpha: Int32 = i != 0 ? 0x4000 : 0x2d41
            for j in 0..<8 {
                let c = Int32(coefficients[j * 8 + i])
                for u in 0..<8 { work[j * 8 + u] = work[j * 8 + u] &+ qmul(alpha, cosine[u * 8 + i]) &* c }
            }
        }
        var pixels = [UInt8](repeating: 0, count: 64)
        for j in 0..<8 {
            var row = [Int32](repeating: 0, count: 8)
            for i in 0..<8 {
                let alpha: Int32 = i != 0 ? 0x4000 : 0x2d41
                for v in 0..<8 {
                    let product = (Int64(work[i * 8 + j]) * Int64(qmul(alpha, cosine[v * 8 + i]))) >> 14
                    row[v] = row[v] &+ Int32(truncatingIfNeeded: product)
                }
            }
            for i in 0..<8 { pixels[i * 8 + j] = UInt8(max(0, min(255, ((row[i] / 4) >> 14) + 128))) }
        }
        return pixels
    }
}

/// One MSU-MR channel's image, 1568 pixels wide, growing 8 lines at a time.
public final class MSUMRChannel {
    public static let blocksPerLine = 196                      // 14 packets of 14 blocks
    public static let width = blocksPerLine * 8
    static let packetsPerLine = 14
    static let packetsPerPeriod = 3 * packetsPerLine + 1       // three channels and a calibration packet
    static let sequenceModulus = 16_384
    static let stripPixels = blocksPerLine * 64

    public let apid: Int
    var blockSequence = 0
    var packetSequence = -1
    private(set) var pixels: [UInt8] = []
    /// Pixels in whole strips (8 lines) so far.
    public private(set) var offset = 0

    init(apid: Int) { self.apid = apid }

    /// Lines received so far (complete strips only).
    public var lines: Int { offset / Self.width }

    /// The image so far: whole strips, or `height` lines (what has been filled of a strip in progress, then black).
    public func image(height requested: Int? = nil) -> GrayImage {
        let height = requested ?? lines
        var out = Array(pixels.prefix(height * Self.width))
        if out.count < height * Self.width { out += [UInt8](repeating: 0, count: height * Self.width - out.count) }
        return GrayImage(width: Self.width, height: height, pixels: out)
    }

    /// Lines including the strip being filled.
    public var startedLines: Int { lines + (blockSequence > 0 ? 8 : 0) }

    /// Appends 14 decoded blocks (nil: black), filling lost strips from the packet and block sequence numbers.
    func append(_ strip: [[UInt8]]?, blockSequence rawBlock: Int, packetSequence: Int) {
        let block = rawBlock - rawBlock % MSUMRCompression.blocksPerPacket
        let packetDelta = (packetSequence - self.packetSequence - 1 + Self.sequenceModulus) % Self.sequenceModulus
        let blockDelta = (block - blockSequence + Self.blocksPerLine) % Self.blocksPerLine
        let linesLost = self.packetSequence < 0 ? 0 : packetDelta / Self.packetsPerPeriod
        let stripsLost = blockDelta / MSUMRCompression.blocksPerPacket + linesLost * Self.packetsPerLine
        for _ in 0..<stripsLost { cache(nil) }
        self.packetSequence = packetSequence
        blockSequence = block
        cache(strip)
    }

    private func cache(_ strip: [[UInt8]]?) {
        if offset + Self.stripPixels > pixels.count {
            pixels += [UInt8](repeating: 0, count: 32 * Self.stripPixels)
        }
        if let strip {
            for row in 0..<8 {
                for block in 0..<MSUMRCompression.blocksPerPacket {
                    let start = offset + row * Self.width + (blockSequence + block) * 8
                    for x in 0..<8 where start + x < pixels.count { pixels[start + x] = strip[block][row * 8 + x] }
                }
            }
        } else {
            for row in 0..<8 {
                let start = offset + row * Self.width + blockSequence * 8
                for x in 0..<(MSUMRCompression.blocksPerPacket * 8) where start + x < pixels.count { pixels[start + x] = 0 }
            }
        }
        blockSequence += MSUMRCompression.blocksPerPacket
        if blockSequence >= Self.blocksPerLine {
            blockSequence = 0
            packetSequence += Self.packetsPerPeriod - Self.packetsPerLine
            offset += Self.stripPixels
        }
    }
}

/// Builds MSU-MR channel images from LRPT packets.
public final class MSUMRImager {
    static let microsecondsPerLine: UInt64 = 1_220_000         // a lower bound (meteor_decode's)
    static let microsecondsPerDay: UInt64 = 86_400_000_000

    public private(set) var channels: [Int: MSUMRChannel] = [:]
    public private(set) var firstTime: UInt64?
    public private(set) var lastTime: UInt64 = 0
    public private(set) var packetsDecoded = 0

    public init() {}

    /// The channels in APID order.
    public var orderedChannels: [MSUMRChannel] { channels.keys.sorted().compactMap { channels[$0] } }

    /// Takes one packet. Returns the APID if it was an image packet that was used.
    @discardableResult
    public func add(_ packet: LRPTPacket) -> Int? {
        let apid = packet.apid
        let time = packet.time
        if firstTime == nil { firstTime = time }
        let first = firstTime!
        // After a reboot the on-board clock can jump backwards: such packets are dropped.
        if time < first && first - time < Self.microsecondsPerDay / 2 { return nil }
        lastTime = time
        guard (64...69).contains(apid) else { return nil }

        let channel = channels[apid] ?? MSUMRChannel(apid: apid)
        channels[apid] = channel
        let payload = packet.decodingBuffer
        // The payload: block sequence, scan header (2), segment header (3, the last is the quality), then the data.
        let blockSequence = Int(payload[0])
        let quality = Int(payload[5])
        var strip: [[UInt8]]?
        if quality > 0 {
            let blocks = payload.withUnsafeBufferPointer { buffer in
                MSUMRCompression.huffman(UnsafeBufferPointer(rebasing: buffer[6...]), maximum: packet.length)
            }
            strip = blocks.map { MSUMRCompression.decode($0, quality: quality) }
        }
        if channel.packetSequence < 0 {
            // The first packet of a channel: place it by time relative to the first packet of any channel.
            let linesLost = Int((time &- first) / Self.microsecondsPerLine)
            channel.packetSequence = ((packet.sequence - MSUMRChannel.packetsPerPeriod * linesLost - 1) % MSUMRChannel.sequenceModulus
                                      + MSUMRChannel.sequenceModulus) % MSUMRChannel.sequenceModulus
        }
        channel.append(strip, blockSequence: blockSequence, packetSequence: packet.sequence)
        packetsDecoded += 1
        return apid
    }

    /// The height meteor_decode gives every channel's image: the most whole strips any channel has (a channel that
    /// is behind shows what it has of its strip in progress).
    public var commonHeight: Int { channels.values.map(\.lines).max() ?? 0 }

    /// A channel's image at the common height.
    public func image(apid: Int) -> GrayImage? { channels[apid].map { $0.image(height: commonHeight) } }

    /// meteor_decode's choice of channels for a colour composite: red from 66 or 68, green from 65 or 67, blue from 64
    /// or 69 (so RGB123 by day, RGB125 at night). `height`: defaults to the common height.
    public func composite(height requested: Int? = nil) -> RGBImage? {
        func pick(_ choices: [Int]) -> MSUMRChannel? { choices.lazy.compactMap { self.channels[$0] }.first }
        let height = requested ?? commonHeight
        guard height > 0 else { return nil }
        let red = pick([66, 68]), green = pick([65, 67]), blue = pick([64, 69])
        let sources = [red, green, blue].map { $0?.image(height: height) }
        var image = RGBImage(width: MSUMRChannel.width, height: height)
        for y in 0..<height {
            for x in 0..<MSUMRChannel.width {
                func value(_ source: GrayImage?) -> UInt8 {
                    guard let source, y < source.height else { return 0 }
                    return source.pixels[y * source.width + x]
                }
                image.set(x, y, (value(sources[0]), value(sources[1]), value(sources[2])))
            }
        }
        return image
    }
}

extension LRPTPacket {
    /// The payload after the time stamp, padded to meteor_decode's buffer size (its decoder may look a few bytes past
    /// the data).
    var decodingBuffer: [UInt8] {
        var buffer = Array(payload)
        if buffer.count < 2048 { buffer += [UInt8](repeating: 0, count: 2048 - buffer.count) }
        return buffer
    }
}
