// SPDX-License-Identifier: GPL-2.0-or-later
//
// POCSAG, the pager code of ITU-R Recommendation M.584: 32-bit codewords (a (31,21) BCH code and a parity bit) in
// batches of eight frames, an address and function, and numeric or alphanumeric text. Written for this package from the
// recommendation's description of the code; multimon-ng (GPL-2.0-or-later) is the oracle, and its numeric table and
// character handling are checked against, not copied. See PROVENANCE.md.
import Foundation

public enum POCSAG {
    /// Bit rates a pager network uses.
    public static let baudRates = [512.0, 1200.0, 2400.0]
    /// The synchronisation codeword that starts every batch, and the idle codeword that fills the frames no one uses.
    public static let syncWord: UInt32 = 0x7CD2_15D8
    public static let idleWord: UInt32 = 0x7A89_C197
    /// Codewords in a batch: eight frames of two.
    public static let batchCodewords = 16
    /// The BCH code's generator polynomial, x^10 + x^9 + x^8 + x^6 + x^5 + x^3 + 1.
    static let generator: UInt32 = 0x769

    /// The ten check bits for 21 data bits (the remainder of the data times x^10 modulo the generator).
    static func checkBits(_ data21: UInt32) -> UInt32 {
        var remainder = data21 << 10
        for bit in stride(from: 30, through: 10, by: -1) where remainder >> UInt32(bit) & 1 == 1 {
            remainder ^= generator << UInt32(bit - 10)
        }
        return remainder & 0x3FF
    }

    /// A codeword from its 21 leading bits (the flag and 20 bits of address, function or text): check bits and even parity
    /// added.
    public static func codeword(data21: UInt32) -> UInt32 {
        var word = data21 << 11 | checkBits(data21) << 1
        word |= UInt32(word.nonzeroBitCount & 1)
        return word
    }

    /// An address codeword for `address` (21 bits) and `function` (2 bits); the frame is the address's low three bits.
    public static func addressWord(address: Int, function: Int) -> UInt32 {
        codeword(data21: UInt32(address >> 3 & 0x3FFFF) << 2 | UInt32(function & 3))
    }

    /// A message codeword carrying 20 bits.
    public static func messageWord(_ data20: UInt32) -> UInt32 { codeword(data21: 1 << 20 | data20 & 0xFFFFF) }

    static func isValid(_ word: UInt32) -> Bool {
        checkBits(word >> 11) == word >> 1 & 0x3FF && word.nonzeroBitCount & 1 == 0
    }

    /// The codeword with up to two wrong bits put right, and how many that took; nil if it needs more. The code's distance
    /// (6 with the parity bit) makes the nearest valid word unique within two bits.
    static func correct(_ word: UInt32) -> (word: UInt32, errors: Int)? {
        if isValid(word) { return (word, 0) }
        for a in 0..<32 {
            let one = word ^ 1 << UInt32(a)
            if isValid(one) { return (one, 1) }
        }
        for a in 0..<32 {
            for b in (a + 1)..<32 {
                let two = word ^ (1 << UInt32(a) | 1 << UInt32(b))
                if isValid(two) { return (two, 2) }
            }
        }
        return nil
    }

    /// The characters of the numeric format: four-bit digits sent least significant bit first.
    static let numericCharacters = Array("0123456789.U -][")
}

/// How the text of a message is read.
public enum POCSAGTextMode: String, Sendable, CaseIterable {
    /// Function 0 is numeric and the others alphanumeric, as the recommendation lays out the four addresses' use.
    case standard
    /// Whichever of the two reads more like text.
    case auto
    case numeric, alpha
}

