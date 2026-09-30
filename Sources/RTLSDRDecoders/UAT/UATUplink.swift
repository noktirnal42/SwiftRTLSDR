// SPDX-License-Identifier: GPL-2.0-or-later
//
// UAT uplink and FIS-B APDU decoding, ported from uat_decode.c in dump978 by Oliver Jowett (GPL-2.0-or-later,
// https://github.com/mutability/dump978). See PROVENANCE.md.
import Foundation

/// A ground station's broadcast: where the station is, and up to 424 bytes of information frames, mostly FIS-B
/// weather and aeronautical products.
public struct UATUplinkMessage: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    /// The station marks its position as valid; dump978 notes that the position looks plausible either way.
    public var positionValid: Bool
    public var utcCoupled: Bool
    public var slotID: Int
    public var tisbSiteID: Int
    /// nil when the frame carries no application data.
    public var informationFrames: [InformationFrame]?

    public struct InformationFrame: Sendable, Equatable {
        public var type: Int
        public var data: [UInt8]
        /// Set for type 0 frames long enough to hold an APDU header.
        public var fisb: FISBProduct?
    }

    public init(payload frame: [UInt8]) {
        precondition(frame.count >= UAT.uplinkPayloadBytes, "a UAT uplink payload is 432 bytes")
        positionValid = frame[5] & 0x01 != 0
        let rawLat = Int(frame[0]) << 15 | Int(frame[1]) << 7 | Int(frame[2]) >> 1
        let rawLon = Int(frame[2] & 0x01) << 23 | Int(frame[3]) << 15 | Int(frame[4]) << 7 | Int(frame[5]) >> 1
        latitude = Double(rawLat) * 360 / 16_777_216
        if latitude > 90 { latitude -= 180 }
        longitude = Double(rawLon) * 360 / 16_777_216
        if longitude > 180 { longitude -= 360 }
        utcCoupled = frame[6] & 0x80 != 0
        slotID = Int(frame[6] & 0x1f)
        tisbSiteID = Int(frame[7] >> 4)
        guard frame[6] & 0x20 != 0 else { informationFrames = nil; return }

        // Information frames: 9-bit length, 4-bit type, then the data. A zero length and type ends the list.
        let appData = Array(frame[8..<(8 + 424)])
        var frames: [InformationFrame] = []
        var position = 0
        while frames.count < 424 / 6, position + 2 <= appData.count {
            let length = Int(appData[position]) << 1 | Int(appData[position + 1]) >> 7
            let type = Int(appData[position + 1] & 0x0f)
            if position + length + 2 > appData.count { break }
            if length == 0 && type == 0 { break }
            let data = Array(appData[(position + 2)..<(position + 2 + length)])
            frames.append(InformationFrame(type: type, data: data, fisb: type == 0 ? FISBProduct(data) : nil))
            position += length + 2
        }
        informationFrames = frames
    }
}

/// A FIS-B application data unit: a product identifier, its time, and the product's own bytes.
public struct FISBProduct: Sendable, Equatable {
    public var productID: Int
    public var flags: (a: Bool, g: Bool, p: Bool, s: Bool)
    public var month: Int?
    public var day: Int?
    public var hours: Int
    public var minutes: Int
    public var seconds: Int?
    public var payload: [UInt8]

    public static func == (a: FISBProduct, b: FISBProduct) -> Bool {
        a.productID == b.productID && a.flags == b.flags && a.month == b.month && a.day == b.day && a.hours == b.hours
            && a.minutes == b.minutes && a.seconds == b.seconds && a.payload == b.payload
    }

