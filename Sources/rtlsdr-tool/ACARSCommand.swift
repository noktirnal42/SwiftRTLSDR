// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRDecoders
import RTLSDRKit

/// ACARS channels by region (MHz): North America's and Europe's usual ones.
private let acarsRegions: [String: [Double]] = [
    "us": [131.550, 131.125, 130.450, 130.425, 130.025],
    "eu": [131.525, 131.725, 131.825],
]

private final class ACARSPrinter: @unchecked Sendable {
    let json: Bool
    var receiver: ACARSReceiver?                    // used on the backlog's queue only
    private(set) var count = 0
    init(json: Bool) { self.json = json }

    func print(_ message: ACARSMessage, channel: Int, frequencyHz: Double?, levelDB: Double?, time: Date = Date()) {
        count += 1
        if json {
            var extra: [String: Any] = ["timestamp": time.timeIntervalSince1970, "channel": channel]
            if let frequencyHz { extra["freq"] = (frequencyHz / 1e3).rounded() / 1e3 }
            if let levelDB { extra["level"] = (levelDB * 10).rounded() / 10 }
            Swift.print(message.json(extra: extra))
        } else {
            let clock = DateFormatter()
            clock.dateFormat = "HH:mm:ss"
            var line = clock.string(from: time) + "  "
            line += frequencyHz.map { String(format: "%.3f", $0 / 1e6) } ?? "#\(channel + 1)"
            if let levelDB { line += String(format: "  %5.1f dB", levelDB) }
            if message.correctedBits > 0 { line += "  (\(message.correctedBits) bit\(message.correctedBits > 1 ? "s" : "") fixed)" }
            Swift.print(line + "  " + message.line)
        }
    }
}

/// `acars`: ACARS on VHF from the dongle (several channels at once), an I/Q recording, or AM audio in a WAV file.
func acars(_ arguments: Arguments) {
    let json = arguments.flag("json")
    let printer = ACARSPrinter(json: json)

    if let path = arguments.option("wav") {
        let wav: WAVFile
        do { wav = try WAVFile(path: path) } catch { fail("\(error)") }
        for (channel, samples) in wav.channels.enumerated() {
            let demodulator = ACARSDemodulator(sampleRate: wav.sampleRate)
            for message in demodulator.process(audio: samples) {
                let level = demodulator.lastLevel / Double(wav.fullScale)
                printer.print(message, channel: channel, frequencyHz: nil, levelDB: 20 * log10(max(level, 1e-12)))
            }
        }
        FileHandle.standardError.write(Data("messages: \(printer.count)\n".utf8))
        return
    }

    var channels: [Double]
    if let list = arguments.option("freq") {
        channels = list.split(separator: ",").compactMap { Double($0) }.map { $0 < 1e4 ? $0 * 1e6 : $0 }
        guard !channels.isEmpty else { fail("--freq takes frequencies in MHz or Hz, separated by commas") }
    } else {
        let region = (arguments.option("region") ?? "us").lowercased()
        guard let list = acarsRegions[region] else { fail("--region is us or eu (or give --freq)") }
        channels = list.map { $0 * 1e6 }
    }
    let rate = arguments.double("rate", default: 2_400_000)
    guard (rate / 12_500).rounded() * 12_500 == rate.rounded() else { fail("--rate must be a multiple of 12500 (2400000, 2000000, ...)") }
    var center = arguments.option("center").map { _ in arguments.double("center", default: 0) }
        ?? ((channels.min()! + channels.max()!) / 2)
    // Keep every channel off the DC spike.
    if arguments.option("center") == nil, channels.contains(where: { abs($0 - center) < 10_000 }) { center += 12_500 }
    let reach = rate / 2 - 15_000
    let outside = channels.filter { abs($0 - center) > reach }
    if !outside.isEmpty {
        fail("\(outside.map { String(format: "%.3f", $0 / 1e6) }.joined(separator: ", ")) MHz: outside ±\(Int(reach / 1000)) kHz of \(megahertz(center)); use fewer channels, or a higher --rate")
    }
    let receiver = ACARSReceiver(sampleRate: rate, centerHz: center, channels: channels)
    let description = "ACARS on " + channels.map { String(format: "%.3f", $0 / 1e6) }.joined(separator: ", ") + " MHz"

    if let path = arguments.option("ifile") {
        guard let file = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
        if !json { FileHandle.standardError.write(Data("\(description), tuned \(megahertz(center)), \(Int(rate)) S/s\n".utf8)) }
        let start = Date(timeIntervalSince1970: 0)
        while true {
            let chunk = file.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            for r in receiver.process(iq: [UInt8](chunk)) {
                printer.print(r.message, channel: r.channel, frequencyHz: r.frequencyHz, levelDB: r.levelDB,
                              time: start.addingTimeInterval(Double(r.sampleIndex) / rate))
            }
        }
        FileHandle.standardError.write(Data("messages: \(printer.count)\n".utf8))
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
        let backlog = Backlog(label: "acars-input")
        let failure = FailureBox()
        printer.receiver = receiver
        try device.startStreaming(onError: { failure.set($0) }) { block in
            backlog.submit(block) { samples in
                for r in printer.receiver!.process(iq: samples) {
                    printer.print(r.message, channel: r.channel, frequencyHz: r.frequencyHz, levelDB: r.levelDB)
                }
            }
        }
        if !json { print("listening for \(description) (tuned \(megahertz(center)), \(Int(rate)) S/s); Ctrl-C to stop") }
        let started = monotonicSeconds()
        while monotonicSeconds() - started < seconds, failure.value == nil {
            Thread.sleep(forTimeInterval: 0.5)
            let dropped = backlog.newlyDropped()
            if dropped > 0 { FileHandle.standardError.write(Data("warning: decoding fell behind; dropped \(dropped) block(s)\n".utf8)) }
        }
        device.stopStreaming()
        backlog.sync {}
        FileHandle.standardError.write(Data("messages: \(printer.count)\n".utf8))
        if let error = failure.value { fail(error.localizedDescription) }
    } catch { fail(error.localizedDescription) }
}
