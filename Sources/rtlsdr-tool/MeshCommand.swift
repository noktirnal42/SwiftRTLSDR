// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRDecoders
import RTLSDRKit

/// Prints Meshtastic packets as they arrive, naming nodes once their node info has been heard.
final class MeshPrinter: @unchecked Sendable {
    /// What feeds it: one receiver, or several listeners on one capture.
    var receiver: LoRaReceiver?
    var multi: MeshtasticMultiReceiver?
    let decoder: MeshtasticDecoder
    let json: Bool
    let verbose: Bool
    let live: Bool
    let sampleRate: Double
    private(set) var frames = 0, badCRC = 0, decoded = 0, unreadable = 0
    private var shortNames: [UInt32: String] = [:]
    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(decoder: MeshtasticDecoder, sampleRate: Double, json: Bool, verbose: Bool, live: Bool) {
        self.decoder = decoder
        self.sampleRate = sampleRate
        self.json = json
        self.verbose = verbose
        self.live = live
    }

    func print(_ received: [LoRaFrame]) {
        for frame in received { print(frame, label: nil, seconds: frame.sampleIndex / sampleRate) }
    }

    /// A block of I/Q to whatever receiver this printer has, and what comes out of it printed.
    func ingest(iq block: [UInt8]) {
        if let receiver { print(receiver.process(iq: block)) }
        if let multi {
            for item in multi.process(iq: block) {
                print(item.frame, label: "[\(item.listener.preset.rawValue) \(megahertz(item.listener.frequencyHz))]", seconds: item.inputSample / sampleRate)
            }
        }
    }

    /// One frame, with the listener it came from (when several are listening) and where it is in the recording.
    func print(_ frame: LoRaFrame, label: String?, seconds: Double) {
        do {
            frames += 1
            let time = (live ? clock.string(from: Date()) : String(format: "%.3f s", seconds)) + (label.map { "  " + $0 } ?? "")
            guard frame.crcValid == true, let packet = decoder.decode(frame.payload) else {
                badCRC += frame.crcValid == false ? 1 : 0
                if verbose && !json {
                    Swift.print("\(time)  LoRa frame, \(frame.payload.count) bytes, " + (frame.crcValid == false ? "CRC failed" : "not Meshtastic"))
                }
                return
            }
            if packet.status == .decoded { decoded += 1 } else { unreadable += 1 }
            if case .nodeInfo(let user)? = packet.data?.content, let name = user.shortName, !name.isEmpty {
                shortNames[packet.header.from] = name
            }
            if json {
                var extra: [String: Any] = ["snr": (frame.snrDB * 10).rounded() / 10, "freq_offset_hz": frame.carrierOffsetHz.rounded()]
                if live { extra["time"] = ISO8601DateFormatter().string(from: Date()) } else { extra["time_s"] = seconds }
                if let name = shortNames[packet.header.from] { extra["from_short_name"] = name }
                if let label { extra["listener"] = label }
                Swift.print(packet.json(extra: extra))
            } else {
                let name = shortNames[packet.header.from].map { "\($0) " } ?? ""
                Swift.print(String(format: "%@  %5.1f dB  %+6.1f kHz  ", time, frame.snrDB, frame.carrierOffsetHz / 1000) + name + packet.line)
            }
        }
    }

    func summary() {
        FileHandle.standardError.write(Data(("LoRa frames: \(frames), CRC failed: \(badCRC), Meshtastic decoded: \(decoded), "
                                             + "unreadable (other channel or direct): \(unreadable)\n").utf8))
    }
}

/// The sample rate and channel offset for listening live to a preset: a whole multiple of the bandwidth that the
/// dongle supports, with the channel one bandwidth above the tuned frequency (clear of the DC spike, and of the band
/// edge with the channel filter's ±0.7 bandwidths).
func meshLiveRate(bandwidth: Double) -> (rate: Double, offset: Double) {
    switch bandwidth {
    case ..<100_000: return (4 * bandwidth, bandwidth)            // 62.5 kHz: 250 kS/s
    case ..<400_000: return (1_000_000, bandwidth)                // 125 and 250 kHz: 1 MS/s
    default: return (4 * bandwidth, bandwidth)                    // 500 kHz: 2 MS/s
    }
}

