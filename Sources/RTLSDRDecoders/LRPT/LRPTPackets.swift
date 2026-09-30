// SPDX-License-Identifier: GPL-2.0-or-later
//
// LRPT packets: CCSDS source packets (M_PDUs) carried across the data zone of the transfer frames, reassembled by a
// port of parser/mpdu_parser.c from meteor_decode by dbdexter-dev (MIT licence,
// https://github.com/dbdexter-dev/meteor_decode; copyright notice in NOTICE). See PROVENANCE.md.

/// One source packet: MSU-MR image data (APIDs 64-69), calibration (70) or other telemetry.
public struct LRPTPacket: Sendable {
    /// Header and data: 6 header bytes, then `length` bytes starting with the 8-byte time stamp.
    public let bytes: [UInt8]

    public var apid: Int { Int(bytes[0] & 0x07) << 8 | Int(bytes[1]) }
    public var sequence: Int { Int(bytes[2] & 0x3f) << 8 | Int(bytes[3]) }
    public var sequenceFlags: Int { Int(bytes[2] >> 6) }
    /// Length of the data field (time stamp included).
    public var length: Int { (Int(bytes[4]) << 8 | Int(bytes[5])) + 1 }
    public var day: Int { Int(bytes[6]) << 8 | Int(bytes[7]) }
    public var milliseconds: Int { Int(bytes[8]) << 24 | Int(bytes[9]) << 16 | Int(bytes[10]) << 8 | Int(bytes[11]) }
    public var microseconds: Int { Int(bytes[12]) << 8 | Int(bytes[13]) }
    /// The on-board clock in microseconds (Moscow time of day for the MSU-MR).
    public var time: UInt64 { UInt64(day) * 86_400_000_000 + UInt64(milliseconds) * 1000 + UInt64(microseconds) }
    /// Everything after the time stamp.
    public var payload: ArraySlice<UInt8> { bytes[14...] }
}

/// Reassembles packets from successive (corrected) frames of one virtual channel.
public final class LRPTPacketAssembler {
    static let dataZone = 882                          // bytes of packet data per frame
    static let headerLength = 6
    static let capacity = 6 + 8 + 2048                 // meteor_decode's packet buffer

    private enum State { case idle, header, data }
    private var state = State.idle
    private var offset = 0
    private var fragmentOffset = 0
    private var packet = [UInt8](repeating: 0, count: capacity + dataZone)

    public init() {}

    public func reset() {
        state = .idle
        offset = 0
        fragmentOffset = 0
    }

    /// The packets completed by this frame (a CADU of 1024 bytes, marker included).
    public func packets(in cadu: [UInt8]) -> [LRPTPacket] {
        var found: [LRPTPacket] = []
        while true {
            let (status, packet) = reconstruct(cadu)
            if let packet { found.append(packet) }
            if status == .proceed { break }
        }
        return found
    }

    private enum Status { case proceed, fragment, parsed }

    private func reconstruct(_ cadu: [UInt8]) -> (Status, LRPTPacket?) {
        let version = cadu[4] >> 6, type = cadu[5] & 0x3f
        let spare = cadu[12] >> 3
        let pointer = Int(cadu[12] & 0x07) << 8 | Int(cadu[13])
        let headerPresent = spare == 0 && pointer != 0x7ff
        let data = 14                                  // start of the data zone within the CADU
        // A packet whose corrupted length slipped through: if this frame has a header pointer, go back to idle after
        // it rather than waiting for a huge packet that does not exist.
        let jumpToIdle = headerPresent && offset == 0

        if version == 0 || type == 0 { return (.proceed, nil) }   // fill or known-bad data
        if fragmentOffset >= Self.capacity {
            reset()
            return (.proceed, nil)
        }
        switch state {
        case .idle:
            guard headerPresent else { return (.proceed, nil) }
            offset = pointer
            if offset > Self.dataZone { return (.proceed, nil) }
            fragmentOffset = 0
            state = .header
            return (.fragment, nil)

        case .header:
            let left = Self.headerLength - fragmentOffset
            if offset + left < Self.dataZone {
                copy(cadu, from: data + offset, count: left, to: fragmentOffset)
                fragmentOffset = 0
                offset += left
                state = .data
                return (.fragment, nil)
            }
            copy(cadu, from: data + offset, count: Self.dataZone - offset, to: fragmentOffset)
            fragmentOffset += Self.dataZone - offset
            offset = 0
            return (.proceed, nil)

        case .data:
            // As in meteor_decode, the length is 16-bit (0xffff + 1 wraps to 0), and a packet that ends exactly at the end
            // of a frame completes, with nothing left to copy, on the next one.
            let length = Int(UInt16(truncatingIfNeeded: (Int(packet[4]) << 8 | Int(packet[5])) + 1))
            let left = length - fragmentOffset
            if left >= 0 && offset + left < Self.dataZone {
                copy(cadu, from: data + offset, count: left, to: Self.headerLength + fragmentOffset)
                fragmentOffset = 0
                offset += left
                state = jumpToIdle ? .idle : .header
                let total = Self.headerLength + length
                return (.parsed, LRPTPacket(bytes: Array(packet[0..<max(14, min(total, packet.count))])))
            }
            copy(cadu, from: data + offset, count: Self.dataZone - offset, to: Self.headerLength + fragmentOffset)
            fragmentOffset += Self.dataZone - offset
            offset = 0
            state = jumpToIdle ? .idle : .data
            return (jumpToIdle ? .fragment : .proceed, nil)
        }
    }

    private func copy(_ cadu: [UInt8], from source: Int, count: Int, to destination: Int) {
        guard count > 0 else { return }
        for index in 0..<count where destination + index < packet.count && source + index < cadu.count {
            packet[destination + index] = cadu[source + index]
        }
    }
}
