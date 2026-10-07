// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRDecoders
import RTLSDRKit

/// VDL Mode 2 channels by region (MHz): the common signalling channel 136.975 MHz and the usual others.
private let vdl2Regions: [String: [Double]] = [
    "us": [136.975, 136.650, 136.700, 136.800],
    "eu": [136.975, 136.875, 136.775, 136.725],
]

private final class VDL2Printer: @unchecked Sendable {
    let json: Bool
    let verbose: Bool
    var raw = false
    var receiver: VDL2Receiver?                     // used on the backlog's queue only
    /// ATN traffic (CPDLC and context management, and the layers under them), decoded from the information frames; it remembers
    /// what reassembly needs, so it is used on the backlog's queue only.
    lazy var atn: ATNDecoder? = try? ATNDecoder()
    private(set) var count = 0
    private let clock: DateFormatter
    init(json: Bool, verbose: Bool) {
        self.json = json
        self.verbose = verbose
        clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
    }

    func print(_ r: VDL2Receiver.Reception, time: Date) {
        count += 1
        let b = r.burst
        let ppm = b.frequencyOffsetHz / r.frequencyHz * 1e6
        if raw {
            Swift.print(String(format: "%.3f ", r.frequencyHz / 1e6) + r.frame.bytes.map { String(format: "%02x", $0) }.joined())
        } else if json {
            var avlc = r.frame.jsonObject()
            if let message = atnMessage(r.frame), let data = message.json(frequencyHz: r.frequencyHz).data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                avlc["atn"] = object
            }
            let seconds = time.timeIntervalSince1970
            let object: [String: Any] = ["vdl2": [
                "app": ["name": "rtlsdr-tool", "ver": "1"],
                "t": ["sec": Int(seconds), "usec": Int((seconds - seconds.rounded(.down)) * 1e6)],
                "freq": Int(r.frequencyHz.rounded()),
                "burst_len_octets": b.octets,
                "hdr_bits_fixed": b.headerCorrected ? 1 : 0,
                "octets_corrected_by_fec": b.correctedOctets,
                "sig_level": (b.levelDB * 10).rounded() / 10,
                "noise_level": (b.noiseDB * 10).rounded() / 10,
                "freq_skew": (ppm * 100).rounded() / 100,
                "avlc": avlc,
            ] as [String: Any]]
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                Swift.print(String(decoding: data, as: UTF8.self))
            }
        } else {
            var line = clock.string(from: time) + "  " + String(format: "%.3f  %5.1f dB  ", r.frequencyHz / 1e6, b.levelDB - b.noiseDB)
            if verbose { line += String(format: "%+.1f ppm  ", ppm) + (b.correctedOctets > 0 ? "(\(b.correctedOctets) fixed)  " : "") }
            Swift.print(line + r.frame.line)
            if let message = atnMessage(r.frame), let atn {
                for text in atn.lines(for: message) { Swift.print("      " + text) }
            }
        }
    }

    /// What an information frame says in the ATN's layers, if it is X.25 (ACARS and XID frames are not).
    private func atnMessage(_ frame: AVLCFrame) -> ATNMessage? {
        guard case .information = frame.kind, frame.acars == nil, !frame.info.isEmpty, let atn else { return nil }
        return atn.decode(information: frame.info, source: frame.source.address, destination: frame.destination.address, fromAircraft: frame.source.type == 1)
    }
}

/// `vdl2`: VDL Mode 2 on VHF from the dongle (several channels at once) or an I/Q recording.
func vdl2(_ arguments: Arguments) {
    let printer = VDL2Printer(json: arguments.flag("json"), verbose: arguments.flag("verbose"))
    printer.raw = arguments.flag("raw")
    var channels: [Double]
    if let list = arguments.option("freq") {
        channels = list.split(separator: ",").compactMap { Double($0) }.map { $0 < 1e4 ? $0 * 1e6 : $0 }
        guard !channels.isEmpty else { fail("--freq takes frequencies in MHz or Hz, separated by commas") }
    } else {
        let region = (arguments.option("region") ?? "eu").lowercased()
        guard let list = vdl2Regions[region] else { fail("--region is us or eu (or give --freq)") }
        channels = list.map { $0 * 1e6 }
    }
    let rate = arguments.double("rate", default: 1_050_000)
    guard (rate / 42_000).rounded() * 42_000 == rate else { fail("--rate must be a multiple of 42000 (1050000, 1680000, 2100000, ...)") }
    var center = arguments.option("center").map { _ in arguments.double("center", default: 0) }
        ?? ((channels.min()! + channels.max()!) / 2)
    if arguments.option("center") == nil, channels.contains(where: { abs($0 - center) < 15_000 }) { center += 12_500 }
    let reach = rate / 2 - 30_000
    let outside = channels.filter { abs($0 - center) > reach }
    if !outside.isEmpty {
        fail("\(outside.map { String(format: "%.3f", $0 / 1e6) }.joined(separator: ", ")) MHz: outside ±\(Int(reach / 1000)) kHz of \(megahertz(center)); use fewer channels, or a higher --rate")
    }
    let receiver = VDL2Receiver(sampleRate: rate, centerHz: center, channels: channels)
    let description = "VDL2 on " + channels.map { String(format: "%.3f", $0 / 1e6) }.joined(separator: ", ") + " MHz"

    if let path = arguments.option("ifile") {
        guard let file = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
        if !printer.json { FileHandle.standardError.write(Data("\(description), tuned \(megahertz(center)), \(Int(rate)) S/s\n".utf8)) }
        let start = Date(timeIntervalSince1970: 0)
        while true {
            let chunk = file.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            for r in receiver.process(iq: [UInt8](chunk)) {
                printer.print(r, time: start.addingTimeInterval(Double(r.sampleIndex) / rate))
            }
        }
        FileHandle.standardError.write(Data("frames: \(printer.count)\(receiver.badFrames > 0 ? ", \(receiver.badFrames) with a bad FCS" : "")\n".utf8))
        return
    }

    let seconds = arguments.double("seconds", default: 1e9)
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        _ = try device.setSampleRate(Int(rate))
        try arguments.applyFrequencyCorrection(to: device)
        try device.setCenterFrequency(Int(center.rounded()))
        try arguments.applyGain(to: device, default: "auto")
        let backlog = Backlog(label: "vdl2-input")
        let failure = FailureBox()
        printer.receiver = receiver
        try device.startStreaming(onError: { failure.set($0) }) { block in
            backlog.submit(block) { samples in
                for r in printer.receiver!.process(iq: samples) { printer.print(r, time: Date()) }
            }
        }
        if !printer.json { print("listening for \(description) (tuned \(megahertz(center)), \(Int(rate)) S/s); Ctrl-C to stop") }
        let started = monotonicSeconds()
        while monotonicSeconds() - started < seconds, failure.value == nil {
            Thread.sleep(forTimeInterval: 0.5)
            let dropped = backlog.newlyDropped()
            if dropped > 0 { FileHandle.standardError.write(Data("warning: decoding fell behind; dropped \(dropped) block(s)\n".utf8)) }
        }
        device.stopStreaming()
        backlog.sync {}
        FileHandle.standardError.write(Data("frames: \(printer.count)\n".utf8))
        if let error = failure.value { fail(error.localizedDescription) }
    } catch { fail(error.localizedDescription) }
}
