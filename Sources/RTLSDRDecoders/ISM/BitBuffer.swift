// SPDX-License-Identifier: GPL-2.0-or-later
//
// The two-dimensional bit buffer the ISM decoders read, ported from rtl_433's bitbuffer.c (Tommy Vestermark;
// GPL-2.0-or-later, release 25.02). Rows share one flat store exactly as there: a row longer than 1024 bits spills
// into the next row's space, and reading past a row's end sees whatever is stored there (zeros after a clear), which
// some decoders rely on. See PROVENANCE.md.

/// Rows of bits, as the pulse slicers produce them: one row per repeat of a message, with the number of sync pulses
/// seen before each row.
public struct BitBuffer: Sendable {
    public static let rowBytes = 128                // BITBUF_COLS
    public static let maximumRows = 50              // BITBUF_ROWS

    private(set) var storage = [UInt8](repeating: 0, count: maximumRows * rowBytes)
    public private(set) var bitsPerRow = [Int](repeating: 0, count: maximumRows)
    public private(set) var syncsBeforeRow = [Int](repeating: 0, count: maximumRows)
    public private(set) var rowCount = 0
    private var freeRow = 0

    public init() {}

    /// A buffer holding the given rows, for tests and for decoding hex codes.
    public init(rows: [(bytes: [UInt8], bits: Int)]) {
        for (index, row) in rows.enumerated() {
            if index > 0 { addRow() }
            for bit in 0..<row.bits { addBit(row.bytes[bit / 8] >> (7 - UInt8(bit % 8)) & 1) }
        }
    }

    /// Parses rtl_433's `-y` notation: rows of hex digits, each optionally preceded by `{bits}` (which truncates or
    /// pads the row to that many bits); `/` also starts a new row; spaces and `0x` are ignored.
    public init(code: String) {
        let characters = Array(code)
        var index = 0
        var width = -1
        while index < characters.count {
            let character = characters[index]
            if character == " " {
                index += 1
                continue
            }
            if character == "0" && index + 1 < characters.count && (characters[index + 1] == "x" || characters[index + 1] == "X") {
                index += 2
                continue
            }
            if character == "{" {
                if width >= 0 { setWidth(width) }
                if rowCount > 0 { addRow() }
                var digits = ""
                index += 1
                while index < characters.count, characters[index].isNumber { digits.append(characters[index]); index += 1 }
                while index < characters.count, characters[index].isWhitespace { index += 1 }
                width = min(Int(digits) ?? 0, Self.maximumRows * Self.rowBytes * 8)
                if index < characters.count && characters[index] == "}" { index += 1 }
                continue
            }
            if character == "/" {
                if width >= 0 { setWidth(width); width = -1 }
                addRow()
                index += 1
                continue
            }
            let nibble = UInt8(character.hexDigitValue ?? 0)
            for shift in [3, 2, 1, 0] { addBit(nibble >> UInt8(shift) & 1) }
            index += 1
        }
        if width >= 0 { setWidth(width) }
    }

    /// Sets the last row's length, padding with zeros or truncating (and clearing what is cut).
    private mutating func setWidth(_ requested: Int) {
        if rowCount == 0 { freeRow = 1; rowCount = 1 }
        let row = rowCount - 1
        let remaining = (Self.maximumRows - rowCount + 1) * Self.rowBytes * 8
        let width = min(requested, remaining)
        let base = row * Self.rowBytes
        if bitsPerRow[row] > width {
            let clearFrom = (width + 7) / 8, clearEnd = (bitsPerRow[row] + 7) / 8
            for index in clearFrom..<clearEnd { storage[base + index] = 0 }
            storage[base + width / 8] &= UInt8(truncatingIfNeeded: 0xff00 >> (width % 8))
        }
        bitsPerRow[row] = width
        freeRow = rowCount + (width == 0 ? 0 : (width - 1) / (Self.rowBytes * 8))
    }

