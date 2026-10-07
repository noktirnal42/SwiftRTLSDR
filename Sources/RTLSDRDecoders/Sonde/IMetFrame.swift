// SPDX-License-Identifier: GPL-2.0-or-later
//
// The packets of an InterMet iMet-1 / iMet-4 radiosonde. Written from NOAA's "iMet-1-RSB Radiosonde Protocol"
// (Wendell and Jordan, version 1.11, 2009), which gives the packet layouts; the checksum's initial value and its byte
// order, the float format of the position and the idle framing are as rs1729's imet1rs_dft decodes real flights (GPL-3.0,
// read for these facts only; no code taken). Written for this package. See PROVENANCE.md.
import Foundation

/// The iMet's fixed numbers.
public enum IMet {
    /// The sondes transmit between 400 and 406 MHz, like the other types.
    public static let frequencyRange = 400_000_000...406_000_000
    /// Bits a second: Bell 202 audio frequency shift keying on an FM carrier, 1200 Hz for a 1 and 2200 Hz for a 0.
    public static let baud = 1200.0
    public static let markHz = 1200.0, spaceHz = 2200.0
    /// The longest frame read: a second of telemetry is a GPS, a PTU and a few XDATA packets, well within 100 bytes.
    public static let maxFrameBytes = 100
    /// Mark bits that precede a frame (the sondes send more; fewer are needed to be sure of the start bit).
    static let idleMarks = 20

    /// A frame's first byte, the packets' start of heading.
    static let soh: UInt8 = 0x01

    public enum PacketID: UInt8, Sendable {
        case ptu = 0x01, gps = 0x02, xdata = 0x03, ptux = 0x04, gpsx = 0x05
    }

    /// The header the receiver correlates with: the idle marks, then the first byte, 0x01, as a start bit, eight data bits
    /// least significant first and a stop bit (+1 for the 1200 Hz tone).
    static let headerSymbols: [Double] = {
        var bits = [Double](repeating: 1, count: idleMarks)
        bits += uartBits(of: soh)
        return bits
    }()

    /// A byte as an asynchronous 8N1 character: start bit (0), data bits least significant first, stop bit (1), as ±1.
    static func uartBits(of byte: UInt8) -> [Double] {
        [-1] + (0..<8).map { byte >> UInt8($0) & 1 == 1 ? 1.0 : -1.0 } + [1]
    }

    /// CRC-16 with the CCITT polynomial 0x1021, started from 0x1D0F, over every byte of a packet up to its checksum (the
    /// start of heading included). The checksum is sent most significant byte first, unlike the fields.
    public static func checksum<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var remainder: UInt16 = 0x1D0F
        for byte in bytes {
            remainder ^= UInt16(byte) << 8
            for _ in 0..<8 { remainder = remainder & 0x8000 != 0 ? remainder << 1 ^ 0x1021 : remainder << 1 }
        }
        return remainder
    }

    /// How long a packet is, from its first bytes (`bytes` starts at the start of heading): the identifier gives it, but
    /// an XDATA packet carries its own.
    static func packetLength(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard bytes.count >= 2, bytes[bytes.startIndex] == soh, let id = PacketID(rawValue: bytes[bytes.startIndex + 1]) else { return nil }
        switch id {
        case .ptu: return 14
        case .ptux: return 20
        case .gps: return 18
        case .gpsx: return 30
        case .xdata:
            guard bytes.count >= 3 else { return nil }
            let count = Int(bytes[bytes.startIndex + 2])
            return count > 0 ? count + 5 : nil
        }
    }
}

/// Pressure, temperature and humidity of the sonde (and what it measures of itself).
public struct IMetPTU: Sendable, Equatable {
    /// The packet counter, which the JSON uses as the frame number.
    public var number: Int
    /// Millibars.
    public var pressure: Double
    /// °C.
    public var temperature: Double
    /// % relative humidity.
    public var humidity: Double
    /// Volts.
    public var batteryVolts: Double
    /// The extended packet's extra readings: the sonde's internal temperature, the pressure sensor's and the humidity
    /// sensor's, °C.
    public var internalTemperature: Double?
    public var pressureSensorTemperature: Double?
    public var humiditySensorTemperature: Double?
}

/// Position, time of day and (in the extended packet) velocity.
public struct IMetGPS: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    /// Metres (the packet carries it 5000 m high so that it stays positive).
    public var altitude: Int
    public var satellites: Int
    /// The GPS receiver's time of day (the packet gives no date).
    public var hour: Int, minute: Int, second: Int
    /// East, north and up velocity, metres a second (extended packet only).
    public var velocity: (east: Double, north: Double, up: Double)?

    public static func == (a: IMetGPS, b: IMetGPS) -> Bool {
        a.latitude == b.latitude && a.longitude == b.longitude && a.altitude == b.altitude && a.satellites == b.satellites
            && a.hour == b.hour && a.minute == b.minute && a.second == b.second
            && a.velocity?.east == b.velocity?.east && a.velocity?.north == b.velocity?.north && a.velocity?.up == b.velocity?.up
    }

    /// Whether the numbers are possible (a packet can pass the 16-bit checksum by chance).
    public var isPlausible: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
            && hour < 24 && minute < 60 && second < 61 && satellites <= 32
    }
}

