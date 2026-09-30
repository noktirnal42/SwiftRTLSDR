// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// What a block of interleaved unsigned 8-bit I/Q looks like: its level, its DC offset, and how much of it sat on the
/// ADC's rails (0 or 255), which is the sign that the front end is clipping.
///
/// Levels use the same convention as `rtlsdr-tool capture`: samples are centred on 127.5 and 0 dBFS is a mean
/// |I + jQ|² of 127.5². Cheap enough to compute in a streaming handler (one pass, integer arithmetic).
public struct SampleStatistics: Sendable, Equatable {
    /// I/Q pairs seen.
    public var sampleCount: Int
    /// Individual I or Q values that were 0 or 255.
    public var railCount: Int
    /// Sums of the doubled, centred values (2·v − 255, an odd integer in −255...255), kept exact.
    public var sumI: Int
    public var sumQ: Int
    public var sumOfSquares: Int

    public init(sampleCount: Int = 0, railCount: Int = 0, sumI: Int = 0, sumQ: Int = 0, sumOfSquares: Int = 0) {
        self.sampleCount = sampleCount
        self.railCount = railCount
        self.sumI = sumI
        self.sumQ = sumQ
        self.sumOfSquares = sumOfSquares
    }

    /// Statistics of one block. A trailing odd byte (half a pair) is ignored.
    public init(_ block: UnsafeBufferPointer<UInt8>) {
        self.init()
        let pairs = block.count / 2
        var rails = 0, sumI = 0, sumQ = 0, squares = 0
        for pair in 0..<pairs {
            let rawI = block[2 * pair], rawQ = block[2 * pair + 1]
            let i = 2 * Int(rawI) - 255, q = 2 * Int(rawQ) - 255
            sumI += i
            sumQ += q
            squares += i * i + q * q
            if rawI == 0 || rawI == 255 { rails += 1 }
            if rawQ == 0 || rawQ == 255 { rails += 1 }
        }
        self.sampleCount = pairs
        self.railCount = rails
        self.sumI = sumI
        self.sumQ = sumQ
        self.sumOfSquares = squares
    }

    public init(_ bytes: [UInt8]) {
        self = bytes.withUnsafeBufferPointer { SampleStatistics($0) }
    }

    /// Combines two sets of statistics as if their samples had been one block.
    public mutating func merge(_ other: SampleStatistics) {
        sampleCount += other.sampleCount
        railCount += other.railCount
        sumI += other.sumI
        sumQ += other.sumQ
        sumOfSquares += other.sumOfSquares
    }

    /// The share of I and Q values that were on a rail (0...1).
    public var railFraction: Double {
        sampleCount == 0 ? 0 : Double(railCount) / Double(2 * sampleCount)
    }

    /// Mean power relative to full scale, in dB. Very quiet (or empty) blocks report −120.
    public var meanPowerDBFS: Double {
        guard sampleCount > 0, sumOfSquares > 0 else { return -120 }
        // Doubled values: divide the sum by 4 for the true squares, and by 127.5² for full scale.
        let meanSquare = Double(sumOfSquares) / 4 / Double(sampleCount)
        return max(-120, 10 * log10(meanSquare / (127.5 * 127.5)))
    }

    /// The mean of I and of Q, in the same units as the samples minus 127.5.
    public var dcOffset: (i: Double, q: Double) {
        guard sampleCount > 0 else { return (0, 0) }
        return (Double(sumI) / 2 / Double(sampleCount), Double(sumQ) / 2 / Double(sampleCount))
    }
}