    public mutating func clear() {
        for index in storage.indices { storage[index] = 0 }
        for index in 0..<Self.maximumRows { bitsPerRow[index] = 0; syncsBeforeRow[index] = 0 }
        rowCount = 0
        freeRow = 0
    }

    public mutating func addBit(_ bit: UInt8) {
        if rowCount == 0 { freeRow = 1; rowCount = 1 }
        let row = rowCount - 1
        let length = bitsPerRow[row]
        if length == Int(UInt16.max) { return }
        if length > 0 && length % (Self.rowBytes * 8) == 0 {
            // The row spills into the next row's space.
            if freeRow < Self.maximumRows { freeRow += 1 } else { return }
        }
        storage[row * Self.rowBytes + length / 8] |= (bit & 1) << (7 - UInt8(length % 8))
        bitsPerRow[row] = length + 1
    }

    public mutating func addRow() {
        if rowCount == 0 { freeRow = 1; rowCount = 1 }
        if freeRow < Self.maximumRows {
            freeRow += 1
            rowCount = freeRow
        } else {
            bitsPerRow[rowCount - 1] = 0               // out of rows: reuse the last one (its bytes are not cleared)
        }
    }

    public mutating func addSync() {
        if rowCount == 0 { freeRow = 1; rowCount = 1 }
        if bitsPerRow[rowCount - 1] > 0 { addRow() }
        syncsBeforeRow[rowCount - 1] += 1
    }

    /// Inverts every bit of every row (and only the row's bits).
    public mutating func invert() {
        for row in 0..<rowCount where bitsPerRow[row] > 0 {
            let base = row * Self.rowBytes
            let lastColumn = (bitsPerRow[row] - 1) / 8
            let lastBits = (bitsPerRow[row] - 1) % 8 + 1
            for column in 0...lastColumn { storage[base + column] = ~storage[base + column] }
            storage[base + lastColumn] ^= UInt8(0xff >> lastBits)
        }
    }

    /// The bytes of a row, read in place: index past the row reads the store (as rtl_433's decoders do).
    public func row(_ row: Int) -> BitRow { BitRow(storage: storage, base: row * Self.rowBytes) }

    /// Bit `index` of `row`.
    public func bit(row: Int, _ index: Int) -> UInt8 {
        let byte = row * Self.rowBytes + index >> 3
        return byte < storage.count ? storage[byte] >> (7 - UInt8(index & 7)) & 1 : 0
    }

    /// `count` bits of `row` from bit `position`, packed MSB first into ⌈count/8⌉ bytes (the unused low bits of the
    /// last byte are zero).
    public func extractBytes(row: Int, from position: Int, bits count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        let byteCount = (count + 7) / 8
        var out = [UInt8](repeating: 0, count: byteCount)
        let base = row * Self.rowBytes
        func at(_ index: Int) -> UInt8 { index < storage.count ? storage[index] : 0 }
        if position & 7 == 0 {
            for index in 0..<byteCount { out[index] = at(base + position / 8 + index) }
        } else {
            let shift = 8 - (position & 7)
            var byte = base + position >> 3
            var word = UInt16(at(byte))
            for index in 0..<byteCount {
                byte += 1
                word = word << 8 | UInt16(at(byte))
                out[index] = UInt8(truncatingIfNeeded: word >> UInt16(shift))
            }
        }
        if count & 7 != 0 { out[(count - 1) / 8] &= UInt8(truncatingIfNeeded: 0xff00 >> (count & 7)) }
        return out
    }

    /// The first position at or after `start` where `pattern` (its first `patternBits` bits) occurs in `row`, or the
    /// row's length if it does not.
    public func search(row: Int, from start: Int, pattern: [UInt8], bits patternBits: Int) -> Int {
        let length = bitsPerRow[row]
        var inputPosition = start
        var patternPosition = 0
        func patternBit(_ index: Int) -> UInt8 { pattern[index >> 3] >> (7 - UInt8(index & 7)) & 1 }
        while inputPosition < length && patternPosition < patternBits {
            if bit(row: row, inputPosition) == patternBit(patternPosition) {
                patternPosition += 1
                inputPosition += 1
                if patternPosition == patternBits { return inputPosition - patternBits }
            } else {
                inputPosition -= patternPosition
                inputPosition += 1
                patternPosition = 0
            }
        }
        return length
    }

