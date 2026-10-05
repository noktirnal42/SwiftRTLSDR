// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRDecoders
import RTLSDRKit

/// Reads `--sf`, `--bw`, `--cr`, `--sync`, `--preamble` and `--ldro` (defaults: Meshtastic's LongFast).
func loraParameters(_ arguments: Arguments, preset: (sf: Int, bw: Double, cr: Int)? = nil) -> LoRaParameters {
    let sf = arguments.int("sf", default: preset?.sf ?? 11)
    guard (6...12).contains(sf) else { fail("--sf is 6 to 12") }
    let bw = arguments.double("bw", default: preset?.bw ?? 250_000)
    let cr = arguments.int("cr", default: preset?.cr ?? 1)
    guard (1...4).contains(cr) else { fail("--cr is 1 to 4 (4/5 to 4/8)") }
    let sync = UInt8(truncatingIfNeeded: Int(arguments.option("sync").flatMap { $0.hasPrefix("0x") ? Int($0.dropFirst(2), radix: 16) : Int($0) } ?? 0x2b))
    var ldro: Bool?
    if let value = arguments.option("ldro") { ldro = value == "1" || value == "on" }
    return LoRaParameters(spreadingFactor: sf, bandwidth: bw, codingRate: cr, lowDataRate: ldro, syncWord: sync,
                          preambleLength: arguments.int("preamble", default: 16))
}

/// Fails unless `rate` is a whole multiple of the LoRa bandwidth (the receiver takes every n-th sample as a chip).
func checkLoRaRate(_ rate: Double, _ parameters: LoRaParameters) {
    let ratio = rate / parameters.bandwidth
    guard ratio >= 1, abs(ratio - ratio.rounded()) < 1e-6 else {
        fail("--rate must be a whole multiple of the \(parameters.bandwidth / 1000) kHz bandwidth (e.g. \(Int(4 * parameters.bandwidth)))")
    }
}

/// Feeds a file of u8 I/Q (or with `--cf32`, complex floats) to `receiver`, handing each block's frames to `handle`.
func readLoRaFile(_ path: String, cf32: Bool, receiver: LoRaReceiver, handle: ([LoRaFrame]) -> Void) {
    guard let file = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
    while true {
        let chunk = file.readData(ofLength: 1 << 20)
        if chunk.isEmpty { break }
        if cf32 {
            let floats = chunk.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            handle(receiver.process(complex: floats))
        } else {
            handle(receiver.process(iq: [UInt8](chunk)))
        }
    }
}

/// `lora`: LoRa frames (explicit header) from a recording, printed as hex with their CRC check.
func lora(_ arguments: Arguments) {
    guard let path = arguments.option("ifile") else { fail("--ifile FILE is required (u8 I/Q, or complex floats with --cf32)") }
    let parameters = loraParameters(arguments)
    let rate = arguments.double("rate", default: 1_000_000)
    checkLoRaRate(rate, parameters)
    let frequency = arguments.option("freq").map { _ in arguments.double("freq", default: 0) }
    let receiver = LoRaReceiver(parameters: parameters, sampleRate: rate, offsetHz: arguments.double("offset", default: 0),
                                centerFrequencyHz: frequency)
    var count = 0, good = 0
    readLoRaFile(path, cf32: arguments.flag("cf32"), receiver: receiver) { frames in
        for frame in frames {
            count += 1
            if frame.crcValid == true { good += 1 }
            let crc = frame.crcValid.map { $0 ? "CRC ok" : "CRC BAD" } ?? "no CRC"
            print(String(format: "%.3f s  %@  %3d bytes  %+.0f Hz  SNR %.1f dB  %@", frame.sampleIndex / rate, crc,
                         frame.payload.count, frame.carrierOffsetHz, frame.snrDB,
                         frame.payload.map { String(format: "%02x", $0) }.joined()))
            if arguments.flag("symbols") { print("symbols: " + frame.symbols.map(String.init).joined(separator: " ")) }
        }
    }
    FileHandle.standardError.write(Data("frames: \(count), CRC ok: \(good), preambles without a frame: \(receiver.rejectedPreambles)\n".utf8))
}