/// A channel from `--primary` or `--channel`: NAME[:KEY], the key base64 as the apps show it, "default" or "none"; left out,
/// the default key; an empty name is `fallbackName`.
func meshChannel(_ spec: String, option: String, fallbackName: String) -> MeshtasticChannel {
    let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    let name = parts[0].isEmpty ? fallbackName : parts[0]
    guard parts.count > 1 else { return MeshtasticChannel(name: name, psk: [1]) }
    switch parts[1].lowercased() {
    case "default": return MeshtasticChannel(name: name, psk: [1])
    case "none": return MeshtasticChannel(name: name, psk: [0])
    default:
        guard let key = Data(base64Encoded: parts[1]), [1, 16, 32].contains(key.count) else {
            fail("--\(option) \(name): the key must be base64 of 1, 16 or 32 bytes (AQ== is the default key)")
        }
        return MeshtasticChannel(name: name, psk: [UInt8](key))
    }
}

/// `mesh --presets A,B,...`: several presets at once from one capture (each preset's default slot), or with `--all-slots`
/// every slot of the region the capture holds, for each preset. The capture is planned to hold every channel clear of the
/// dongle's DC spike (up to about 1.6 MHz at 2 MS/s). With `--ifile`, `--center` says where the recording was tuned.
private func meshMultiple(_ arguments: Arguments, region: MeshtasticRegion) {
    var presets: [MeshtasticPreset] = []
    for name in (arguments.option("presets") ?? "").split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
        guard let preset = MeshtasticPreset(name: name) else {
            fail("unknown preset \(name) in --presets; one of " + MeshtasticPreset.allCases.map(\.rawValue).joined(separator: ", "))
        }
        if !presets.contains(preset) { presets.append(preset) }
    }
    guard !presets.isEmpty else { fail("--presets needs preset names, e.g. --presets LongFast,MediumFast,ShortFast") }
    var channels = presets.map { MeshtasticChannel.primary($0) }
    if let spec = arguments.option("primary") { channels.append(meshChannel(spec, option: "primary", fallbackName: presets[0].rawValue)) }
    channels += arguments.options("channel").map { meshChannel($0, option: "channel", fallbackName: presets[0].rawValue) }
    let decoder = MeshtasticDecoder(channels: channels)
    let json = arguments.flag("json"), verbose = arguments.flag("verbose")

    // What to listen for, and the capture that holds it.
    var listeners: [MeshtasticListener] = []
    var capture: MeshtasticPlan.Capture
    let explicitCenter = arguments.option("center").map { _ in arguments.double("center", default: 0) }
    if arguments.flag("all-slots") {
        let rate = arguments.double("rate", default: 2_000_000)
        let first = presets[0].modulation.bandwidth
        let firstDefault = region.frequency(slot: region.defaultSlot(channelName: presets[0].rawValue, bandwidth: first), bandwidth: first)
        let center = explicitCenter ?? (firstDefault + first)
        let half = rate * MeshtasticPlan.usableShare / 2
        for preset in presets {
            let bandwidth = preset.modulation.bandwidth
            for frequency in MeshtasticPlan.slots(of: region, bandwidth: bandwidth, from: center - half, to: center + half)
            where abs(frequency - center) - bandwidth / 2 >= MeshtasticPlan.dcGuardHz {
                listeners.append(MeshtasticListener(preset: preset, frequencyHz: frequency))
            }
        }
        guard !listeners.isEmpty else { fail("no \(region.name) slot of those presets lies in the capture around \(megahertz(center)); try --center") }
        capture = MeshtasticPlan.Capture(centerHz: center, sampleRate: rate)
    } else {
        listeners = presets.map { preset in
            let bandwidth = preset.modulation.bandwidth
            guard region.slotCount(bandwidth: bandwidth) > 0 else { fail("\(preset.rawValue) (\(bandwidth / 1000) kHz) does not fit in \(region.name)") }
            return MeshtasticListener(preset: preset, frequencyHz: region.frequency(slot: region.defaultSlot(channelName: preset.rawValue, bandwidth: bandwidth), bandwidth: bandwidth))
        }
        do { capture = try MeshtasticPlan.capture(for: listeners) } catch {
            fail("\(error). Use fewer presets, or --all-slots with --center to listen to one window")
        }
        if let explicitCenter { capture.centerHz = explicitCenter }
        if let rate = arguments.option("rate").map({ _ in arguments.double("rate", default: 0) }) { capture.sampleRate = rate }
    }
    for listener in listeners {
        let ratio = capture.sampleRate / listener.bandwidth
        guard ratio >= 2, abs(ratio - ratio.rounded()) < 1e-6 else {
            fail("--rate must be a whole multiple of every bandwidth (\(listener.preset.rawValue) is \(listener.bandwidth / 1000) kHz); 1000000 and 2000000 suit them all")
        }
        guard abs(listener.frequencyHz - capture.centerHz) + listener.bandwidth / 2 <= capture.sampleRate / 2 else {
            fail("\(listener.preset.rawValue) on \(megahertz(listener.frequencyHz)) is outside the capture around \(megahertz(capture.centerHz))")
        }
    }
    let description = listeners.map { "\($0.preset.rawValue) " + megahertz($0.frequencyHz) }.joined(separator: ", ")
    let receiver: MeshtasticMultiReceiver
    do { receiver = try MeshtasticMultiReceiver(listeners: listeners, capture: capture) } catch { fail("\(error)") }

    if let path = arguments.option("ifile") {
        guard explicitCenter != nil else { fail("--ifile with --presets needs --center, the frequency the recording was tuned to (and --rate if it is not \(capture.sampleRate / 1e6) MS/s)") }
        guard let file = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
        let printer = MeshPrinter(decoder: decoder, sampleRate: capture.sampleRate, json: json, verbose: verbose, live: false)
        printer.multi = receiver
        if !json {
            FileHandle.standardError.write(Data("\(listeners.count) listener(s) on a capture at \(megahertz(capture.centerHz)), \(capture.sampleRate / 1e6) MS/s: \(description)\n".utf8))
        }
        while true {
            let chunk = file.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            printer.ingest(iq: [UInt8](chunk))
        }
        printer.summary()
        return
    }

    let seconds = arguments.double("seconds", default: 1e9)
    let printer = MeshPrinter(decoder: decoder, sampleRate: capture.sampleRate, json: json, verbose: verbose, live: true)
    printer.multi = receiver
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        _ = try device.setSampleRate(Int(capture.sampleRate))
        try arguments.applyFrequencyCorrection(to: device)
        try device.setCenterFrequency(Int(capture.centerHz.rounded()))
        try arguments.applyGain(to: device, default: "auto")
        let backlog = Backlog(label: "mesh-input")
        let failure = FailureBox()
        try device.startStreaming(onError: { failure.set($0) }) { block in
            backlog.submit(block) { printer.ingest(iq: $0) }
        }
        if !json { print("listening on a capture at \(megahertz(capture.centerHz)), \(capture.sampleRate / 1e6) MS/s, for \(description); Ctrl-C to stop") }
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

