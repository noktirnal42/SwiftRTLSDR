// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRDecoders

/// `atn --frames FILE`: the ATN traffic (CPDLC, context management and the layers under them) in raw AVLC frames, one in
/// hexadecimal (with its FCS) on each line, optionally after a frequency in MHz, as `vdl2 --raw` prints them.
func atn(_ arguments: Arguments) {
    guard let path = arguments.option("frames") else { fail("atn --frames FILE (a hexadecimal AVLC frame on each line)") }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    let decoder: ATNDecoder
    do { decoder = try ATNDecoder() } catch { fail("\(error)") }
    let json = arguments.flag("json")
    var seen = 0
    for line in text.split(whereSeparator: \.isNewline) {
        let words = line.split(separator: " ")
        guard let hex = words.last, hex.count % 2 == 0 else { continue }
        let bytes = stride(from: 0, to: hex.count, by: 2).compactMap { UInt8(hex.dropFirst($0).prefix(2), radix: 16) }
        guard bytes.count == hex.count / 2, let frame = AVLCFrame(bytes: bytes), case .information = frame.kind else { if json { print("{}") }; continue }
        let message = decoder.decode(information: frame.info, source: frame.source.address, destination: frame.destination.address,
                                     fromAircraft: frame.source.type == 1)
        seen += message == nil ? 0 : 1
        if json { print(message?.json() ?? "{}") } else if let message {
            print("\(frame.source.hex) → \(frame.destination.hex)")
            for line in decoder.lines(for: message) { print("  " + line) }
        }
    }
    if !json { FileHandle.standardError.write(Data("ATN frames: \(seen)\n".utf8)) }
}
