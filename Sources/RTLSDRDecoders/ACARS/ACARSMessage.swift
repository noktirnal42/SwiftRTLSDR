// SPDX-License-Identifier: GPL-2.0-or-later
//
// ACARS (Aircraft Communications Addressing and Reporting System) as it is sent on VHF: characters of 7-bit ASCII
// with odd parity, least significant bit first; two SYN, SOH, a 12-character header (mode, aircraft registration, ack,
// label, block ID), STX, text, ETX or ETB, a 16-bit CRC and DEL. Written for this package from the format (ARINC 618 as
// publicly described); acarsdec by Thierry Leconte (LGPL-2.0) was read for the conventions its output uses and is the
// test oracle. See PROVENANCE.md.
import Foundation

/// One ACARS message (one block).
public struct ACARSMessage: Sendable, Equatable {
    public var mode: Character
    /// The aircraft registration with the padding dots removed (".N12345" → "N12345").
    public var registration: String
    /// The technical acknowledgement character, or nil for NAK.
    public var acknowledgement: Character?
    public var label: String
    /// nil for a block without one (a squitter's is still a character).
    public var blockID: Character
    /// Message number and flight ID: in downlinks (block ID 0-9) only.
    public var messageNumber: String?
    public var flightID: String?
    public var text: String
    /// ETB instead of ETX: more blocks of this message follow.
    public var moreBlocks: Bool
    /// Bits the CRC let this decoder repair.
    public var correctedBits: Int
    /// Characters whose parity failed as received (acarsdec's "error").
    public var parityErrors: Int

    /// From aircraft (block IDs 0-9) rather than from the ground.
    public var isDownlink: Bool { blockID.isASCII && blockID.isNumber }

    /// Parses the characters between SOH and the CRC (parity bits already removed), ETX or ETB last.
    init?(characters c: [UInt8], correctedBits: Int, parityErrors: Int = 0) {
        guard c.count >= 13 else { return nil }
        func ch(_ i: Int) -> Character { Character(UnicodeScalar(c[i])) }
        mode = ch(0)
        registration = String(c[1..<8].filter { $0 != 0x2e }.map { Character(UnicodeScalar($0)) })
        acknowledgement = c[8] == 0x15 ? nil : ch(8)
        label = String([ch(9), c[10] == 0x7f ? "d" : ch(10)])
        blockID = ch(11)
        moreBlocks = c[c.count - 1] == 0x17
        self.correctedBits = correctedBits
        self.parityErrors = parityErrors
        var body = c.count > 13 && c[12] == 0x02 ? Array(c[13..<(c.count - 1)]) : []
        if blockID.isASCII && blockID.isNumber {
            messageNumber = String(decoding: body.prefix(4), as: UTF8.self)
            body.removeFirst(min(4, body.count))
            flightID = String(decoding: body.prefix(6), as: UTF8.self)
            body.removeFirst(min(6, body.count))
        }
        text = String(decoding: body, as: UTF8.self)
    }

