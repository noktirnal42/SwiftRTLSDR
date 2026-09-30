// SPDX-License-Identifier: GPL-2.0-or-later

/// Reed-Solomon over GF(2^8), shortened to `length` symbols with `parityCount` parity symbols, primitive element 2
/// and generator roots β^(firstRoot + i) with β = α^rootStep (UAT: step 1, first root 120; CCSDS, as Meteor-M LRPT
/// uses it in the conventional basis: step 11, first root 112).
///
/// Written for this package: syndromes, Berlekamp-Massey, Chien search, Forney. It is checked against Phil Karn's
/// decoder (the one dump978 uses) and against reedsolo's encoder. One deliberate difference: an error located in the
/// part of the full-length code that shortening removed means the word is not within reach of any codeword, and is
/// reported as uncorrectable (Karn's decoder ignores such a location and reports success).
public struct ReedSolomon: Sendable {
    public let length: Int
    public let parityCount: Int
    public let firstRoot: Int
    public let rootStep: Int
    public var dataCount: Int { length - parityCount }

    private let exp: [UInt8]           // α^i for i in 0..<510 (doubled to skip a modulo)
    private let log: [Int]             // log[x] for x in 1...255; log[0] unused
    private let generator: [UInt8]     // g(x), highest degree first, monic

    public init(length: Int, parityCount: Int, polynomial: Int = 0x187, firstRoot: Int = 120, rootStep: Int = 1) {
        precondition(length <= 255 && parityCount < length, "a shortened code of at most 255 symbols")
        self.length = length
        self.parityCount = parityCount
        self.firstRoot = firstRoot
        self.rootStep = rootStep
        var exp = [UInt8](repeating: 0, count: 510)
        var log = [Int](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            exp[i] = UInt8(x)
            log[x] = i
            x <<= 1
            if x & 0x100 != 0 { x ^= polynomial }
        }
        for i in 255..<510 { exp[i] = exp[i - 255] }
        self.exp = exp
        self.log = log

        // g(x) = Π (x - β^(firstRoot + i)); in GF(2^8), minus is plus.
        var g: [UInt8] = [1]
        for i in 0..<parityCount {
            let root = exp[((firstRoot + i) * rootStep) % 255]
            var next = [UInt8](repeating: 0, count: g.count + 1)
            for (j, coefficient) in g.enumerated() {
                next[j] ^= coefficient
                next[j + 1] ^= Self.multiply(coefficient, root, exp, log)
            }
            g = next
        }
        generator = g
    }

    private static func multiply(_ a: UInt8, _ b: UInt8, _ exp: [UInt8], _ log: [Int]) -> UInt8 {
        a == 0 || b == 0 ? 0 : exp[log[Int(a)] + log[Int(b)]]
    }
    private func mul(_ a: UInt8, _ b: UInt8) -> UInt8 { Self.multiply(a, b, exp, log) }
    private func div(_ a: UInt8, _ b: UInt8) -> UInt8 { a == 0 ? 0 : exp[(log[Int(a)] - log[Int(b)] + 255) % 255] }
    /// α^power for any integer power.
    private func alpha(_ power: Int) -> UInt8 { exp[((power % 255) + 255) % 255] }
    /// β^power, β = α^rootStep: the element the code's roots and locators are powers of.
    private func beta(_ power: Int) -> UInt8 { alpha((power % 255) * rootStep) }

    /// Parity symbols for `data` (`dataCount` symbols): the remainder of data(x)·x^parityCount divided by g(x).
    public func parity(for data: [UInt8]) -> [UInt8] {
        precondition(data.count == dataCount, "expected \(dataCount) data symbols")
        var remainder = [UInt8](repeating: 0, count: parityCount)
        for symbol in data {
            let feedback = symbol ^ remainder[0]
            remainder.removeFirst()
            remainder.append(0)
            if feedback != 0 {
                for i in 0..<parityCount { remainder[i] ^= mul(generator[i + 1], feedback) }
            }
        }
        return remainder
    }