/// One page.
public struct POCSAGMessage: Sendable, Equatable {
    /// The pager's address (a RIC): 21 bits.
    public var address: Int
    /// The two function bits (some networks use them to select the pager's alert or the text format).
    public var function: Int
    /// The text read as four-bit digits, and as seven-bit characters; a page has one real reading, which one depends on
    /// the network (`text(_:)` chooses).
    public var numeric: String
    public var alpha: String
    /// Message codewords that were put right, and those that could not be (a message with one is partial).
    public var correctedCodewords: Int
    public var damagedCodewords: Int
    /// Bits a second the page was sent at.
    public var baud: Double
    /// The signal's polarity was inverted (a receiver that tunes the other side of the channel does this).
    public var inverted: Bool

    /// The text as `mode` reads it.
    public func text(_ mode: POCSAGTextMode = .standard) -> String {
        switch mode {
        case .numeric: return numeric
        case .alpha: return alpha
        case .standard: return function == 0 ? numeric : alpha
        case .auto: return Self.alphaLooksLikeText(alpha) || !Self.numericLooksLikeNumbers(numeric) ? alpha : numeric
        }
    }

    private static func alphaLooksLikeText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let scalars = text.unicodeScalars
        let printable = scalars.filter { ($0.value >= 32 && $0.value < 127) || $0.value == 9 || $0.value == 10 || $0.value == 13 }.count
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        return printable == scalars.count && letters >= 3
    }

    private static func numericLooksLikeNumbers(_ text: String) -> Bool {
        !text.isEmpty && !text.contains("U") && text.filter { $0.isNumber }.count * 2 >= text.count
    }

    public var line: String { line(.standard) }

    public func line(_ mode: POCSAGTextMode) -> String {
        let flags = (correctedCodewords > 0 ? "  [\(correctedCodewords) corrected]" : "") + (damagedCodewords > 0 ? "  [\(damagedCodewords) damaged]" : "")
        return String(format: "POCSAG%.0f: Address: %7d  Function: %d  %@: %@", baud, address, function,
                      mode == .numeric || (mode == .standard && function == 0) ? "Numeric" : "Alpha", text(mode)) + flags
    }

    /// One JSON object, the fields multimon-ng's `--json` has plus what this decoder knows.
    public func json(_ mode: POCSAGTextMode = .standard) -> String {
        func quote(_ s: String) -> String {
            var out = "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default: out += scalar.value < 32 || scalar.value == 127 ? String(format: "\\u%04x", scalar.value) : String(scalar)
                }
            }
            return out + "\""
        }
        let kind = mode == .numeric || (mode == .standard && function == 0) ? "numeric" : "alpha"
        return "{\"demod_name\": \"POCSAG\(Int(baud))\", \"address\": \(address), \"function\": \(function), \"\(kind)\": \(quote(text(mode)))"
            + ", \"corrected\": \(correctedCodewords), \"damaged\": \(damagedCodewords)}"
    }
}

/// Finds pages in a stream of bits (as sent: the first bit of a codeword first, a 1 for the lower frequency).
///
/// A shift register looks for the synchronisation codeword (up to two wrong bits, either polarity); after it come
/// sixteen codewords and, if the transmission goes on, the next synchronisation codeword. An address codeword starts a
/// page, message codewords add 20 bits each, and an address, an idle codeword or the end of the batch ends it. The
/// address's low three bits are the frame the codeword is in.
public final class POCSAGDecoder {
    public let baud: Double
    /// Pages with a codeword beyond repair are returned too, marked.
    public var reportsPartialPages = false
    /// Codewords the decoder put right, and those it could not (inside and outside pages).
    public private(set) var correctedTotal = 0, damagedTotal = 0

    private var register: UInt32 = 0
    private var bitsInRegister = 0
    private enum State { case searching, batch(index: Int) }
    private var state = State.searching
    private var inverted = false
    private var wordBits = 0
    private var pending: (address: Int, function: Int, bits: [UInt8], corrected: Int, damaged: Int)?

    public init(baud: Double) { self.baud = baud }

