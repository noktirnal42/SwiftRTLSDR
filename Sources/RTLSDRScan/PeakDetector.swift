// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A signal found in a spectrum.
public struct Detection: Sendable, Equatable {
    /// Frequency of the strongest bin, in Hz.
    public var frequencyHz: Double
    /// Power of the strongest bin, dB relative to a full-scale tone.
    public var powerDB: Double
    /// The local noise floor under it, same units.
    public var noiseFloorDB: Double
    /// Width of the run of bins above the threshold, in Hz.
    public var bandwidthHz: Double

    public var snrDB: Double { powerDB - noiseFloorDB }

    public init(frequencyHz: Double, powerDB: Double, noiseFloorDB: Double, bandwidthHz: Double) {
        self.frequencyHz = frequencyHz
        self.powerDB = powerDB
        self.noiseFloorDB = noiseFloorDB
        self.bandwidthHz = bandwidthHz
    }
}

/// Finds signals that stand above the local noise floor.
///
/// The floor is the median of the spectrum in windows of `floorWindowHz`, interpolated between window centres, so a
/// floor that slopes across a wide sweep does not hide signals or invent them. Runs of bins more than `thresholdDB`
/// above it become detections; detections closer than `minimumSeparationHz` merge into the stronger one.
public struct PeakDetector: Sendable, Equatable {
    public var thresholdDB: Double
    public var floorWindowHz: Double
    public var minimumSeparationHz: Double

    public init(thresholdDB: Double = 10, floorWindowHz: Double = 500_000, minimumSeparationHz: Double = 20_000) {
        self.thresholdDB = thresholdDB
        self.floorWindowHz = floorWindowHz
        self.minimumSeparationHz = minimumSeparationHz
    }

    /// The estimated noise floor at every bin (NaN where the spectrum has no data).
    public func noiseFloor(of spectrum: Spectrum) -> [Double] {
        let powers = spectrum.powerDB
        guard !powers.isEmpty else { return [] }
        let window = max(16, Int(floorWindowHz / spectrum.binWidthHz))
        // Median of each window, placed at the window's centre.
        var anchors: [(position: Double, level: Double)] = []
        var start = 0
        while start < powers.count {
            let end = min(powers.count, start + window)
            let values = powers[start..<end].filter { !$0.isNaN }.sorted()
            if !values.isEmpty {
                let median = values.count % 2 == 1 ? values[values.count / 2] : (values[values.count / 2 - 1] + values[values.count / 2]) / 2
                anchors.append((Double(start + end - 1) / 2, median))
            }
            start = end
        }
        guard !anchors.isEmpty else { return powers }
        var floor = [Double](repeating: 0, count: powers.count)
        var next = 0
        for bin in powers.indices {
            let position = Double(bin)
            while next < anchors.count && anchors[next].position < position { next += 1 }
            if next == 0 {
                floor[bin] = anchors[0].level
            } else if next == anchors.count {
                floor[bin] = anchors[anchors.count - 1].level
            } else {
                let a = anchors[next - 1], b = anchors[next]
                floor[bin] = a.level + (b.level - a.level) * (position - a.position) / (b.position - a.position)
            }
            if powers[bin].isNaN { floor[bin] = .nan }
        }
        return floor
    }

    /// Detections in frequency order.
    public func detect(in spectrum: Spectrum) -> [Detection] {
        let powers = spectrum.powerDB
        let floor = noiseFloor(of: spectrum)
        var found: [Detection] = []
        var bin = 0
        while bin < powers.count {
            guard !powers[bin].isNaN, powers[bin] > floor[bin] + thresholdDB else { bin += 1; continue }
            var strongest = bin
            var end = bin
            while end + 1 < powers.count, !powers[end + 1].isNaN, powers[end + 1] > floor[end + 1] + thresholdDB {
                end += 1
                if powers[end] > powers[strongest] { strongest = end }
            }
            found.append(Detection(frequencyHz: spectrum.frequency(ofBin: strongest), powerDB: powers[strongest],
                                   noiseFloorDB: floor[strongest], bandwidthHz: Double(end - bin + 1) * spectrum.binWidthHz))
            bin = end + 1
        }
        return merged(found, binWidth: spectrum.binWidthHz)
    }

    private func merged(_ detections: [Detection], binWidth: Double) -> [Detection] {
        var result: [Detection] = []
        for detection in detections {
            guard let last = result.last, detection.frequencyHz - last.frequencyHz < minimumSeparationHz else {
                result.append(detection)
                continue
            }
            // Keep the stronger peak; the bandwidth spans both runs.
            let lowEdge = min(last.frequencyHz - last.bandwidthHz / 2, detection.frequencyHz - detection.bandwidthHz / 2)
            let highEdge = max(last.frequencyHz + last.bandwidthHz / 2, detection.frequencyHz + detection.bandwidthHz / 2)
            var keep = detection.powerDB > last.powerDB ? detection : last
            keep.bandwidthHz = max(binWidth, highEdge - lowEdge)
            result[result.count - 1] = keep
        }
        return result
    }
}
