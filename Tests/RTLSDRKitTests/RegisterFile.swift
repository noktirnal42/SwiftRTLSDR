// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The dongle's registers as a sequence of writes leaves them. Used to compare two sessions by outcome instead of by
/// exact transfer order (this driver skips writes that would change nothing; the reference sometimes repeats them).
struct RegisterFile {
    /// R820T registers (I2C address 0x34).
    var tuner: [Int: UInt8] = [:]
    /// Demodulator registers, keyed page * 256 + address. Multi-byte writes fill consecutive addresses.
    var demod: [Int: UInt8] = [:]
    /// USB and system block registers, keyed by "block:address".
    var other: [String: [UInt8]] = [:]

    mutating func apply(_ transfer: Transfer) {
        guard transfer.isWrite else { return }
        let block = Int(transfer.index >> 8) & 0xff
        switch block {
        case 6:                                                             // I2C: first byte is the tuner register
            guard transfer.value == 0x34, transfer.data.count > 1 else { return }
            for (offset, byte) in transfer.data.dropFirst().enumerated() { tuner[Int(transfer.data[0]) + offset] = byte }
        case 0:
            let page = Int(transfer.index & 0x0f), address = Int(transfer.value >> 8)
            for (offset, byte) in transfer.data.enumerated() { demod[page * 256 + address + offset] = byte }
        default:
            other["\(block):\(String(transfer.value, radix: 16))"] = transfer.data
        }
    }

    init(_ transfers: [Transfer], upTo stop: (Transfer) -> Bool = { _ in false }) {
        for transfer in transfers {
            apply(transfer)
            if stop(transfer) { break }
        }
    }

    /// Human-readable list of registers that differ, empty when the two match.
    func differences(from expected: RegisterFile) -> [String] {
        var found: [String] = []
        for key in Set(tuner.keys).union(expected.tuner.keys).sorted() where tuner[key] != expected.tuner[key] {
            found.append("tuner 0x\(String(key, radix: 16)): got \(describe(tuner[key])), reference \(describe(expected.tuner[key]))")
        }
        for key in Set(demod.keys).union(expected.demod.keys).sorted() where demod[key] != expected.demod[key] {
            found.append("demod page \(key >> 8) 0x\(String(key & 0xff, radix: 16)): got \(describe(demod[key])), reference \(describe(expected.demod[key]))")
        }
        for key in Set(other.keys).union(expected.other.keys).sorted() where other[key] != expected.other[key] {
            found.append("block \(key): got \(other[key] ?? []), reference \(expected.other[key] ?? [])")
        }
        return found
    }

    private func describe(_ byte: UInt8?) -> String { byte.map { String(format: "0x%02x", $0) } ?? "unwritten" }
}

/// Reads a trace file in `TracingTransport`'s format.
func parseTrace(_ text: String) -> [Transfer] {
    text.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 3, parts[0] == "W" || parts[0] == "R",
              let value = UInt16(parts[1].dropFirst(2), radix: 16), let index = UInt16(parts[2].dropFirst(2), radix: 16) else { return nil }
        let isWrite = parts[0] == "W"
        // Writes: data follows. Reads: "<length> -> data".
        let dataParts = isWrite ? Array(parts.dropFirst(3)) : Array(parts.drop(while: { $0 != "->" }).dropFirst())
        return Transfer(isWrite: isWrite, value: value, index: index, data: dataParts.compactMap { UInt8($0, radix: 16) })
    }
}

func goldenTrace(named name: String) throws -> [Transfer] {
    guard let url = Bundle.module.url(forResource: name, withExtension: "trace", subdirectory: "Resources/golden") else {
        throw TestSetupError.missingResource(name)
    }
    return parseTrace(try String(contentsOf: url, encoding: .utf8))
}

enum TestSetupError: Error { case missingResource(String) }

/// The write that restarts the sample FIFO: a session's configuration is complete once this has happened.
let isBufferReset: @Sendable (Transfer) -> Bool = { $0.isWrite && $0.value == 0x2148 && $0.index == 0x0110 && $0.data == [0, 0] }
