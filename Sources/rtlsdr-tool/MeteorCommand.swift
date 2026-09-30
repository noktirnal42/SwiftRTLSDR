// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRDecoders
import RTLSDRKit

/// `meteor`: Meteor-M LRPT weather images on 137 MHz, from soft symbols, a recording of u8 I/Q, or the dongle.
func meteor(_ arguments: Arguments) {
    let mode: LRPT.Mode
    switch arguments.option("mode") ?? "oqpsk" {
    case "qpsk": mode = .qpsk
    case "oqpsk": mode = .oqpskNRZM
    default: fail("--mode is qpsk (Meteor-M N2) or oqpsk (N2-3, N2-4, the default)")
    }
    let decoder = LRPTDecoder(mode: mode)
    let output = arguments.option("out") ?? "meteor"
    var caduFile: FileHandle?
    if let path = arguments.option("cadu") {
        _ = FileManager.default.createFile(atPath: path, contents: nil)
        caduFile = FileHandle(forWritingAtPath: path)
        guard caduFile != nil else { fail("cannot write \(path)") }
    }
    decoder.onFrame = { frame in
        if frame.isValid { caduFile?.write(Data(frame.bytes)) }
    }

    if let path = arguments.option("soft") {
        guard let file = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
        while true {
            let chunk = file.readData(ofLength: 1 << 16)
            if chunk.isEmpty { break }
            decoder.process(soft: chunk.map { Int8(bitPattern: $0) })
        }
        decoder.flush()
        finishMeteor(decoder, directory: output)
        return
    }
    fail("give --soft FILE (8-bit soft symbols)")
}

func finishMeteor(_ decoder: LRPTDecoder, directory: String) {
    let statistics = decoder.statistics
    print("frames: \(statistics.frames), valid: \(statistics.validFrames), symbols corrected: \(statistics.correctedSymbols)")
    print("packets: \(statistics.packets) (\(statistics.packetsPerAPID.sorted { $0.key < $1.key }.map { "APID \($0.key): \($0.value)" }.joined(separator: ", ")))")
    do {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for channel in decoder.imager.orderedChannels {
            guard let image = decoder.imager.image(apid: channel.apid), image.height > 0 else { continue }
            let path = (directory as NSString).appendingPathComponent("msu-mr-\(channel.apid).png")
            try Data(image.png).write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(image.height) lines)")
        }
        if let composite = decoder.imager.composite() {
            let path = (directory as NSString).appendingPathComponent("msu-mr-rgb.png")
            try Data(composite.png).write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
    } catch { fail(error.localizedDescription) }
}