    /// A readable line: registration, flight, mode, label, message number, then the text.
    public var line: String {
        var parts = [registration.isEmpty ? "-" : registration]
        if let flightID, !flightID.isEmpty { parts.append(flightID) }
        parts.append("mode \(mode)")
        parts.append("label \(label)")
        parts.append("block \(blockID)")
        parts.append(acknowledgement.map { "ack \($0)" } ?? "nak")
        if let messageNumber, !messageNumber.isEmpty { parts.append("no \(messageNumber)") }
        var line = parts.joined(separator: "  ")
        if !text.isEmpty { line += "  " + text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ") }
        if moreBlocks { line += "  (more)" }
        return line
    }

    /// acarsdec's JSON fields (`-o 4`), with `extra` added (timestamp, channel, frequency, level).
    public func json(extra: [String: Any] = [:]) -> String {
        var object = extra
        object["error"] = parityErrors
        object["mode"] = String(mode)
        object["label"] = label
        object["block_id"] = String(blockID)
        if let acknowledgement { object["ack"] = String(acknowledgement) } else { object["ack"] = false }
        object["tail"] = registration
        if let flightID { object["flight"] = flightID }
        if let messageNumber { object["msgno"] = messageNumber }
        if !text.isEmpty { object["text"] = text }
        if moreBlocks { object["end"] = false }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

/// Bits to messages: finds SYN SYN SOH at any bit (in either polarity), collects the block, checks parity and the CRC,
/// and repairs what `correct` can: a bit in each of up to three characters whose parity fails, one in the CRC, or two in
/// one character.
public final class ACARSFrameDecoder {
    static let syn: UInt8 = 0x16, soh: UInt8 = 0x01, stx: UInt8 = 0x02
    static let etx: UInt8 = 0x83, etb: UInt8 = 0x97, del: UInt8 = 0x7f      // with their parity bits
    static let maximumLength = 240

    private enum State { case searching, secondSYN, start, text, crc }
    private var state = State.searching
    private var window: UInt8 = 0                  // the last 8 bits, the newest in bit 7 (characters come LSB first)
    private var count = 0                          // bits until the next character
    private var invert = false                     // the demodulator's polarity is reversed (found ~SYN)
    private var characters: [UInt8] = []
    private var crc: [UInt8] = []
    private var parityErrors = 0
    public private(set) var rejected = 0
    /// SOH sequences seen so far (each starts a block, good or bad).
    public private(set) var blocksStarted = 0

    public init() {}

    /// Feeds one bit (`true` for 1); returns a message when one completes.
    public func push(_ bit: Bool) -> ACARSMessage? {
        window = window >> 1 | ((bit != invert) ? 0x80 : 0)
        switch state {
        case .searching:
            // Either polarity: the demodulator cannot tell 1 from 0 until it sees a known character.
            if window == Self.syn || window == ~Self.syn {
                if window == ~Self.syn { invert.toggle(); window = Self.syn }
                state = .secondSYN
                count = 8
            }
            return nil
        default:
            break
        }
        count -= 1
        guard count == 0 else { return nil }
        count = 8
        let byte = window
        switch state {
        case .searching:
            return nil
        case .secondSYN:
            if byte == Self.syn { state = .start } else { reset() }
        case .start:
            if byte == Self.soh {
                blocksStarted += 1
                state = .text
                characters = []
                parityErrors = 0
            } else {
                reset()
            }
        case .text:
            characters.append(byte)
            if byte.nonzeroBitCount % 2 == 0 {
                parityErrors += 1
                if parityErrors > 4 { reject(); return nil }
            }
            if characters.count >= 13 && (byte == Self.etx || byte == Self.etb) {
                state = .crc
                crc = []
            } else if characters.count > Self.maximumLength {
                reject()
            }
        case .crc:
            crc.append(byte)
            if crc.count == 2 {
                let message = finish()
                reset()
                if message == nil { rejected += 1 }
                return message
            }
        }
        return nil
    }

    private func reset() {
        state = .searching
        invert = false
    }

    private func reject() {
        rejected += 1
        reset()
    }

    private func finish() -> ACARSMessage? {
        var block = characters + crc
        // The byte after the header is STX or ETX whatever the noise did to it (as acarsdec has it).
        if block[12] != Self.stx && block[12] != Self.etx && (block[12] ^ Self.stx).nonzeroBitCount <= 1 { block[12] = Self.stx }
        let parity = block.dropLast(2).filter { $0.nonzeroBitCount % 2 == 0 }.count
        guard let corrected = Self.correct(&block) else { return nil }
        let text = block.prefix(block.count - 2).map { $0 & 0x7f }
        return ACARSMessage(characters: Array(text), correctedBits: corrected, parityErrors: parity)
    }

    // MARK: CRC

    /// CRC-16/CCITT, reflected (polynomial 0x8408 LSB first), from 0: over the characters and the two CRC bytes (low
    /// byte first) it leaves 0.
    static func crc(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? crc >> 1 ^ 0x8408 : crc >> 1 }
        }
        return crc
    }

    /// What a single wrong bit `distance` bits before the end does to the check: the CRC of that bit alone.
    static let syndromes: [UInt16] = {
        var table = [UInt16](repeating: 0, count: (maximumLength + 4) * 8)
        var state: UInt16 = 0x8408                 // a one bit fed into an empty register
        for distance in table.indices {
            table[distance] = state
            state = state & 1 != 0 ? state >> 1 ^ 0x8408 : state >> 1
        }
        return table
    }()

    /// Repairs `block` (characters and CRC) in place if it can; returns the bits changed, or nil.
    ///
    /// A wrong bit in a character breaks its parity, so the characters whose parity fails say where to look: one bit in
    /// each of up to three of them, and perhaps one in the CRC; with no parity failure, one bit in the CRC or two in one
    /// character. A repair is taken only when exactly one pattern of that kind makes the CRC come out right: an ambiguous
    /// one is more likely wrong than right.
    static func correct(_ block: inout [UInt8]) -> Int? {
        let check = crc(block)
        let parity = Array(block.indices.dropLast(2).filter { block[$0].nonzeroBitCount % 2 == 0 })
        if check == 0 && parity.isEmpty { return 0 }
        guard parity.count <= 3 else { return nil }
        let count = block.count
        // Bits go in least significant first, so bit 7 of the last byte is the last bit fed.
        func syndrome(_ byte: Int, _ bit: Int) -> UInt16 { syndromes[(count - 1 - byte) * 8 + 7 - bit] }
        var crcBits: [UInt16: (Int, Int)] = [:]          // syndrome of each single CRC-byte bit
        for c in (count - 2)..<count { for b in 0..<8 { crcBits[syndrome(c, b)] = (c, b) } }

        var found: [[(Int, Int)]] = []
        func consider(_ flips: [(Int, Int)], _ rest: UInt16) {
            if rest == 0 { found.append(flips) } else if let extra = crcBits[rest] { found.append(flips + [extra]) }
        }
        if parity.isEmpty {
            // One bit in the CRC, or two in one character (its parity still holds).
            if let extra = crcBits[check] { found.append([extra]) }
            for byte in 0..<(count - 2) {
                for a in 0..<7 {
                    for b in (a + 1)..<8 where syndrome(byte, a) ^ syndrome(byte, b) == check { found.append([(byte, a), (byte, b)]) }
                }
            }
        } else {
            // One bit in each parity-failed character, and at most one in the CRC (not with three characters: 512
            // patterns are enough of a gamble).
            func walk(_ k: Int, _ flips: [(Int, Int)], _ rest: UInt16) {
                guard k < parity.count else {
                    if parity.count < 3 { consider(flips, rest) } else if rest == 0 { found.append(flips) }
                    return
                }
                for bit in 0..<8 { walk(k + 1, flips + [(parity[k], bit)], rest ^ syndrome(parity[k], bit)) }
            }
            walk(0, [], check)
        }
        guard found.count == 1 else { return nil }
        for (byte, bit) in found[0] { block[byte] ^= 1 << UInt8(bit) }
        return found[0].count
    }

    // MARK: Building frames (for tests and the oracle)

    /// A character with its odd-parity bit.
    static func withParity(_ c: UInt8) -> UInt8 { c & 0x7f | ((c & 0x7f).nonzeroBitCount % 2 == 0 ? 0x80 : 0) }

    /// The bytes of a block as transmitted: pre-key (ones), bit sync "+*", SYN SYN SOH, header, STX, text, ETX, CRC, DEL.
    public static func frame(mode: Character = "2", registration: String, acknowledgement: Character? = nil, label: String,
                             blockID: Character, messageNumber: String? = nil, flightID: String? = nil, text: String,
                             moreBlocks: Bool = false) -> [UInt8] {
        var header: [UInt8] = [UInt8(mode.asciiValue ?? 0x32)]
        let padded = String(repeating: ".", count: max(0, 7 - registration.count)) + registration
        header += Array(padded.utf8.prefix(7))
        header.append(acknowledgement?.asciiValue ?? 0x15)
        header += Array((label + "  ").utf8.prefix(2))
        header.append(blockID.asciiValue ?? 0x30)
        var body = Array((messageNumber ?? "").utf8) + Array((flightID ?? "").utf8) + Array(text.utf8)
        body = body.map { $0 & 0x7f }
        var characters = header.map(withParity)
        if !body.isEmpty { characters += [withParity(stx)] + body.map(withParity) }
        characters.append(moreBlocks ? etb : etx)
        let crc = Self.crc(characters)
        return [UInt8](repeating: 0xff, count: 16) + [withParity(0x2b), withParity(0x2a), syn, syn, soh]
            + characters + [UInt8(crc & 0xff), UInt8(crc >> 8), del]
    }
}
