// SPDX-License-Identifier: GPL-2.0-or-later
//
// UAT (978 MHz Universal Access Transceiver) framing and forward error correction.
// Frame sizes, sync words, code parameters and acceptance limits follow dump978 by Oliver Jowett
// (GPL-2.0-or-later; https://github.com/mutability/dump978, uat.h and fec.c). See PROVENANCE.md.
import Foundation

/// A UAT frame after error correction: payload bytes only (parity removed).
public struct UATFrame: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Aircraft ADS-B: basic (18 bytes) or long (34 bytes).
        case downlink
        /// Ground station broadcast (432 bytes): FIS-B weather and TIS-B.
        case uplink
    }
    public var kind: Kind
    public var payload: [UInt8]
    /// Symbols the Reed-Solomon code repaired.
    public var correctedSymbols: Int
    /// Index of the first sync sample in the stream, when demodulated.
    public var sampleIndex: Int?

    public init(kind: Kind, payload: [UInt8], correctedSymbols: Int = 0, sampleIndex: Int? = nil) {
        self.kind = kind
        self.payload = payload
        self.correctedSymbols = correctedSymbols
        self.sampleIndex = sampleIndex
    }

    /// dump978's text format: `-` (downlink) or `+` (uplink), the payload in hex, then `;` metadata.
    public var dump978Line: String {
        (kind == .downlink ? "-" : "+") + payload.map { hexDigits[Int($0)] }.joined() + (correctedSymbols > 0 ? ";rs=\(correctedSymbols);" : ";")
    }

    /// Parses one line of dump978 output (nil for anything else).
    public init?(dump978Line line: Substring) {
        guard let first = line.first, first == "-" || first == "+", let end = line.firstIndex(of: ";") else { return nil }
        let hex = line[line.index(after: line.startIndex)..<end]
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        let kind: Kind = first == "-" ? .downlink : .uplink
        let expected = kind == .uplink ? [UAT.uplinkPayloadBytes] : [UAT.basicPayloadBytes, UAT.longPayloadBytes]
        guard expected.contains(bytes.count) else { return nil }
        var repaired = 0
        if let rs = line[end...].range(of: "rs=") {
            repaired = Int(line[rs.upperBound...].prefix { $0.isNumber }) ?? 0
        }
        self.init(kind: kind, payload: bytes, correctedSymbols: repaired)
    }
}

private let hexDigits = (0..<256).map { String(format: "%02x", $0) }

public enum UAT {
    public static let sampleRate = 2_083_334           // two samples per bit at 1.041667 Mbit/s
    public static let frequency = 978_000_000

    static let syncBits = 36
    static let downlinkSync: UInt64 = 0xEACDDA4E2
    static let uplinkSync: UInt64 = 0x153225B1D        // the downlink sync word inverted

    public static let basicPayloadBytes = 18
    static let basicFrameBytes = 30                    // RS(30,18)
    public static let longPayloadBytes = 34
    static let longFrameBytes = 48                     // RS(48,34)
    static let uplinkBlocks = 6
    static let uplinkBlockPayloadBytes = 72
    static let uplinkBlockBytes = 92                   // RS(92,72), six blocks interleaved byte by byte
    public static let uplinkPayloadBytes = uplinkBlocks * uplinkBlockPayloadBytes       // 432
    static let uplinkFrameBytes = uplinkBlocks * uplinkBlockBytes                       // 552

    static let basicCode = ReedSolomon(length: basicFrameBytes, parityCount: 12)
    static let longCode = ReedSolomon(length: longFrameBytes, parityCount: 14)
    static let uplinkCode = ReedSolomon(length: uplinkBlockBytes, parityCount: 20)

    /// Corrects a downlink frame (the first 48 received bytes). A payload type of 0 in the first five bits means basic.
    /// Acceptance limits are dump978's: at most 7 repairs for long frames and 6 for basic ones.
    public static func correctDownlink(_ received: [UInt8]) -> (payload: [UInt8], corrected: Int)? {
        precondition(received.count >= longFrameBytes)
        var long = Array(received.prefix(longFrameBytes))
        if let fixed = longCode.correct(&long), fixed <= 7, long[0] >> 3 != 0 {
            return (Array(long.prefix(longPayloadBytes)), fixed)
        }
        var basic = Array(received.prefix(basicFrameBytes))
        if let fixed = basicCode.correct(&basic), fixed <= 6, basic[0] >> 3 == 0 {
            return (Array(basic.prefix(basicPayloadBytes)), fixed)
        }
        return nil
    }

    /// De-interleaves and corrects an uplink frame (552 received bytes): byte i of block b was sent at i*6 + b.
    public static func correctUplink(_ received: [UInt8]) -> (payload: [UInt8], corrected: Int)? {
        precondition(received.count >= uplinkFrameBytes)
        var payload: [UInt8] = []
        payload.reserveCapacity(uplinkPayloadBytes)
        var total = 0
        for block in 0..<uplinkBlocks {
            var codeword = (0..<uplinkBlockBytes).map { received[$0 * uplinkBlocks + block] }
            guard let fixed = uplinkCode.correct(&codeword), fixed <= 10 else { return nil }
            total += fixed
            payload += codeword.prefix(uplinkBlockPayloadBytes)
        }
        return (payload, total)
    }

    /// The bytes a transmitter sends for `payload`: with parity, and for uplinks interleaved (used by tests and by
    /// anything that wants to synthesise signals).
    public static func encode(_ payload: [UInt8], kind: UATFrame.Kind) -> [UInt8] {
        switch kind {
        case .downlink:
            let code = payload.count == basicPayloadBytes ? basicCode : longCode
            return payload + code.parity(for: payload)
        case .uplink:
            precondition(payload.count == uplinkPayloadBytes)
            var interleaved = [UInt8](repeating: 0, count: uplinkFrameBytes)
            for block in 0..<uplinkBlocks {
                let data = Array(payload[(block * uplinkBlockPayloadBytes)..<((block + 1) * uplinkBlockPayloadBytes)])
                let codeword = data + uplinkCode.parity(for: data)
                for (i, byte) in codeword.enumerated() { interleaved[i * uplinkBlocks + block] = byte }
            }
            return interleaved
        }
    }
}
