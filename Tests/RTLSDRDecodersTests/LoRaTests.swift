// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

/// gr-lora_sdr's transmit chain on random payloads (`Tools/generate-lora-vectors.py`).
private func loraVectors() throws -> [(p: LoRaParameters, payload: [UInt8], symbols: [Int])] {
    try resourceLines("lora-symbol-vectors").map { fields in
        let p = LoRaParameters(spreadingFactor: Int(fields[0])!, bandwidth: 125_000, codingRate: Int(fields[1])!, lowDataRate: fields[2] == "1")
        return (p, bytes(hex: fields[3]), fields.dropFirst(4).map { Int($0)! })
    }
}

struct LoRaCodingTests {
    @Test func whiteningIsTheSequenceGrLoraSdrUses() {
        #expect(Array(LoRaCoding.whitening.prefix(16)) == [0xff, 0xfe, 0xfc, 0xf8, 0xf0, 0xe1, 0xc2, 0x85, 0x0b, 0x17, 0x2f, 0x5e, 0xbc, 0x78, 0xf1, 0xe3])
        #expect(LoRaCoding.whitening.count == 255 && Set(LoRaCoding.whitening).count == 255)     // a maximal sequence
    }

    @Test func symbolsMatchGrLoraSdr() throws {
        let vectors = try loraVectors()
        #expect(vectors.count == 36)
        for vector in vectors {
            #expect(LoRaCoding.encode(vector.payload, vector.p) == vector.symbols,
                    "SF\(vector.p.spreadingFactor) CR\(vector.p.codingRate) LDRO \(vector.p.lowDataRate) \(vector.payload.count) bytes")
        }
    }

    @Test func framesDecodeWithTheirCRC() throws {
        for vector in try loraVectors() {
            let decoded = try #require(LoRaCoding.decode(vector.symbols, vector.p))
            #expect(decoded.payload == vector.payload && decoded.crcValid == true)
            #expect(8 + LoRaCoding.payloadSymbols(try #require(LoRaCoding.header(vector.symbols[...], vector.p)).0, vector.p) == vector.symbols.count)
        }
    }

    @Test func hammingCorrectsOneErrorAtFourSeventhsAndFourEighths() throws {
        for vector in try loraVectors() where vector.p.codingRate >= 3 && !vector.p.lowDataRate {
            // One bit wrong in each codeword: a symbol one bin off flips one bit of each (Gray mapping).
            var symbols = vector.symbols
            for index in stride(from: 8, to: symbols.count, by: 4 + vector.p.codingRate) {
                symbols[index] = (symbols[index] + 1) % vector.p.chips
            }
            let decoded = try #require(LoRaCoding.decode(symbols, vector.p))
            #expect(decoded.payload == vector.payload && decoded.crcValid == true, "SF\(vector.p.spreadingFactor) CR\(vector.p.codingRate)")
        }
    }

    @Test func aDamagedHeaderIsRefused() throws {
        let vector = try #require(try loraVectors().first)
        var symbols = vector.symbols
        symbols[0] = (symbols[0] + 40) % vector.p.chips
        symbols[1] = (symbols[1] + 17) % vector.p.chips
        #expect(LoRaCoding.header(symbols[...], vector.p) == nil)
    }
}