    /// Feeds bits; returns the pages a bit completed.
    public func process(bits: [UInt8]) -> [POCSAGMessage] {
        var pages: [POCSAGMessage] = []
        for bit in bits {
            register = register << 1 | UInt32(bit & 1)
            bitsInRegister = min(bitsInRegister + 1, 32)
            switch state {
            case .searching:
                guard bitsInRegister == 32 else { continue }
                if (register ^ POCSAG.syncWord).nonzeroBitCount <= 2 {
                    inverted = false
                } else if (~register ^ POCSAG.syncWord).nonzeroBitCount <= 2 {
                    inverted = true
                } else { continue }
                state = .batch(index: 0)
                wordBits = 0
            case .batch(let index):
                wordBits += 1
                guard wordBits == 32 else { continue }
                wordBits = 0
                let word = inverted ? ~register : register
                if index == POCSAG.batchCodewords {
                    // After the sixteenth codeword comes the next batch's synchronisation codeword, or the transmission has ended.
                    if (word ^ POCSAG.syncWord).nonzeroBitCount <= 3 {
                        state = .batch(index: 0)
                    } else {
                        if let page = finish(complete: true) { pages.append(page) }
                        state = .searching
                        bitsInRegister = 0
                        // The bits of this word may be the start of a synchronisation codeword (back to back transmissions).
                    }
                    continue
                }
                if let page = handle(word, frame: index / 2) { pages.append(page) }
                state = .batch(index: index + 1)
            }
        }
        return pages
    }

    private func handle(_ received: UInt32, frame: Int) -> POCSAGMessage? {
        guard let (word, errors) = POCSAG.correct(received) else {
            damagedTotal += 1
            // Either an address or text: a page being read cannot be trusted past it.
            if pending != nil { pending!.damaged += 1; pending!.bits += [UInt8](repeating: 0, count: 20) }
            return nil
        }
        correctedTotal += errors > 0 ? 1 : 0
        if word == POCSAG.idleWord { return finish(complete: true) }
        if word >> 31 == 0 {
            let page = finish(complete: true)
            pending = (address: Int(word >> 13 & 0x3FFFF) << 3 | frame, function: Int(word >> 11 & 3), bits: [], corrected: errors > 0 ? 1 : 0, damaged: 0)
            return page
        }
        guard pending != nil else { return nil }                     // text without an address: the start was missed
        if errors > 0 { pending!.corrected += 1 }
        for k in stride(from: 30, through: 11, by: -1) { pending!.bits.append(UInt8(word >> UInt32(k) & 1)) }
        return nil
    }

    private func finish(complete: Bool) -> POCSAGMessage? {
        defer { pending = nil }
        guard let page = pending else { return nil }
        if page.damaged > 0 && !reportsPartialPages { return nil }
        // Numeric: four-bit groups, least significant bit first. Alphanumeric: seven-bit characters, least significant bit first.
        var numeric = "", alpha = ""
        var k = 0
        while k + 4 <= page.bits.count {
            var value = 0
            for j in 0..<4 { value |= Int(page.bits[k + j]) << j }
            numeric.append(POCSAG.numericCharacters[value])
            k += 4
        }
        k = 0
        while k + 7 <= page.bits.count {
            var value: UInt32 = 0
            for j in 0..<7 { value |= UInt32(page.bits[k + j]) << UInt32(j) }
            alpha.unicodeScalars.append(Unicode.Scalar(value)!)
            k += 7
        }
        // The last codeword's unused bits come out as filler: the end of an alphanumeric text is sent as an EOT or NULs,
        // which are dropped (a numeric text is kept as it is: its zeros are digits).
        while alpha.unicodeScalars.last.map({ $0.value == 0 || $0.value == 4 }) == true { alpha.unicodeScalars.removeLast() }
        return POCSAGMessage(address: page.address, function: page.function, numeric: numeric, alpha: alpha, correctedCodewords: page.corrected,
                             damagedCodewords: page.damaged, baud: baud, inverted: inverted)
    }
}
