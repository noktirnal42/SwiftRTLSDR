// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

/// SH-2: filling lost strips must produce the same image as before, only faster. The reference is a checksum of the
/// image made by the per-pixel fill this test was written against.
struct LRPTBackfillTests {

    /// FNV-1a over the image's dimensions and pixels.
    private func checksum(_ image: GrayImage) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ byte: UInt8) { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        for byte in "\(image.width)x\(image.height)".utf8 { mix(byte) }
        for byte in image.pixels { mix(byte) }
        return hash
    }

    /// A seeded run of packets for one channel: most arrive, some are lost, and now and then the sequence jumps far
    /// (a gap of a few lines; the per-pixel fill made each one slow in a debug build).
    private func imageAfterGaps() -> GrayImage {
        var state: UInt64 = 0x9e37_79b9
        func random() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        let channel = MSUMRChannel(apid: 64)
        var packet = 0
        for _ in 0..<600 {
            packet += 1
            if random() < 0.03 { packet += 20 + Int(random() * 60) }          // a gap of a few lines
            guard random() > 0.2 else { continue }                              // a lost packet
            let strip = (0..<MSUMRCompression.blocksPerPacket).map { block in
                (0..<64).map { UInt8(truncatingIfNeeded: packet &* 31 &+ block &* 7 &+ $0) }
            }
            let blockSequence = (packet % 14) * MSUMRCompression.blocksPerPacket
            // The stream numbers packets 43 to a line (three channels and a calibration packet), so a lost packet of this
            // channel is a gap in the numbers, not a neighbour's number.
            let sequence = ((packet / 14) * 43 + packet % 14) % 16_384
            channel.append(strip, blockSequence: blockSequence, packetSequence: sequence)
        }
        return channel.image()
    }

    @Test func longGapsFillTheSameImageAsBefore() {
        let image = imageAfterGaps()
        #expect(image.width == MSUMRChannel.width)
        // Recorded from the per-pixel fill before the change: the bulk fill must give the same pixels.
        #expect(checksum(image) == 0xb779_9201_8367_db25)
        #expect(image.height == 1056)
    }
}
