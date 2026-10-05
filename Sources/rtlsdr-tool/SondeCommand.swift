// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRDecoders
import RTLSDRKit
import RTLSDRScan

/// A mono channel of a PCM WAV file (8-bit unsigned, 16-bit signed or 32-bit float; the first channel if several).
struct WAVFile {
    let sampleRate: Double
    let samples: [Float]

    init(path: String) throws {
        struct Invalid: Error, CustomStringConvertible { let description: String }
        let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard data.count >= 12, data[0..<4].elementsEqual("RIFF".utf8), data[8..<12].elementsEqual("WAVE".utf8) else {
            throw Invalid(description: "\(path) is not a WAV file")
        }
        var format = 0, channels = 0, rate = 0, bits = 0
        var position = 12
        var samples: [Float]?
        while position + 8 <= data.count {
            let size = u32(position + 4), body = position + 8
            let end = min(data.count, body + size)
            if data[position..<(position + 4)].elementsEqual("fmt ".utf8), size >= 16 {
                format = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
            } else if data[position..<(position + 4)].elementsEqual("data".utf8) {
                guard channels > 0, [1, 3].contains(format) else { throw Invalid(description: "\(path): only PCM or float WAV files") }
                let width = bits / 8, frame = width * channels
                guard [1, 2, 4].contains(width), !(format == 3 && width != 4) else { throw Invalid(description: "\(path): \(bits)-bit samples are not supported") }
                var out: [Float] = []
                out.reserveCapacity((end - body) / frame)
                var at = body
                while at + frame <= end {
                    switch (format, width) {
                    case (_, 1): out.append(Float(Int(data[at]) - 128))
                    case (_, 2): out.append(Float(Int16(bitPattern: UInt16(u16(at)))))
                    case (3, _): out.append(Float(bitPattern: UInt32(u32(at))))
                    default: out.append(Float(Int32(bitPattern: UInt32(u32(at)))) / 65_536)
                    }
                    at += frame
                }
                samples = out
            }
            position = body + size + (size & 1)
        }
        guard let samples, rate > 0 else { throw Invalid(description: "\(path) has no audio") }
        sampleRate = Double(rate)
        self.samples = samples
    }
}

/// Prints radiosonde reports: rs41mod's JSON lines with `--json`, otherwise one readable line each.
private final class SondePrinter: @unchecked Sendable {
    let receiver: RS41Receiver
    let sampleRate: Double
    let json: Bool
    let verbose: Bool
    private(set) var frames = 0, repaired = 0, reports = 0

    init(receiver: RS41Receiver, sampleRate: Double, json: Bool, verbose: Bool) {
        self.receiver = receiver
        self.sampleRate = sampleRate
        self.json = json
        self.verbose = verbose
    }

    func print(_ events: [RS41Event]) {
        for event in events {
            frames += 1
            if event.frame.corrected != nil { repaired += 1 }
            if let report = event.report {
                reports += 1
                var text = json ? report.json() : report.line
                if !json, let offset = event.frequencyOffsetHz { text += String(format: "  (%+.1f kHz)", offset / 1000) }
                Swift.print(text)
            } else if verbose {
                let damaged = event.frame.blocks.filter { !$0.value.valid }.map { String(format: "%02X", $0.key) }.sorted()
                Swift.print(String(format: "frame at %.2f s: Reed-Solomon %@, blocks with bad CRC: %@", event.sampleIndex / sampleRate,
                                   event.frame.corrected.map { "fixed \($0)" } ?? "failed", damaged.joined(separator: " ")))
            }
        }
    }

    func summary() {
        FileHandle.standardError.write(Data("frames: \(frames), error-corrected: \(repaired), reports: \(reports), headers without a frame: \(receiver.rejectedHeaders)\n".utf8))
    }
}

/// The scan loop's RS41 decoder: listens beside each narrow signal in 400-406 MHz for a few seconds. One `RS41Decoder`
/// serves every dwell, so a sonde's calibration keeps filling from one visit to the next.
private final class RS41ScanDecoder: SignalDecoder {
    let name = "RS41"
    let dwellSeconds: Double
    let json: Bool
    let shared = RS41Decoder()

    init(dwellSeconds: Double, json: Bool) {
        self.dwellSeconds = dwellSeconds
        self.json = json
    }

    func wants(_ detection: Detection) -> Bool {
        RS41.frequencyRange.contains(Int(detection.frequencyHz.rounded())) && detection.bandwidthHz < 40_000
    }

    func decode(_ dwell: Dwell) -> [DecodedMessage] {
        let receiver = RS41Receiver(sampleRate: dwell.sampleRate, offsetHz: dwell.signalOffsetHz, decoder: shared)
        return receiver.process(iq: dwell.samples).compactMap { event in
            event.report.map { report in
                DecodedMessage(decoder: name, frequencyHz: Double(dwell.tunedHz) + (event.frequencyOffsetHz ?? dwell.signalOffsetHz),
                               text: json ? report.json() : report.line)
            }
        }
    }
}

