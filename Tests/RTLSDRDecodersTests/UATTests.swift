// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

func resourceText(_ name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Resources") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try String(contentsOf: url, encoding: .utf8)
}

/// The real frames shipped with dump978.
func sampleFrames() throws -> [UATFrame] {
    try resourceText("dump978-sample-data").split(separator: "\n").compactMap { UATFrame(dump978Line: $0) }
}

struct ReedSolomonTests {
    private func rows() throws -> [[String]] { try resourceLines("uat-reed-solomon-vectors") }

    @Test func parityMatchesAnIndependentEncoder() throws {
        for row in try rows() {
            let code = ReedSolomon(length: Int(row[0])!, parityCount: Int(row[1])!)
            let clean = bytes(hex: row[2])
            #expect(Array(clean.prefix(code.dataCount)) + code.parity(for: Array(clean.prefix(code.dataCount))) == clean)
        }
    }

    @Test func correctableWordsAreRepairedExactlyAsKarnsDecoderDoes() throws {
        var checked = 0
        for row in try rows() {
            let code = ReedSolomon(length: Int(row[0])!, parityCount: Int(row[1])!)
            let injected = Int(row[4])!, karn = Int(row[5])!
            guard 2 * injected <= code.parityCount else { continue }
            var word = bytes(hex: row[3])
            #expect(code.correct(&word) == karn, "\(row[0])-byte word with \(injected) errors")
            #expect(word == bytes(hex: row[6]) && word == bytes(hex: row[2]))
            checked += 1
        }
        #expect(checked == 135)
    }

    @Test func wordsBeyondRepairAreRefusedAndLeftAlone() throws {
        var refused = 0
        for row in try rows() {
            let code = ReedSolomon(length: Int(row[0])!, parityCount: Int(row[1])!)
            guard 2 * Int(row[4])! > code.parityCount else { continue }
            var word = bytes(hex: row[3])
            if code.correct(&word) == nil {
                refused += 1
                #expect(word == bytes(hex: row[3]))
            } else {
                // Rarely a heavily damaged word lands near another codeword: then it must at least be one.
                #expect(code.correct(&word) == 0)
            }
            #expect(Int(row[5])! == -1, "Karn's decoder refused all of these too")
        }
        #expect(refused >= 40)
    }

    @Test func uplinkFramesRoundTripThroughTheInterleaver() throws {
        let payload = (0..<UAT.uplinkPayloadBytes).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
        var sent = UAT.encode(payload, kind: .uplink)
        #expect(sent.count == 552)
        for position in stride(from: 3, to: 552, by: 61) { sent[position] ^= 0x5a }      // 9 bytes spread over the six blocks
        let received = try #require(UAT.correctUplink(sent))
        #expect(received.payload == payload && received.corrected == 9)
    }

    @Test func downlinkFramesPickTheirOwnLength() throws {
        let basic = [UInt8](repeating: 0, count: 1) + (1..<18).map { UInt8($0) }         // payload type 0: basic
        var sentBasic = UAT.encode(basic, kind: .downlink) + [UInt8](repeating: 0x55, count: 18)
        sentBasic[5] ^= 0xff
        #expect(UAT.correctDownlink(sentBasic)?.payload == basic)
        let long = [UInt8(0x08)] + (1..<34).map { UInt8($0) }                          // payload type 1: long
        var sentLong = UAT.encode(long, kind: .downlink)
        sentLong[40] ^= 0x01
        #expect(UAT.correctDownlink(sentLong).map { ($0.payload, $0.corrected) } ?? ([], 0) == (long, 1))
    }
}

/// Formats decoded frames exactly as Tools/uat-oracle-fields.c prints dump978's decoding of them.
enum OracleFormat {
    static func line(_ m: UATADSBMessage) -> String {
        var text = String(format: "D type=%d aq=%d addr=%06X", m.payloadType, m.addressQualifier.rawValue, m.address)
        if let v = m.stateVector {
            text += " nic=\(v.nic)"
            if let lat = v.latitude, let lon = v.longitude { text += String(format: " lat=%.6f lon=%.6f", lat, lon) }
            if let alt = v.altitude { text += " alt=\(alt.feet)/\(alt.type.rawValue)" }
            text += " ag=\(v.airGround.rawValue)"
            if let ns = v.northVelocity { text += " ns=\(ns)" }
            if let ew = v.eastVelocity { text += " ew=\(ew)" }
            if let track = v.track { text += " track=\(track.degrees)/\(track.type.rawValue)" }
            if let speed = v.speedKnots { text += " speed=\(speed)" }
            if let rate = v.verticalRate { text += " vr=\(rate.feetPerMinute)/\(rate.source.rawValue)" }
            text += " utc=\(v.utcCoupled ? 1 : 0) site=\(v.tisbSiteID)"
        }
        if let s = m.modeStatus {
            let type = s.callsign == nil ? 0 : s.callsignIsSquawk ? 2 : 1
            let caps = [s.hasCDTI, s.hasACAS, s.acasResolutionActive, s.identActive, s.atcServices].map { $0 ? "1" : "0" }.joined()
            text += " cat=\(s.emitterCategory) cs=\(type):\(s.callsign ?? "") emerg=\(s.emergency) ver=\(s.uatVersion) sil=\(s.sil)"
                + " nacp=\(s.nacP) nacv=\(s.nacV) nicbaro=\(s.nicBaro) caps=\(caps)\(s.headingIsMagnetic ? 1 : 2)"
        }
        if let alt = m.secondaryAltitude { text += " alt2=\(alt.feet)/\(alt.type.rawValue)" }
        return text
    }