    /// nil if `data` is too short for the header its time option calls for.
    init?(_ data: [UInt8]) {
        guard data.count >= 4 else { return nil }
        let timeOption = Int(data[1] & 0x01) << 1 | Int(data[2]) >> 7
        let headerLength: Int
        switch timeOption {
        case 0:                                                  // hours, minutes
            headerLength = 4
            hours = Int(data[2] & 0x7c) >> 2
            minutes = Int(data[2] & 0x03) << 4 | Int(data[3]) >> 4
        case 1:                                                  // hours, minutes, seconds
            guard data.count >= 5 else { return nil }
            headerLength = 5
            hours = Int(data[2] & 0x7c) >> 2
            minutes = Int(data[2] & 0x03) << 4 | Int(data[3]) >> 4
            seconds = Int(data[3] & 0x0f) << 2 | Int(data[4]) >> 6
        case 2:                                                  // month, day, hours, minutes
            guard data.count >= 5 else { return nil }
            headerLength = 5
            month = Int(data[2] & 0x78) >> 3
            day = Int(data[2] & 0x07) << 2 | Int(data[3]) >> 6
            hours = Int(data[3] & 0x3e) >> 1
            minutes = Int(data[3] & 0x01) << 5 | Int(data[4]) >> 3
        default:                                                 // month, day, hours, minutes, seconds
            guard data.count >= 6 else { return nil }
            headerLength = 6
            month = Int(data[2] & 0x78) >> 3
            day = Int(data[2] & 0x07) << 2 | Int(data[3]) >> 6
            hours = Int(data[3] & 0x3e) >> 1
            minutes = Int(data[3] & 0x01) << 5 | Int(data[4]) >> 3
            // Six bits after the minutes: byte 4 bits 2-0, byte 5 bits 7-5. dump978 masks byte 4 with 0x03, losing 32 s
            // from any time whose seconds are 32 or more.
            seconds = Int(data[4] & 0x07) << 3 | Int(data[5]) >> 5
        }
        flags = (data[0] & 0x80 != 0, data[0] & 0x40 != 0, data[0] & 0x20 != 0, data[1] & 0x02 != 0)
        productID = Int(data[0] & 0x1f) << 6 | Int(data[1]) >> 2
        payload = Array(data[headerLength...])
    }

    /// Text products (product 413: METAR, TAF, winds aloft, PIREP ...) are 6-bit DLAC characters. Reports are
    /// separated by RS (0x1e) and the text ends with ETX (0x03), as in the DLAC alphabet.
    public var dlacText: String? {
        productID == 413 ? Self.decodeDLAC(payload) : nil
    }

    /// The 64-character DLAC alphabet; character 28 is a tab whose following character counts the spaces.
    static let dlacAlphabet: [Character] = Array("\u{03}ABCDEFGHIJKLMNOPQRSTUVWXYZ\u{1A}\t\u{1E}\n| !\"#$%&'()*+,-./0123456789:;<=>?")

    static func decodeDLAC(_ data: [UInt8]) -> String {
        var text = ""
        var tab = false
        var index = 0, step = 0
        while index < data.count {
            let character: Int
            switch step {
            case 0: character = Int(data[index]) >> 2; index += 1
            case 1: character = Int(data[index - 1] & 0x03) << 4 | Int(data[index]) >> 4; index += 1
            case 2: character = Int(data[index - 1] & 0x0f) << 2 | Int(data[index]) >> 6
            default: character = Int(data[index] & 0x3f); index += 1
            }
            if tab {
                text += String(repeating: " ", count: character)
                tab = false
            } else if character == 28 {
                tab = true
            } else {
                text.append(dlacAlphabet[character])
            }
            step = (step + 1) % 4
        }
        return text
    }

    /// The reports in a text product: split at RS or ETX, empty ones dropped.
    public var reports: [String] {
        guard let text = dlacText else { return [] }
        return text.split(whereSeparator: { $0 == "\u{1E}" || $0 == "\u{03}" }).map(String.init).filter { !$0.isEmpty }
    }

    /// A short name for the product, from the list in dump978.
    public var productName: String {
        switch productID {
        case 0, 20: return "METAR and SPECI"
        case 1, 21: return "TAF and amended TAF"
        case 2, 22: return "SIGMET"
        case 3, 23: return "Convective SIGMET"
        case 4, 24: return "AIRMET"
        case 5, 25: return "PIREP"
        case 6, 26: return "AWW"
        case 7, 27: return "Winds and temperatures aloft"
        case 8: return "NOTAM (including TFRs) and service status"
        case 9: return "D-ATIS"
        case 10: return "TWIP"
        case 11: return "Aerodrome and airspace AIRMET"
        case 12: return "Aerodrome and airspace SIGMET / convective SIGMET"
        case 13: return "Special use airspace status"
        case 63: return "Regional NEXRAD (8 level)"
        case 64: return "CONUS NEXRAD (8 level)"
        case 81: return "Radar echo tops (16 level)"
        case 82: return "Radar echo tops (8 level)"
        case 83: return "Storm tops and velocity"
        case 101: return "Lightning strikes (pixel level)"
        case 102: return "Lightning strikes (grid element level)"
        case 351: return "System time"
        case 352: return "Operational status"
        case 353: return "Ground station status"
        case 413: return "Generic text (DLAC)"
        default: return "product \(productID)"
        }
    }
}
