// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Collects a stream's pieces into blocks of a fixed size, so the work done per block is the same however the stream was
/// cut. Used where a receiver's state moves between blocks (a frequency control, a timing loop).
struct FixedBlocks {
    let bytes: Int
    private var pending: [UInt8] = []

    init(bytes: Int) { self.bytes = bytes }

    /// The full blocks that the piece completes, in order (the rest is kept for the next piece).
    mutating func append(_ piece: [UInt8]) -> [[UInt8]] {
        pending += piece
        var blocks: [[UInt8]] = []
        while pending.count >= bytes {
            blocks.append(Array(pending[..<bytes]))
            pending.removeFirst(bytes)
        }
        return blocks
    }

    /// What is left for an incomplete block, or nil when nothing is.
    mutating func remainder() -> [UInt8]? {
        defer { pending = [] }
        return pending.isEmpty ? nil : pending
    }
}
