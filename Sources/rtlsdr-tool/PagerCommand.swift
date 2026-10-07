// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRDecoders
import RTLSDRKit

private final class PagerPrinter: @unchecked Sendable {
    let receiver: POCSAGReceiver
    let json: Bool
    let mode: POCSAGTextMode
    private(set) var pages = 0

    init(receiver: POCSAGReceiver, json: Bool, mode: POCSAGTextMode) {
        self.receiver = receiver
        self.json = json
        self.mode = mode
    }

    private func print(_ events: [POCSAGEvent]) {
        for event in events {
            pages += 1
            Swift.print(json ? event.message.json(mode) : event.message.line(mode))
        }
    }

    func process(iq: [UInt8]) { print((try? receiver.process(iq: iq)) ?? []) }
    func process(audio: [Float]) { print((try? receiver.process(audio: audio)) ?? []) }

    func summary() {
        let decoders = receiver.decoder
        let corrected = decoders.map(\.correctedTotal).reduce(0, +), damaged = decoders.map(\.damagedTotal).reduce(0, +)
        FileHandle.standardError.write(Data("pages: \(pages), codewords corrected: \(corrected), beyond repair: \(damaged)\n".utf8))
    }
}

/// `pager`: POCSAG pages (512, 1200 and 2400 bit/s) from the dongle, a recording of u8 I/Q, or FM audio in a WAV file.
func pager(_ arguments: Arguments) {
    let json = arguments.flag("json")
    guard let mode = POCSAGTextMode(rawValue: arguments.option("mode") ?? "standard") else {
        fail("--mode is one of \(POCSAGTextMode.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    var bauds = POCSAG.baudRates
    if let text = arguments.option("baud"), text != "all" {
        guard let baud = Double(text), POCSAG.baudRates.contains(baud) else { fail("--baud is 512, 1200, 2400 or all") }
        bauds = [baud]
    }
    func configure(_ receiver: POCSAGReceiver) -> PagerPrinter {
        if arguments.flag("partial") { receiver.decoder.forEach { $0.reportsPartialPages = true } }
        return PagerPrinter(receiver: receiver, json: json, mode: mode)
    }

    if let path = arguments.option("wav") {
        let wav: WAVFile
        do { wav = try WAVFile(path: path) } catch { fail("\(error)") }
        let printer = configure(POCSAGReceiver(audioRate: wav.sampleRate, bauds: bauds))
        var index = 0
        while index < wav.samples.count {
            let end = min(wav.samples.count, index + 48_000)
            printer.process(audio: Array(wav.samples[index..<end]))
            index = end
        }
        printer.summary()
        return
    }

    let rate = arguments.double("rate", default: 240_000)
    guard rate >= 48_000 else { fail("--rate must be at least 48000") }
    if let path = arguments.option("ifile") {
        guard let file = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
        let printer = configure(POCSAGReceiver(sampleRate: rate, offsetHz: arguments.double("offset", default: 0),
                                               channelCutoffHz: arguments.double("cutoff", default: 8_500),
                                               searchesForCarrier: arguments.flag("search"), bauds: bauds))
        while true {
            let chunk = file.readData(ofLength: 1 << 18)
            if chunk.isEmpty { break }
            printer.process(iq: [UInt8](chunk))
        }
        printer.summary()
        return
    }

    // Live: tune 40 kHz below the channel so that it is clear of the dongle's DC spike.
    let frequency = arguments.int("freq", default: 0)
    guard (24_000_000...1_700_000_000).contains(frequency) else { fail("--freq is the paging channel's frequency (e.g. --freq 152.84e6)") }
    let seconds = arguments.double("seconds", default: 1e9)
    let printer = configure(POCSAGReceiver(sampleRate: rate, offsetHz: 40_000, channelCutoffHz: arguments.double("cutoff", default: 8_500),
                                           searchesForCarrier: arguments.flag("search"), bauds: bauds))
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        _ = try device.setSampleRate(Int(rate))
        try arguments.applyFrequencyCorrection(to: device)
        try device.setCenterFrequency(frequency - 40_000)
        try arguments.applyGain(to: device, default: "auto")
        let backlog = Backlog(label: "pager-input")
        let failure = FailureBox()
        try device.startStreaming(onError: { failure.set($0) }) { block in
            backlog.submit(block) { printer.process(iq: $0) }
        }
        print("listening on \(megahertz(Double(frequency))) for POCSAG at \(bauds.map { String(Int($0)) }.joined(separator: ", ")) bit/s; Ctrl-C to stop")
        let started = monotonicSeconds()
        while monotonicSeconds() - started < seconds, failure.value == nil {
            Thread.sleep(forTimeInterval: 0.5)
            let dropped = backlog.newlyDropped()
            if dropped > 0 { FileHandle.standardError.write(Data("warning: decoding fell behind; dropped \(dropped) block(s)\n".utf8)) }
        }
        device.stopStreaming()
        backlog.sync {}
        printer.summary()
        if let error = failure.value { fail(error.localizedDescription) }
    } catch { fail(error.localizedDescription) }
}