    /// Manchester-decodes `row` from `start` (pairs 01 → 1, 10 → 0, i.e. the second bit of each pair) into
    /// `output`, stopping at the first invalid pair or after `maximum` bits (0: no limit). Returns the position
    /// reached.
    @discardableResult
    public func manchesterDecode(row: Int, from start: Int, into output: inout BitBuffer, maximum: Int = 0) -> Int {
        var length = bitsPerRow[row]
        var position = start
        if maximum > 0 && length > start + maximum * 2 { length = start + maximum * 2 }
        while position < length {
            let first = bit(row: row, position)
            let second = bit(row: row, position + 1)
            position += 2
            if first == second { break }
            output.addBit(second)
        }
        return position
    }

    public func compareRows(_ a: Int, _ b: Int, maximumBits: Int = 0) -> Bool {
        if maximumBits == 0 || bitsPerRow[a] < maximumBits || bitsPerRow[b] < maximumBits {
            guard bitsPerRow[a] == bitsPerRow[b] else { return false }
            let bytes = (bitsPerRow[a] + 7) / 8
            for index in 0..<bytes where storage[a * Self.rowBytes + index] != storage[b * Self.rowBytes + index] { return false }
            return true
        }
        let whole = maximumBits / 8
        for index in 0..<whole where storage[a * Self.rowBytes + index] != storage[b * Self.rowBytes + index] { return false }
        let last = (maximumBits - 1) / 8
        let mask = UInt8(truncatingIfNeeded: 0xff00 >> (maximumBits & 7))
        return storage[a * Self.rowBytes + last] & mask == storage[b * Self.rowBytes + last] & mask
    }

    public func countRepeats(of row: Int, maximumBits: Int = 0) -> Int {
        (0..<rowCount).filter { compareRows(row, $0, maximumBits: maximumBits) }.count
    }

    /// The first row of at least `minimumBits` that occurs at least `minimumRepeats` times, or nil.
    public func findRepeatedRow(minimumRepeats: Int, minimumBits: Int) -> Int? {
        (0..<rowCount).first { bitsPerRow[$0] >= minimumBits && countRepeats(of: $0) >= minimumRepeats }
    }

    /// As `findRepeatedRow`, comparing only the first `minimumBits` bits.
    public func findRepeatedPrefix(minimumRepeats: Int, minimumBits: Int) -> Int? {
        (0..<rowCount).first { bitsPerRow[$0] >= minimumBits && countRepeats(of: $0, maximumBits: minimumBits) >= minimumRepeats }
    }

    /// rtl_433's `{bits}hex` notation for each row, e.g. `{36}b5a8f0470`.
    public var codes: [String] {
        (0..<rowCount).map { row in
            let bytes = (bitsPerRow[row] + 7) / 8
            let rowView = self.row(row)
            return "{\(bitsPerRow[row])}" + (0..<bytes).map { hex2(rowView[$0]) }.joined()
        }
    }
}

/// Read-only view of a row's bytes. Reading past the store gives 0.
public struct BitRow: Sendable {
    let storage: [UInt8]
    let base: Int

    public subscript(index: Int) -> UInt8 {
        let position = base + index
        return position >= 0 && position < storage.count ? storage[position] : 0
    }

    /// The first `count` bytes as an array.
    public func bytes(_ count: Int) -> [UInt8] { (0..<count).map { self[$0] } }
}

func hex2(_ byte: UInt8) -> String {
    let digits: [Character] = Array("0123456789abcdef")
    return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]])
}