    static func lines(_ u: UATUplinkMessage) -> [String] {
        var lines = [String(format: "U lat=%.6f lon=%.6f", u.latitude, u.longitude)
            + " pos=\(u.positionValid ? 1 : 0) utc=\(u.utcCoupled ? 1 : 0) app=\(u.informationFrames == nil ? 0 : 1) slot=\(u.slotID)"
            + " site=\(u.tisbSiteID) frames=\(u.informationFrames?.count ?? 0)"]
        for frame in u.informationFrames ?? [] {
            var text = " I len=\(frame.data.count) type=\(frame.type)"
            if let f = frame.fisb {
                text += " product=\(f.productID) flags=" + [f.flags.a, f.flags.g, f.flags.p, f.flags.s].map { $0 ? "1" : "0" }.joined() + " time="
                if let month = f.month, let day = f.day { text += "\(month)/\(day)-" }
                text += String(format: "%02d:%02d", f.hours, f.minutes)
                if let seconds = f.seconds { text += String(format: ":%02d", seconds) }
                text += " payload=\(f.payload.count)"
                if let dlac = f.dlacText { text += " text=" + dlac.unicodeScalars.map { String(format: "%02x", $0.value) }.joined() }
            }
            lines.append(text)
        }
        return lines
    }
}

struct UATMessageTests {
    @Test func theSampleFramesParse() throws {
        let frames = try sampleFrames()
        #expect(frames.count == 1143)
        #expect(frames.filter { $0.kind == .downlink }.count == 439)
    }

    @Test func everySampleFrameDecodesExactlyAsDump978DecodesIt() throws {
        var ours: [String] = []
        for frame in try sampleFrames() {
            switch frame.kind {
            case .downlink: ours.append(OracleFormat.line(UATADSBMessage(payload: frame.payload)))
            case .uplink: ours += OracleFormat.lines(UATUplinkMessage(payload: frame.payload))
            }
        }
        // dump978 reads the aircraft length from the wrong bits; that one field is checked separately below.
        let reference = try resourceText("dump978-sample-fields").split(separator: "\n").map {
            $0.replacingOccurrences(of: #" dim=[0-9.]+x[0-9.]+"#, with: "", options: .regularExpression)
        }
        #expect(ours.count == reference.count)
        var mismatches = 0
        for (mine, theirs) in zip(ours, reference) where mine != theirs {
            mismatches += 1
            if mismatches <= 5 { Issue.record("ours:   \(mine)\ndump978: \(theirs)") }
        }
        #expect(mismatches == 0)
    }

    @Test func aircraftSizeFollowsTheDO282BTable() {
        // On the ground (air/ground state 2), size code 0x6 in byte 15 bits 6-3: 45 m long, 39.5 m wide.
        var payload = [UInt8](repeating: 0, count: 18)
        payload[12] = 0x80
        payload[15] = 0x6 << 3
        let vector = UATADSBMessage(payload: payload).stateVector
        #expect(vector?.dimensions?.length == 45 && vector?.dimensions?.width == 39.5)
        payload[15] = 0
        #expect(UATADSBMessage(payload: payload).stateVector?.dimensions == nil, "code 0: no data")
    }

    @Test func weatherTextReadsAsText() throws {
        let products = try sampleFrames().filter { $0.kind == .uplink }
            .flatMap { UATUplinkMessage(payload: $0.payload).informationFrames ?? [] }
            .compactMap(\.fisb).filter { $0.productID == 413 }
        #expect(products.count == 224)
        let reports = products.flatMap(\.reports)
        #expect(reports.contains { $0.hasPrefix("METAR ") } && reports.contains { $0.hasPrefix("TAF ") })
        #expect(reports.contains { $0.hasPrefix("WINDS BCE 250000Z") })
    }
}

struct NEXRADTests {
    @Test func blocksMatchExtractNexradLineForLine() throws {
        var ours: [String] = []
        for frame in try sampleFrames() where frame.kind == .uplink {
            for product in (UATUplinkMessage(payload: frame.payload).informationFrames ?? []).compactMap(\.fisb) {
                ours += NEXRADBlock.blocks(in: product).map(\.extractNexradLine)
            }
        }
        let reference = try resourceText("dump978-sample-nexrad").split(separator: "\n").map(String.init)
        #expect(ours.count == 720 && reference.count == 720)
        #expect(ours == reference)
    }