/// `sonde --scan`: sweeps the band for signals and dwells on each with the RS41 decoder, as radiosonde_auto_rx does
/// (without its continuous tracking once a sonde is found: every sonde is revisited each round).
private func scanForSondes(_ arguments: Arguments, json: Bool, verbose: Bool) {
    let from = Int(arguments.double("from", default: 400_000_000)), to = Int(arguments.double("to", default: 406_000_000))
    guard from < to else { fail("--from must be below --to") }
    let seconds = arguments.double("seconds", default: 1e9)
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        try device.setSampleRate(arguments.int("rate", default: 2_400_000))
        try arguments.applyFrequencyCorrection(to: device)
        try arguments.applyGain(to: device, default: "40.2")      // fixed, so that the hops of a sweep compare
        var configuration = BandScanner.Configuration(range: from...to)
        configuration.detector.thresholdDB = arguments.double("threshold", default: 8)
        let scanner = try BandScanner(receiver: device, configuration: configuration)
        let decoder = RS41ScanDecoder(dwellSeconds: arguments.double("dwell", default: 3), json: json)
        let loop = ScanLoop(scanner: scanner, decoders: [decoder])
        print("scanning \(megahertz(Double(from)))-\(megahertz(Double(to))) for RS41 radiosondes; Ctrl-C to stop")
        let started = monotonicSeconds()
        while monotonicSeconds() - started < seconds {
            let round = try loop.runRound()
            if verbose {
                FileHandle.standardError.write(Data("round \(round.number): \(round.detections.count) signal(s), \(round.dwells.count) dwell(s)\n".utf8))
            }
            for dwell in round.dwells {
                for message in dwell.messages { print(json ? message.text : "\(megahertz(message.frequencyHz))  \(message.text)") }
                if verbose && dwell.messages.isEmpty {
                    FileHandle.standardError.write(Data("  \(megahertz(dwell.detection.frequencyHz)): no RS41\n".utf8))
                }
            }
        }
    } catch { fail(error.localizedDescription) }
}

/// `sonde`: Vaisala RS41 radiosondes (400-406 MHz), from the dongle, a recording of u8 I/Q, or FM audio in a WAV file.
func sonde(_ arguments: Arguments) {
    let json = arguments.flag("json"), verbose = arguments.flag("verbose")
    if arguments.flag("scan") { scanForSondes(arguments, json: json, verbose: verbose); return }

    if let path = arguments.option("wav") {
        let wav: WAVFile
        do { wav = try WAVFile(path: path) } catch { fail("\(error)") }
        let printer = SondePrinter(receiver: RS41Receiver(audioRate: wav.sampleRate), sampleRate: wav.sampleRate, json: json, verbose: verbose)
        var index = 0
        while index < wav.samples.count {
            let end = min(wav.samples.count, index + 48_000)
            printer.print(printer.receiver.process(audio: Array(wav.samples[index..<end])))
            index = end
        }
        printer.summary()
        return
    }

    let rate = arguments.double("rate", default: 240_000)
    guard rate >= 48_000 else { fail("--rate must be at least 48000") }
    if let path = arguments.option("ifile") {
        guard let file = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
        let receiver = RS41Receiver(sampleRate: rate, offsetHz: arguments.double("offset", default: 0),
                                    channelCutoffHz: arguments.double("cutoff", default: 3_700))
        let printer = SondePrinter(receiver: receiver, sampleRate: rate, json: json, verbose: verbose)
        while true {
            let chunk = file.readData(ofLength: 1 << 18)
            if chunk.isEmpty { break }
            printer.print(receiver.process(iq: [UInt8](chunk)))
        }
        printer.summary()
        return
    }

    // Live: tune 40 kHz below the sonde so that it is clear of the dongle's DC spike.
    let frequency = arguments.int("freq", default: 0)
    guard RS41.frequencyRange.contains(frequency) else { fail("--freq is the sonde's frequency, 400e6 to 406e6 (e.g. --freq 403.5e6)") }
    let seconds = arguments.double("seconds", default: 1e9)
    let receiver = RS41Receiver(sampleRate: rate, offsetHz: 40_000)
    let printer = SondePrinter(receiver: receiver, sampleRate: rate, json: json, verbose: verbose)
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        _ = try device.setSampleRate(Int(rate))
        try arguments.applyFrequencyCorrection(to: device)
        try device.setCenterFrequency(frequency - 40_000)
        try arguments.applyGain(to: device, default: "auto")
        let backlog = Backlog(label: "sonde-input")
        let failure = FailureBox()
        try device.startStreaming(onError: { failure.set($0) }) { block in
            backlog.submit(block) { printer.print(printer.receiver.process(iq: $0)) }
        }
        print("listening on \(megahertz(Double(frequency))) (RS41, 4800 bit/s GFSK); Ctrl-C to stop")
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
