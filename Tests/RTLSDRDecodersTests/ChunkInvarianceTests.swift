// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

/// SH-4: a decoder fed from an app gets the same results however the app cuts the stream. Each decoder's test runs its
/// signal in one piece and in several random plans of piece sizes, and compares the events as text (`String(describing:)`,
/// exact for these value types). Piece sizes are even where the stream is I/Q, so a piece never splits a sample.
enum ChunkPlans {
    /// Feeds `total` items in the pieces of `plan` (the last piece takes whatever is left), then calls `finish`.
    static func events(total: Int, plan: [Int], feed: (Range<Int>) throws -> [String], finish: () throws -> [String]) rethrows -> [String] {
        var out: [String] = []
        var position = 0
        for length in plan where position < total {
            let end = min(total, position + length)
            out += try feed(position..<end)
            position = end
        }
        if position < total { out += try feed(position..<total) }
        return try out + finish()
    }

    /// `count` plans of random piece sizes from 1 to `maximum` (odd sizes split I/Q samples, as an app's buffers may),
    /// one plan per seed.
    static func anyPlans(seeds: [UInt64], count: Int, maximum: Int) -> [[Int]] {
        seeds.map { seed in
            var generator = Seeded(state: seed)
            return (0..<count).map { _ in Int.random(in: 1...maximum, using: &generator) }
        }
    }

    /// `count` plans of random even piece sizes from 2 to `maximum`, one per seed.
    static func evenPlans(seeds: [UInt64], count: Int, maximum: Int) -> [[Int]] {
        seeds.map { seed in
            var generator = Seeded(state: seed)
            return (0..<count).map { _ in 2 * Int.random(in: 1...(maximum / 2), using: &generator) }
        }
    }
}

struct ISMChunkingTests {
    @Test func anyChunkingGivesExactlyWhatOneBigFeedGives() {
        let bits = bitsOf([0xb5, 0x90, 0xd5, 0xf3, 0x70], count: 36)
        var pairs: [(on: Double, off: Double)] = []
        for _ in 0..<12 {
            pairs += bits.map { (500, $0 ? 2_000 : 1_000) }
            pairs.append((500, 4_000))
        }
        var modulator = ISMModulator()
        let iq = modulator.ook(pairs)
        func run(_ plan: [Int]) throws -> [String] {
            let receiver = ISMReceiver()
            return try ChunkPlans.events(total: iq.count, plan: plan, feed: { range in
                receiver.process(Array(iq[range])).map { String(describing: $0) }
            }, finish: { receiver.flush().map { String(describing: $0) } })
        }
        let whole = (try? run([iq.count])) ?? []
        #expect(whole.count == 1, "the one transmission decodes")
        for plan in ChunkPlans.anyPlans(seeds: [1, 2, 3, 4], count: 300, maximum: 6_000) {
            #expect((try? run(plan)) == whole)
        }
    }
}

struct POCSAGChunkingTests {
    @Test func anyChunkingGivesExactlyWhatOneBigFeedGives() throws {
        let pages = [
            POCSAGEncoder.Page(address: 1_234_567, function: 3, text: "Fire at 12 Main St, ALARM 4021"),
            POCSAGEncoder.Page(address: 55_126, function: 0, text: "6]3730-047 [87", numeric: true),
        ]
        let bits = POCSAGEncoder.bits(POCSAGEncoder.codewords(pages))
        var modulator = POCSAGModulator(baud: 1200, sampleRate: 240_000, carrierHz: 3_000)
        let iq = modulator.iq(bits)
        func run(_ plan: [Int]) throws -> [String] {
            let receiver = POCSAGReceiver(sampleRate: 240_000, offsetHz: 3_000)
            return try ChunkPlans.events(total: iq.count, plan: plan, feed: { range in
                try receiver.process(iq: Array(iq[range])).map { String(describing: $0) }
            }, finish: { try receiver.flush().map { String(describing: $0) } })
        }
        let whole = try run([iq.count])
        #expect(whole.count == 2, "both pages decode")
        for plan in ChunkPlans.anyPlans(seeds: [5, 6, 7], count: 40, maximum: 40_000) {
            #expect(try run(plan) == whole)
        }
    }
}