    @Test func blockGeometry() {
        func header(_ number: Int, south: Bool = false, scale: Int = 0) -> FISBProduct {
            let first = UInt8(0x80 | (south ? 0x40 : 0) | scale << 4 | (number >> 16))
            // APDU header for product 63 (0x00 0xfc), hours:minutes option, 00:00.
            return FISBProduct([0x00, 0xfc, 0x00, 0x00, first, UInt8((number >> 8) & 0xff), UInt8(number & 0xff), 0xf8])!
        }
        let zero = NEXRADBlock.blocks(in: header(0)).first!
        #expect((zero.northArcminutes, zero.westArcminutes, zero.heightArcminutes, zero.widthArcminutes) == (4, 0, 4, 48))
        #expect(zero.bins == [UInt8](repeating: 0, count: 32), "one run of 32 zeros")
        let southern = NEXRADBlock.blocks(in: header(451, south: true)).first!
        #expect((southern.northArcminutes, southern.westArcminutes) == (-4, 48))
        let wide = NEXRADBlock.blocks(in: header(405_001)).first!
        #expect((wide.northArcminutes, wide.westArcminutes, wide.widthArcminutes) == (3604, 0, 96), "odd numbers above 60° round down")
        let coarse = NEXRADBlock.blocks(in: header(900, scale: 1)).first!
        #expect((coarse.heightArcminutes, coarse.widthArcminutes) == (20, 240))
    }

    @Test func aCompositeRendersToAPicture() throws {
        var composites: [String: NEXRADComposite] = [:]
        for frame in try sampleFrames() where frame.kind == .uplink {
            for product in (UATUplinkMessage(payload: frame.payload).informationFrames ?? []).compactMap(\.fisb) {
                for block in NEXRADBlock.blocks(in: product) {
                    let key = "\(block.product.rawValue) \(block.hours):\(block.minutes)"
                    composites[key, default: NEXRADComposite(product: block.product, hours: block.hours, minutes: block.minutes)].add(block)
                }
            }
        }
        let largest = try #require(composites.values.max { $0.blocks.count < $1.blocks.count })
        let bounds = try #require(largest.bounds)
        #expect(bounds.north > bounds.south && bounds.east > bounds.west)
        // The sample data comes from the San Francisco Bay Area: the mosaic should be around 37°N 122°W.
        #expect(abs(Double(bounds.north + bounds.south) / 120 - 37) < 5 && abs(Double(bounds.west + bounds.east) / 120 + 122) < 8)
        let image = try #require(largest.image())
        #expect(image.width > 0 && image.height > 0)
        let png = image.png
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        #expect(png.count > image.width * image.height * 3)
    }

    @Test func binsArePaintedWhereTheyBelongInTheirColours() throws {
        // A run-length block (block 0: 0°-0.8°E, 0°-4'N) whose first row is intensity 7 and the rest 3.
        let payload: [UInt8] = [0x80, 0x00, 0x00, UInt8(31 << 3 | 7), UInt8(31 << 3 | 3), UInt8(31 << 3 | 3), UInt8(31 << 3 | 3)]
        let product = try #require(FISBProduct([0x00, 0xfc, 0x00, 0x00] + payload))
        let block = try #require(NEXRADBlock.blocks(in: product).first)
        var composite = NEXRADComposite(product: .regional, hours: 0, minutes: 0)
        let accepted = composite.add(block)
        #expect(accepted)
        let image = try #require(composite.image())
        #expect(image.width == 32 && image.height == 4, "one pixel per bin at scale 0")
        #expect(image.pixel(0, 0) == NEXRADComposite.palette[7] && image.pixel(31, 0) == NEXRADComposite.palette[7])
        #expect(image.pixel(0, 1) == NEXRADComposite.palette[3] && image.pixel(31, 3) == NEXRADComposite.palette[3])
        // Blocks from another product or time are refused.
        var other = block
        other.minutes = 5
        let refused = !composite.add(other)
        #expect(refused)
    }

    @Test func pngChunksCarryValidChecksums() {
        var image = RGBImage(width: 3, height: 2)
        image.set(1, 1, (255, 0, 0))
        let png = image.png
        // IHDR: length 13, then "IHDR", 13 bytes, CRC over type + data.
        let ihdr = Array(png[12..<(12 + 4 + 13)])
        let crc = UInt32(png[29]) << 24 | UInt32(png[30]) << 16 | UInt32(png[31]) << 8 | UInt32(png[32])
        #expect(crc32(ihdr) == crc)
        #expect(crc32(Array("IEND".utf8)) == 0xae42_6082, "the well-known CRC of an empty IEND chunk")
    }
}
