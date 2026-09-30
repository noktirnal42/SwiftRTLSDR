// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Where to tune, hop by hop, to cover a frequency range, and which FFT bins of each hop to trust.
///
/// Each hop uses only the middle `usableFraction` of its bandwidth (the edges roll off in the filters) and ignores
/// the bins around DC, where the dongle's DC offset sits. With `coverDCHoles` (the default) hops are spaced half a
/// usable width apart, so every frequency is seen by two hops and each hop's DC hole is filled by a neighbour; without
/// it the hops are twice as far apart and a narrow gap stays at every hop's centre.
///
/// All hops share one bin grid: the step is a whole number of bins, so bins from neighbouring hops line up. Hops that
/// would fall outside `tunableRange` are pulled inside it by whole bins, so they stay on the grid.
public struct SweepPlan: Sendable, Equatable {
    public let range: ClosedRange<Int>
    public let sampleRate: Double
    public let fftSize: Int
    /// Tuning frequency of each hop, in order.
    public let centers: [Int]
    /// Where each hop's centre bin sits on the shared grid, counted from the lowest hop's centre.
    public let hopOffsetBins: [Int]
    /// Bins trusted on each side of a hop's centre bin.
    public let usableHalfBins: Int
    /// Bins on each side of the centre bin (and the centre bin itself) that are ignored.
    public let dcHalfBins: Int
    /// Distance between neighbouring hops, in bins (before any clamping into the tunable range).
    public let stepBins: Int
    /// Frequency of the lowest hop's centre bin, before rounding to whole hertz for tuning.
    private let originHz: Double

    public var binWidth: Double { sampleRate / Double(fftSize) }

    public init?(range: ClosedRange<Int>, sampleRate: Double, fftSize: Int,
                 usableFraction: Double = 0.75, dcExclusionHz: Double = 10_000, coverDCHoles: Bool = true,
                 tunableRange: ClosedRange<Int>? = nil) {
        guard sampleRate > 0, fftSize >= 16, fftSize & (fftSize - 1) == 0, usableFraction > 0, usableFraction <= 1 else { return nil }
        let binWidth = sampleRate / Double(fftSize)
        // The outermost bin (index 0) has no partner above DC, so the usable span stops one bin short of it.
        let usableHalf = min(fftSize / 2 - 1, Int(Double(fftSize) * usableFraction / 2))
        let dcHalf = max(0, Int((max(0, dcExclusionHz) / binWidth).rounded(.up)))
        // A hop must keep some usable bins beside its DC hole, and with overlapping hops the neighbour must reach past it.
        let step = coverDCHoles ? usableHalf : 2 * usableHalf + 1
        guard usableHalf > dcHalf, !coverDCHoles || step > 2 * dcHalf else { return nil }

        self.range = range
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        usableHalfBins = usableHalf
        dcHalfBins = dcHalf
        stepBins = step

        // With overlap the first hop sits at the bottom of the range (the half below it is discarded), so every
        // frequency in the range lies between two hop centres. Without, the first usable bin starts the range.
        let first = Double(range.lowerBound) + (coverDCHoles ? 0 : Double(usableHalf) * binWidth)
        var offsets: [Int] = []
        var hop = 0
        while true {
            let nominal = first + Double(hop * step) * binWidth
            var shift = 0
            if let tunableRange {
                if nominal > Double(tunableRange.upperBound) {
                    shift = -Int(((nominal - Double(tunableRange.upperBound)) / binWidth).rounded(.up))
                } else if nominal < Double(tunableRange.lowerBound) {
                    shift = Int(((Double(tunableRange.lowerBound) - nominal) / binWidth).rounded(.up))
                }
            }
            let offset = hop * step + shift
            if offsets.last != offset { offsets.append(offset) }       // clamping can land two hops on the same bin
            let covered = coverDCHoles ? nominal : nominal + Double(usableHalf) * binWidth
            if covered >= Double(range.upperBound) { break }
            hop += 1
        }
        let lowest = offsets.min()!
        let origin = first + Double(lowest) * binWidth
        originHz = origin
        hopOffsetBins = offsets.map { $0 - lowest }
        centers = hopOffsetBins.map { Int((origin + Double($0) * binWidth).rounded()) }
    }

    /// The spectrum grid: frequency of global bin 0, and the number of global bins the hops span.
    var gridStart: Double { originHz - Double(usableHalfBins) * binWidth }
    var gridCount: Int { hopOffsetBins.max()! + 2 * usableHalfBins + 1 }
}

/// Power across a frequency range, in dB relative to a full-scale tone, on a uniform grid.
public struct Spectrum: Sendable, Equatable {
    /// Frequency of bin 0, in Hz.
    public var startHz: Double
    public var binWidthHz: Double
    /// NaN where no hop contributed (only possible when a plan leaves DC holes uncovered).
    public var powerDB: [Double]

    public init(startHz: Double, binWidthHz: Double, powerDB: [Double]) {
        self.startHz = startHz
        self.binWidthHz = binWidthHz
        self.powerDB = powerDB
    }

    public func frequency(ofBin bin: Int) -> Double { startHz + Double(bin) * binWidthHz }

    /// The bin nearest `hertz`, if it is inside the spectrum.
    public func bin(nearest hertz: Double) -> Int? {
        let bin = Int(((hertz - startHz) / binWidthHz).rounded())
        return powerDB.indices.contains(bin) ? bin : nil
    }
}

/// Collects the hops of one sweep and stitches them into a `Spectrum` (overlapping bins are averaged in linear power).
public struct SpectrumStitcher: Sendable {
    public let plan: SweepPlan
    private var sum: [Double]
    private var count: [Int]

    public init(plan: SweepPlan) {
        self.plan = plan
        sum = [Double](repeating: 0, count: plan.gridCount)
        count = [Int](repeating: 0, count: plan.gridCount)
    }

    /// Adds hop `index`'s averaged power (from `SpectrumEstimator`, DC in the middle).
    public mutating func add(hop index: Int, power: [Double]) {
        precondition(plan.centers.indices.contains(index) && power.count == plan.fftSize, "hop and FFT size must match the plan")
        let middle = plan.fftSize / 2
        for offset in -plan.usableHalfBins...plan.usableHalfBins where abs(offset) > plan.dcHalfBins {
            let global = plan.hopOffsetBins[index] + offset + plan.usableHalfBins
            sum[global] += power[middle + offset]
            count[global] += 1
        }
    }

    /// The spectrum over the plan's range (bins outside it are dropped).
    public func spectrum() -> Spectrum {
        let binWidth = plan.binWidth
        let first = max(0, Int(((Double(plan.range.lowerBound) - plan.gridStart) / binWidth).rounded(.up)))
        let last = min(plan.gridCount - 1, Int(((Double(plan.range.upperBound) - plan.gridStart) / binWidth).rounded(.down)))
        guard first <= last else { return Spectrum(startHz: Double(plan.range.lowerBound), binWidthHz: binWidth, powerDB: []) }
        let powers = (first...last).map { bin in
            count[bin] == 0 ? Double.nan : 10 * log10(max(sum[bin] / Double(count[bin]), 1e-20))
        }
        return Spectrum(startHz: plan.gridStart + Double(first) * binWidth, binWidthHz: binWidth, powerDB: powers)
    }
}
