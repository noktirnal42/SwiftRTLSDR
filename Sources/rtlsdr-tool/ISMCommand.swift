// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRDecoders
import RTLSDRKit

/// Prints decoded sensor messages: rtl_433's JSON lines with `--json`, otherwise one readable line each.
private final class ISMPrinter: @unchecked Sendable {
    let receiver: ISMReceiver
    let json: Bool
    let analyze: Bool
    private let clock: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return formatter
    }()

    init(receiver: ISMReceiver, json: Bool, analyze: Bool) {
        self.receiver = receiver
        self.json = json
        self.analyze = analyze
        if analyze {
            receiver.onPackage = { pulses, isFSK, decoded in
                let pairs = pulses.pairs
                let widths = pairs.prefix(24).map { "\($0.pulse)/\($0.gap)" }.joined(separator: " ")
                FileHandle.standardError.write(Data("\(isFSK ? "FSK" : "OOK") package at sample \(pulses.offset): \(pairs.count) pulses, \(decoded) decoded; \(widths)\(pairs.count > 24 ? " ..." : "")\n".utf8))
            }
        }
    }

    func print(_ events: [ISMEvent], time: String) {
        for event in events {
            if json {
                Swift.print(event.report.json(time: time))
            } else {
                Swift.print("\(time)  \(event.report)")
            }
        }
    }

    /// Live reception: messages are stamped with the wall-clock time.
    func processLive(_ block: [UInt8]) {
        print(receiver.process(block), time: clock.string(from: Date()))
    }
}

/// `ism`: 433/868/915 MHz sensors and remotes (what rtl_433 does), from the dongle or from a recording of u8 I/Q.
func ism(_ arguments: Arguments) {
    let json = arguments.flag("json")
    var protocols: Set<Int>?
    if let list = arguments.option("protocols") {
        protocols = Set(list.split(separator: ",").compactMap { Int($0) })
    }
    let devices = ISMDevices.all.filter { protocols?.contains($0.protocolNumber) ?? true }
    if devices.isEmpty { fail("none of those protocols is ported; `rtlsdr-tool ism --list-protocols` lists them") }
    if let code = arguments.option("code") {
        // rtl_433's -y: decode a bit buffer given as text.
        for event in ISMReceiver.decode(code: code, devices: devices) { print(json ? event.report.json() : event.report.description) }
        return
    }
    if arguments.flag("list-protocols") {
        for device in ISMDevices.all { print(String(format: "%4d  ", device.protocolNumber) + device.name) }
        return
    }
    var fskDetector: FSKPulseDetector?
    switch arguments.option("fsk") {
    case "classic"?: fskDetector = .classic
    case "minmax"?: fskDetector = .minMax
    case nil: break
    default: fail("--fsk is classic or minmax")
    }
    // As in rtl_433, the FSK detector follows the tuned frequency (--freq), not the one in a file's name.
    let frequency = arguments.int("freq", default: 433_920_000)

    if let path = arguments.option("ifile") {
        let named = ISMFileName.parse(path)
        let rate = arguments.option("rate") != nil ? arguments.int("rate", default: 250_000) : (named.sampleRate ?? ISMReceiver.defaultSampleRate)
        guard rate > 0 else { fail("--rate must be positive") }
        let receiver = ISMReceiver(sampleRate: rate, frequency: frequency, devices: devices, fskDetector: fskDetector)
        let printer = ISMPrinter(receiver: receiver, json: json, analyze: arguments.flag("analyze"))
        if arguments.flag("codes") {
            // Every bit buffer a decoder was given, in rtl_433's -y notation, with the decoder's result.
            receiver.onBits = { protocolNumber, bits, result in print("codes\t[\(protocolNumber)]\(bits.codes.joined())\t\(result)") }
        }
        guard let file = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
        // rtl_433 reads 262144-byte buffers, notes the file position at the end of each (in single precision, and
        // counting a short last buffer as full once the file has ended) and stamps a message with that position less
        // the samples since its package started. The same arithmetic gives the same stamps.
        let bufferBytes = ISMReceiver.flushSamples * 2
        let secondsPerSample = Double(Float(1) / Float(rate))
        var blocks = 0
        var fed = 0
        func stamp(_ events: [ISMEvent], filePosition: Float) {
            for event in events {
                let seconds = Float(Double(filePosition) - Double(fed - event.sampleIndex) * secondsPerSample)
                printer.print([event], time: String(format: "@%fs", Double(seconds)))
            }
        }
        while true {
            let chunk = file.readData(ofLength: bufferBytes)
            if chunk.isEmpty { break }
            let position = (Float(blocks) * Float(bufferBytes) + Float(chunk.count)) / Float(rate) / 2
            blocks += 1
            let events = receiver.process([UInt8](chunk))
            fed += chunk.count / 2
            stamp(events, filePosition: position)
        }
        let events = receiver.flush()
        fed += ISMReceiver.flushSamples
        stamp(events, filePosition: (Float(blocks) + 1) * Float(bufferBytes) / Float(rate) / 2)
        if !json {
            FileHandle.standardError.write(Data("\(receiver.ookPackages) OOK and \(receiver.fskPackages) FSK package(s)\n".utf8))
        }
        return
    }

    let rate = arguments.int("rate", default: ISMReceiver.defaultSampleRate)
    let seconds = arguments.double("seconds", default: 1e9)
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        let actualRate = try device.setSampleRate(rate)
        try arguments.applyFrequencyCorrection(to: device)
        try device.setCenterFrequency(frequency)
        try arguments.applyGain(to: device, default: "auto")
        // Timings use the nominal rate, as rtl_433 does (the dongle's actual rate differs by a few parts per million).
        let receiver = ISMReceiver(sampleRate: rate, frequency: frequency, devices: devices, fskDetector: fskDetector)
        let printer = ISMPrinter(receiver: receiver, json: json, analyze: arguments.flag("analyze"))
        let backlog = Backlog(label: "ism")
        let failure = FailureBox()
        try device.startStreaming(onError: { failure.set($0) }) { block in
            backlog.submit(block) { printer.processLive($0) }
        }
        if !json { print("listening on \(megahertz(Double(frequency))) at \(Int(actualRate)) S/s; Ctrl-C to stop") }
        let started = monotonicSeconds()
        while monotonicSeconds() - started < seconds, failure.value == nil {
            Thread.sleep(forTimeInterval: 0.5)
            let dropped = backlog.newlyDropped()
            if dropped > 0 { FileHandle.standardError.write(Data("warning: decoding fell behind; dropped \(dropped) block(s)\n".utf8)) }
        }
        device.stopStreaming()
        backlog.sync {}
        if let error = failure.value { fail(error.localizedDescription) }
    } catch { fail(error.localizedDescription) }
}