/// `mesh`: Meshtastic packets from the dongle or a recording, decrypted with the default and any given channel keys.
func mesh(_ arguments: Arguments) {
    let presetName = arguments.option("preset") ?? "LongFast"
    guard let preset = MeshtasticPreset(name: presetName) else {
        fail("unknown --preset \(presetName); one of " + MeshtasticPreset.allCases.map(\.rawValue).joined(separator: ", "))
    }
    let regionName = arguments.option("region") ?? "US"
    guard let region = MeshtasticRegion.named(regionName) else {
        fail("unknown --region \(regionName); one of " + MeshtasticRegion.all.map(\.name).joined(separator: ", "))
    }
    if arguments.option("presets") != nil { meshMultiple(arguments, region: region); return }
    // Channels as a node has them: the primary (--primary NAME[:KEY]; the preset's default channel if not given),
    // whose name picks the frequency slot, and secondaries (--channel NAME[:KEY], any number). KEY is base64 as the
    // apps show it, "default" or "none"; left out, the default key. The preset's default channel is always tried.
    func channel(_ spec: String, option: String) -> MeshtasticChannel { meshChannel(spec, option: option, fallbackName: preset.rawValue) }
    let primary = arguments.option("primary").map { channel($0, option: "primary") } ?? .primary(preset)
    var channels = [primary] + arguments.options("channel").map { channel($0, option: "channel") }
    if !channels.contains(where: { $0.name == preset.rawValue && $0.key == Meshtastic.defaultKey }) {
        channels.append(.primary(preset))
    }
    let bandwidth = preset.modulation.bandwidth
    let slots = region.slotCount(bandwidth: bandwidth)
    var slot = region.defaultSlot(channelName: primary.name, bandwidth: bandwidth)
    if let text = arguments.option("slot") {
        guard let number = Int(text), (1...max(1, slots)).contains(number) else { fail("--slot is 1 to \(slots) for \(region.name) \(preset.rawValue)") }
        slot = number - 1
    }
    let frequency = arguments.option("freq").map { _ in arguments.double("freq", default: 0) }
        ?? region.frequency(slot: slot, bandwidth: bandwidth)
    let decoder = MeshtasticDecoder(channels: channels)
    let json = arguments.flag("json"), verbose = arguments.flag("verbose")
    let m = preset.modulation
    let description = "\(preset.rawValue) (SF\(m.spreadingFactor), \(bandwidth / 1000) kHz, CR 4/\(4 + m.codingRate)) on "
        + megahertz(frequency) + " (\(region.name) slot \(slot + 1) of \(slots)); channels: "
        + channels.map { "\($0.name) [0x" + String(format: "%02x", $0.hash) + "]" }.joined(separator: ", ")

    if let path = arguments.option("ifile") {
        let rate = arguments.double("rate", default: 1_000_000)
        checkLoRaRate(rate, preset.parameters)
        let receiver = LoRaReceiver(parameters: preset.parameters, sampleRate: rate, offsetHz: arguments.double("offset", default: 0),
                                    centerFrequencyHz: frequency)
        let printer = MeshPrinter(decoder: decoder, sampleRate: rate, json: json, verbose: verbose, live: false)
        printer.receiver = receiver
        if !json { FileHandle.standardError.write(Data("\(description)\n".utf8)) }
        readLoRaFile(path, cf32: arguments.flag("cf32"), receiver: receiver) { printer.print($0) }
        printer.summary()
        return
    }

    let (defaultRate, defaultOffset) = meshLiveRate(bandwidth: bandwidth)
    let rate = arguments.double("rate", default: defaultRate)
    checkLoRaRate(rate, preset.parameters)
    let offset = arguments.double("offset", default: defaultOffset)
    let seconds = arguments.double("seconds", default: 1e9)
    let receiver = LoRaReceiver(parameters: preset.parameters, sampleRate: rate, offsetHz: offset, centerFrequencyHz: frequency)
    let printer = MeshPrinter(decoder: decoder, sampleRate: rate, json: json, verbose: verbose, live: true)
    printer.receiver = receiver
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        _ = try device.setSampleRate(Int(rate))
        try arguments.applyFrequencyCorrection(to: device)
        try device.setCenterFrequency(Int((frequency - offset).rounded()))
        try arguments.applyGain(to: device, default: "auto")
        let backlog = Backlog(label: "mesh-input")
        let failure = FailureBox()
        try device.startStreaming(onError: { failure.set($0) }) { block in
            backlog.submit(block) { printer.ingest(iq: $0) }
        }
        if !json { print("listening for Meshtastic \(description); Ctrl-C to stop") }
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