    /// Corrects `codeword` (`length` symbols, data then parity) in place. Returns the number of symbols corrected, or
    /// nil if the errors are beyond repair (the word is then left as it was).
    public func correct(_ codeword: inout [UInt8]) -> Int? {
        precondition(codeword.count == length, "expected \(length) symbols")
        // Syndromes: the received polynomial (first symbol = highest degree) at each generator root.
        var syndromes = [UInt8](repeating: 0, count: parityCount)
        var clean = true
        for i in 0..<parityCount {
            let root = beta(firstRoot + i)
            var value: UInt8 = 0
            for symbol in codeword { value = mul(value, root) ^ symbol }
            syndromes[i] = value
            if value != 0 { clean = false }
        }
        if clean { return 0 }

        // Berlekamp-Massey: the shortest LFSR (error locator Λ, lowest degree first) that generates the syndromes.
        var locator: [UInt8] = [1]
        var previous: [UInt8] = [1]
        var errors = 0
        var shift = 1
        var lastDiscrepancy: UInt8 = 1
        for n in 0..<parityCount {
            var discrepancy = syndromes[n]
            for i in 1...max(1, errors) where i < locator.count { discrepancy ^= mul(locator[i], syndromes[n - i]) }
            if discrepancy == 0 {
                shift += 1
                continue
            }
            let scale = div(discrepancy, lastDiscrepancy)
            var updated = locator
            if updated.count < previous.count + shift { updated += [UInt8](repeating: 0, count: previous.count + shift - updated.count) }
            for (i, coefficient) in previous.enumerated() { updated[i + shift] ^= mul(scale, coefficient) }
            if 2 * errors <= n {
                previous = locator
                errors = n + 1 - errors
                lastDiscrepancy = discrepancy
                shift = 1
            } else {
                shift += 1
            }
            locator = updated
        }
        while locator.count > 1 && locator.last == 0 { locator.removeLast() }
        let degree = locator.count - 1
        guard degree == errors, degree > 0, 2 * degree <= parityCount else { return nil }

        // Chien search over the positions that exist: symbol j sits at degree (length - 1 - j), locator X = α^degree,
        // and it is in error when Λ(X^-1) = 0 (X = β^degree).
        var positions: [Int] = []
        for j in 0..<length {
            let inverse = beta(-(length - 1 - j))
            var value: UInt8 = 0
            for coefficient in locator.reversed() { value = mul(value, inverse) ^ coefficient }
            if value == 0 { positions.append(j) }
        }
        guard positions.count == degree else { return nil }

        // Forney: Ω(x) = S(x)Λ(x) mod x^parityCount, e = X^(1-firstRoot) Ω(X^-1) / Λ'(X^-1).
        var evaluator = [UInt8](repeating: 0, count: parityCount)
        for i in 0..<parityCount {
            for j in 0...min(i, degree) { evaluator[i] ^= mul(syndromes[i - j], locator[j]) }
        }
        var corrected = codeword
        for j in positions {
            let power = length - 1 - j
            let inverse = beta(-power)
            var omega: UInt8 = 0
            for coefficient in evaluator.reversed() { omega = mul(omega, inverse) ^ coefficient }
            // Formal derivative: only odd-degree terms survive, Λ'(x) = Σ Λ(2k+1) x^(2k).
            var derivative: UInt8 = 0
            var term: UInt8 = 1
            let inverseSquared = mul(inverse, inverse)
            for k in stride(from: 1, through: degree, by: 2) {
                derivative ^= mul(locator[k], term)
                term = mul(term, inverseSquared)
            }
            guard derivative != 0 else { return nil }
            let magnitude = mul(beta(power * (1 - firstRoot)), div(omega, derivative))
            corrected[j] ^= magnitude
        }
        // Belt and braces: the result must now be a codeword.
        for i in 0..<parityCount {
            let root = beta(firstRoot + i)
            var value: UInt8 = 0
            for symbol in corrected { value = mul(value, root) ^ symbol }
            guard value == 0 else { return nil }
        }
        codeword = corrected
        return degree
    }
}
