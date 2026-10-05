// SPDX-License-Identifier: GPL-2.0-or-later
//
// A sample stream with running sums, for reading FSK symbols at fractional positions. Written for this package.
import Foundation

/// What a frame synchroniser is given: a discriminator's frequency (to be integrated over each symbol), or the front
/// end's tone statistic (a symbol's worth already; its place is the sample where it ends).
public enum SymbolInput: Sendable { case frequency, tones }

/// Samples as they arrive, with a prefix sum, so that the integral over any stretch (whole or fractional samples) costs
/// two lookups. In `.tones` mode a second stream, the discriminator's frequency, comes along for the carrier offset.
struct SymbolBuffer {
    let input: SymbolInput
    let samplesPerSymbol: Double
    private(set) var count = 0
    /// Stream index of sample 0 of the buffer.
    private(set) var base = 0
    private var samples: [Float] = []
    private var prefix: [Double] = [0]              // prefix[n] = Σ samples[0 ..< n]
    private var frequencies: [Float] = []
    private var frequencyPrefix: [Double] = [0]

    init(input: SymbolInput, samplesPerSymbol: Double) {
        self.input = input
        self.samplesPerSymbol = samplesPerSymbol
    }

    mutating func append(_ values: [Float], frequency: [Float]?) {
        samples.reserveCapacity(samples.count + values.count)
        prefix.reserveCapacity(prefix.count + values.count)
        var running = prefix[prefix.count - 1]
        for value in values {
            samples.append(value)
            running += Double(value)
            prefix.append(running)
        }
        count = samples.count
        if input == .tones, let frequency {
            precondition(frequency.count == values.count)
            var total = frequencyPrefix[frequencyPrefix.count - 1]
            for value in frequency {
                frequencies.append(value)
                total += Double(value)
                frequencyPrefix.append(total)
            }
        }
    }

    /// Σ of the samples over [x0, x1), for fractional positions (the samples taken as steps).
    @inline(__always)
    func integral(_ x: Double) -> Double {
        let whole = Int(x)
        return prefix[whole] + (x - Double(whole)) * Double(samples[min(whole, samples.count - 1)])
    }

    @inline(__always)
    private func frequencyIntegral(_ x: Double) -> Double {
        let whole = Int(x)
        return frequencyPrefix[whole] + (x - Double(whole)) * Double(frequencies[min(whole, frequencies.count - 1)])
    }

    /// The symbol that starts at `start`: the integral over its period of the frequency, or the statistic of the
    /// window that ends with its last sample, between two samples.
    @inline(__always)
    func symbol(_ start: Double, period: Double? = nil) -> Double {
        let length = period ?? samplesPerSymbol
        guard input == .tones else { return integral(start + length) - integral(start) }
        let x = start + length - 1
        let whole = Int(x), fraction = x - Double(whole)
        return Double(samples[whole]) * (1 - fraction) + Double(samples[min(whole + 1, samples.count - 1)]) * fraction
    }

    /// The mean frequency over [start, end): the carrier offset, if the stream is a frequency in hertz.
    func meanFrequency(from start: Double, to end: Double) -> Double {
        if input == .tones { return (frequencyIntegral(end) - frequencyIntegral(start)) / (end - start) }
        return (integral(end) - integral(start)) / (end - start)
    }

    /// Pearson correlation of `pattern` (±1) with the symbols from `start` on, `symbolsPerPatternEntry` apart.
    func correlation(of pattern: [Double], at start: Double, symbols count: Int? = nil) -> Double {
        let n = count ?? pattern.count
        var sum = 0.0, sumSquares = 0.0, cross = 0.0, sumH = 0.0
        for k in 0..<n {
            let v = symbol(start + Double(k) * samplesPerSymbol), h = pattern[k]
            sum += v; sumSquares += v * v; cross += v * h; sumH += h
        }
        let m = Double(n)
        let spread = sumSquares - sum * sum / m, spreadH = m - sumH * sumH / m
        guard spread > 0, spreadH > 0 else { return 0 }
        return (cross - sum * sumH / m) / (spread * spreadH).squareRoot()
    }

    /// Drops what lies before `index` (less a margin), in large steps so that shifting the buffers stays cheap.
    /// Returns how many samples went; positions in the buffer then fall by that much.
    mutating func trim(before index: Double) -> Int {
        let drop = Int(index) - 16
        guard drop > 100_000 else { return 0 }
        samples.removeFirst(drop)
        let offset = prefix[drop]
        prefix.removeFirst(drop)
        for k in prefix.indices { prefix[k] -= offset }
        if input == .tones {
            frequencies.removeFirst(drop)
            let frequencyOffset = frequencyPrefix[drop]
            frequencyPrefix.removeFirst(drop)
            for k in frequencyPrefix.indices { frequencyPrefix[k] -= frequencyOffset }
        }
        base += drop
        count = samples.count
        return drop
    }
}