/// Data from an instrument attached to the sonde (an ozonesonde, a hygrometer, ...), as the bytes after the length.
public struct IMetXData: Sendable, Equatable {
    /// The bytes the packet carries, the instrument's identifier and the daisy chain index first.
    public var data: [UInt8]
    public var instrument: UInt8? { data.first }
    /// The hexadecimal text radiosonde_auto_rx's JSON gives as `aux`.
    public var hex: String { data.map { String(format: "%02X", $0) }.joined() }

    /// An ozonesonde's readings (instrument 0x01, eight bytes, most significant byte first).
    public struct Ozonesonde: Sendable, Equatable {
        /// µA.
        public var cellCurrent: Double
        /// °C.
        public var pumpTemperature: Double
        /// mA.
        public var pumpCurrent: Int
        public var batteryVolts: Double
    }

    public var ozonesonde: Ozonesonde? {
        guard data.count == 8, data[0] == 0x01 else { return nil }
        let current = Int(data[2]) << 8 | Int(data[3]), pump = Int16(bitPattern: UInt16(data[4]) << 8 | UInt16(data[5]))
        return Ozonesonde(cellCurrent: Double(current) / 1000, pumpTemperature: Double(pump) / 100, pumpCurrent: Int(data[6]),
                          batteryVolts: Double(data[7]) / 10)
    }
}

/// One packet with a good checksum.
public enum IMetPacket: Sendable, Equatable {
    case ptu(IMetPTU)
    case gps(IMetGPS)
    case xdata(IMetXData)

    /// The packet in `bytes` (the start of heading first, exactly one packet long), if its checksum holds.
    init?(bytes: [UInt8]) {
        guard let length = IMet.packetLength(bytes[...]), bytes.count == length else { return nil }
        let check = UInt16(bytes[length - 2]) << 8 | UInt16(bytes[length - 1])
        guard IMet.checksum(bytes[0..<(length - 2)]) == check else { return nil }
        func unsigned(_ at: Int, _ count: Int) -> Int { (0..<count).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) } }
        func signed16(_ at: Int) -> Double { Double(Int16(truncatingIfNeeded: unsigned(at, 2))) }
        func float(_ at: Int) -> Double { Double(Float(bitPattern: UInt32(unsigned(at, 4)))) }
        switch IMet.PacketID(rawValue: bytes[1])! {
        case .ptu, .ptux:
            var ptu = IMetPTU(number: unsigned(2, 2), pressure: Double(unsigned(4, 3)) / 100, temperature: signed16(7) / 100,
                              humidity: Double(unsigned(9, 2)) / 100, batteryVolts: Double(bytes[11]) / 10)
            if bytes[1] == IMet.PacketID.ptux.rawValue {
                ptu.internalTemperature = signed16(12) / 100
                ptu.pressureSensorTemperature = signed16(14) / 100
                ptu.humiditySensorTemperature = signed16(16) / 100
            }
            self = .ptu(ptu)
        case .gps, .gpsx:
            let extended = bytes[1] == IMet.PacketID.gpsx.rawValue
            let time = extended ? 25 : 13
            var gps = IMetGPS(latitude: float(2), longitude: float(6), altitude: unsigned(10, 2) - 5000, satellites: Int(bytes[12]),
                              hour: Int(bytes[time]), minute: Int(bytes[time + 1]), second: Int(bytes[time + 2]))
            if extended { gps.velocity = (float(13), float(17), float(21)) }
            self = .gps(gps)
        case .xdata:
            self = .xdata(IMetXData(data: Array(bytes[3..<(length - 2)])))
        }
    }
}

/// The packets of one telemetry frame, one after the other, as they were received.
public struct IMetFrame: Sendable {
    /// Packets with a good checksum.
    public var packets: [IMetPacket]
    /// Packets that were cut off or whose checksum failed (the frame stops at the first).
    public var damaged: Int
    /// Bytes read.
    public var byteCount: Int

    /// Reads packets from a frame's bytes (from the first start of heading) until one does not parse.
    public init(bytes: [UInt8]) {
        var packets: [IMetPacket] = []
        var offset = 0, damaged = 0
        while offset < bytes.count, bytes[offset] == IMet.soh {
            guard let length = IMet.packetLength(bytes[offset...]), offset + length <= bytes.count else { damaged += 1; break }
            guard let packet = IMetPacket(bytes: Array(bytes[offset..<(offset + length)])) else { damaged += 1; break }
            packets.append(packet)
            offset += length
        }
        self.packets = packets
        self.damaged = damaged
        byteCount = offset
    }

    public var gps: IMetGPS? { packets.lazy.compactMap { if case .gps(let gps) = $0 { return gps } else { return nil } }.first }
    public var ptu: IMetPTU? { packets.lazy.compactMap { if case .ptu(let ptu) = $0 { return ptu } else { return nil } }.first }
    public var xdata: [IMetXData] { packets.compactMap { if case .xdata(let data) = $0 { return data } else { return nil } } }
}
