// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRDecoders
import RTLSDRKit

private final class AISPrinter: @unchecked Sendable {
    enum Style { case line, json, nmea }
    let receiver: AISReceiver
    let style: Style
    let centerHz: Double?
    private(set) var frames = 0, messages = 0
    private var sequence = 0
    private let clock: DateFormatter

    init(receiver: AISReceiver, style: Style, centerHz: Double?) {
        self.receiver = receiver
        self.style = style
        self.centerHz = centerHz
        clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
    }

    private func print(_ events: [AISEvent]) {
        for event in events {
            frames += 1
            let packet = event.packet
            if packet.message != nil { messages += 1 }
            switch style {
            case .nmea:
                for sentence in packet.sentences(sequentialID: sequence) { Swift.print(sentence) }
                sequence += 1
            case .json:
                var frequency: Double?
                if let centerHz, let offset = event.frequencyOffsetHz { frequency = centerHz + offset }
                if let message = packet.message { Swift.print(message.json(channel: packet.channel, frequencyHz: frequency)) }
            case .line:
                var text = clock.string(from: Date()) + "  "
                if let channel = packet.channel { text += channel + "  " }
                text += packet.message?.line ?? "message of \(packet.bits.count) bits (\(packet.bits.unsigned(0, 6)))"
                Swift.print(text)
            }
        }
    }

    func process(iq: [UInt8]) { print((try? receiver.process(iq: iq)) ?? []) }
    func process(audio: [Float]) { print((try? receiver.process(audio: audio)) ?? []) }

    func summary() {
        FileHandle.standardError.write(Data("frames: \(frames), decoded messages: \(messages), headers without a frame: \(receiver.rejectedHeaders)\n".utf8))
    }
}

/// `ais`: ships' AIS on 161.975 MHz (A) and 162.025 MHz (B), from the dongle, a recording of u8 I/Q, or FM audio in a WAV file.
func ais(_ arguments: Arguments) {
    let style: AISPrinter.Style = arguments.flag("json") ? .json : arguments.flag("nmea") ? .nmea : .line
    let which = (arguments.option("channel") ?? "both").lowercased()
    guard ["a", "b", "both"].contains(which) else { fail("--channel is a, b or both") }
    // The capture is tuned between the channels (162.000 MHz): each is 25 kHz from the middle, clear of the DC spike.
    let centre = arguments.double("center", default: 162_000_000)
    var channels: [(offsetHz: Double, name: String?)] = []
    if which != "b" { channels.append((AIS.channelA - centre, "A")) }
    if which != "a" { channels.append((AIS.channelB - centre, "B")) }

    if let path = arguments.option("wav") {
        let wav: WAVFile
        do { wav = try WAVFile(path: path) } catch { fail("\(error)") }
        let printer = AISPrinter(receiver: AISReceiver(audioRate: wav.sampleRate, name: which == "both" ? nil : which.uppercased()), style: style, centerHz: nil)
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
    guard rate >= 150_000 else { fail("--rate must be at least 150000 (both channels are 50 kHz apart)") }
    let receiver = AISReceiver(sampleRate: rate, channels: channels, channelCutoffHz: arguments.double("cutoff", default: 8_000))
    let printer = AISPrinter(receiver: receiver, style: style, centerHz: centre)
    if let path = arguments.option("ifile") {
        guard let file = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
        while true {
            let chunk = file.readData(ofLength: 1 << 18)
            if chunk.isEmpty { break }
            printer.process(iq: [UInt8](chunk))
        }
        printer.summary()
        return
    }

    let seconds = arguments.double("seconds", default: 1e9)
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        _ = try device.setSampleRate(Int(rate))
        try arguments.applyFrequencyCorrection(to: device)
        try device.setCenterFrequency(Int(centre))
        try arguments.applyGain(to: device, default: "auto")
        let backlog = Backlog(label: "ais-input")
        let failure = FailureBox()
        try device.startStreaming(onError: { failure.set($0) }) { block in
            backlog.submit(block) { printer.process(iq: $0) }
        }
        FileHandle.standardError.write(Data("listening for AIS on \(megahertz(AIS.channelA)) and \(megahertz(AIS.channelB)); Ctrl-C to stop\n".utf8))
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
