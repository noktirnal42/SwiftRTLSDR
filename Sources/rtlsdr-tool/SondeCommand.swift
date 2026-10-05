// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRDecoders
import RTLSDRKit
import RTLSDRScan

/// A mono channel of a PCM WAV file (8-bit unsigned, 16-bit signed or 32-bit float; the first channel if several).
struct WAVFile {
    let sampleRate: Double
    /// Each channel's samples (acarsdec's test recording has one ACARS channel in each of four).
    let channels: [[Float]]
    /// The first channel.
    var samples: [Float] { channels[0] }
    /// What a full-scale sample reads (32768 for 16-bit files, 1 for float).
    let fullScale: Float

    init(path: String) throws {
        struct Invalid: Error, CustomStringConvertible { let description: String }
        let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard data.count >= 12, data[0..<4].elementsEqual("RIFF".utf8), data[8..<12].elementsEqual("WAVE".utf8) else {
            throw Invalid(description: "\(path) is not a WAV file")
        }
        var format = 0, channelCount = 0, rate = 0, bits = 0
        var position = 12
        var decoded: [[Float]]?
        while position + 8 <= data.count {
            let size = u32(position + 4), body = position + 8
            let end = min(data.count, body + size)
            if data[position..<(position + 4)].elementsEqual("fmt ".utf8), size >= 16 {
                format = u16(body); channelCount = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
                // WAVE_FORMAT_EXTENSIBLE (multichannel files): the format code opens the sub-format GUID.
                if format == 0xfffe && size >= 40 { format = u16(body + 24) }
            } else if data[position..<(position + 4)].elementsEqual("data".utf8) {
                guard channelCount > 0, [1, 3].contains(format) else { throw Invalid(description: "\(path): only PCM or float WAV files") }
                let width = bits / 8, frame = width * channelCount
                guard [1, 2, 4].contains(width), !(format == 3 && width != 4) else { throw Invalid(description: "\(path): \(bits)-bit samples are not supported") }
                var out = [[Float]](repeating: [], count: channelCount)
                for c in 0..<channelCount { out[c].reserveCapacity((end - body) / frame) }
                var at = body
                while at + frame <= end {
                    for c in 0..<channelCount {
                        let p = at + c * width
                        switch (format, width) {
                        case (_, 1): out[c].append(Float(Int(data[p]) - 128))
                        case (_, 2): out[c].append(Float(Int16(bitPattern: UInt16(u16(p)))))
                        case (3, _): out[c].append(Float(bitPattern: UInt32(u32(p))))
                        default: out[c].append(Float(Int32(bitPattern: UInt32(u32(p)))) / 65_536)
                        }
                    }
                    at += frame
                }
                decoded = out
            }
            position = body + size + (size & 1)
        }
        guard let decoded, rate > 0 else { throw Invalid(description: "\(path) has no audio") }
        sampleRate = Double(rate)
        channels = decoded
        fullScale = format == 3 ? 1 : bits == 8 ? 128 : bits == 32 ? 32_768 : 32_768
    }
}

/// One thing a sonde receiver has to say: a report if the frame completed one, otherwise (for `--verbose`) why not.
struct SondeOutput {
    var kind: String
    var json: String?
    var line: String?
    var note: String
    /// The frame came through the error correction (counted in the summary).
    var corrected: Bool
    var offsetHz: Double?
    var sampleIndex: Double
}

/// What the `sonde` command needs from a receiver of any sonde type.
protocol SondeReceiving: AnyObject {
    var kind: String { get }
    var rejectedHeaders: Int { get }
    func process(iq: [UInt8]) -> [SondeOutput]
    func process(audio: [Float]) -> [SondeOutput]
}

/// The sonde types the command knows, by `--type`.
enum SondeType: String, CaseIterable {
    case rs41, dfm

    var name: String { rawValue.uppercased() }
    var frequencyRange: ClosedRange<Int> {
        switch self {
        case .rs41: return RS41.frequencyRange
        case .dfm: return DFM.frequencyRange
        }
    }
    var description: String {
        switch self {
        case .rs41: return "RS41, 4800 bit/s GFSK"
        case .dfm: return "DFM-06/09/17, 2500 symbol/s Manchester FSK"
        }
    }
    /// How wide a signal this type makes, for the scan loop to know what it may dwell on.
    var maximumBandwidthHz: Double { 40_000 }

    /// A receiver for I/Q at `sampleRate`, the sonde `offsetHz` above the tuned frequency `tunedHz` (if known).
    func receiver(sampleRate: Double, offsetHz: Double, cutoffHz: Double?, tunedHz: Double?, shared: SondeSharedState,
                  json: Bool, options: SondeOptions = SondeOptions()) -> SondeReceiving {
        switch self {
        case .rs41:
            return RS41Adapter(RS41Receiver(sampleRate: sampleRate, offsetHz: offsetHz, channelCutoffHz: cutoffHz ?? 3_700,
                                            decoder: shared.rs41), json: json)
        case .dfm:
            let receiver = DFMReceiver(sampleRate: sampleRate, offsetHz: offsetHz, channelCutoffHz: cutoffHz ?? 4_500,
                                       deviationHz: options.deviationHz ?? DFMReceiver.defaultDeviationHz,
                                       useTones: !options.discriminator, decoder: shared.dfm)
            receiver.sync.repairTwoBitErrors = options.repair
            return DFMAdapter(receiver, tunedHz: tunedHz, json: json)
        }
    }

    /// A receiver for FM audio.
    func receiver(audioRate: Double, tunedHz: Double?, shared: SondeSharedState, json: Bool,
                  options: SondeOptions = SondeOptions()) -> SondeReceiving {
        switch self {
        case .rs41: return RS41Adapter(RS41Receiver(audioRate: audioRate, decoder: shared.rs41), json: json)
        case .dfm:
            let receiver = DFMReceiver(audioRate: audioRate, decoder: shared.dfm)
            receiver.sync.repairTwoBitErrors = options.repair
            return DFMAdapter(receiver, tunedHz: tunedHz, json: json)
        }
    }

    static func parse(_ text: String?) -> SondeType {
        guard let text else { return .rs41 }
        guard let type = SondeType(rawValue: text.lowercased()) else {
            fail("--type is one of \(allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return type
    }
}

/// Receiver settings from the command line.
struct SondeOptions {
    /// DFM: the tones' distance from the carrier for the tone detector (the sonde's deviation).
    var deviationHz: Double?
    /// DFM: read the signal through the FM discriminator instead of the tone detector.
    var discriminator = false
    /// DFM: replace a codeword with two bad bits by its likeliest neighbour (more frames, less trust).
    var repair = false

    init() {}
    init(_ arguments: Arguments) {
        deviationHz = arguments.option("deviation").flatMap { Double($0) }
        discriminator = arguments.flag("discriminator")
        repair = arguments.flag("repair")
    }
}

/// The decoders' state that outlives a receiver: each sonde's calibration and configuration keep filling from one dwell
/// to the next.
final class SondeSharedState: @unchecked Sendable {
    let rs41 = RS41Decoder()
    let dfm = DFMDecoder()
}

private final class RS41Adapter: SondeReceiving {
    let receiver: RS41Receiver
    let json: Bool
    let kind = "RS41"
    init(_ receiver: RS41Receiver, json: Bool) { self.receiver = receiver; self.json = json }
    var rejectedHeaders: Int { receiver.rejectedHeaders }
    func process(iq: [UInt8]) -> [SondeOutput] { convert(receiver.process(iq: iq)) }
    func process(audio: [Float]) -> [SondeOutput] { convert(receiver.process(audio: audio)) }

    private func convert(_ events: [RS41Event]) -> [SondeOutput] {
        events.map { event in
            let damaged = event.frame.blocks.filter { !$0.value.valid }.map { String(format: "%02X", $0.key) }.sorted()
            let note = "Reed-Solomon \(event.frame.corrected.map { "fixed \($0)" } ?? "failed"), blocks with bad CRC: \(damaged.joined(separator: " "))"
            return SondeOutput(kind: kind, json: event.report?.json(), line: event.report?.line, note: note,
                               corrected: event.frame.corrected != nil, offsetHz: event.frequencyOffsetHz,
                               sampleIndex: event.sampleIndex)
        }
    }
}

private final class DFMAdapter: SondeReceiving {
    let receiver: DFMReceiver
    let tunedHz: Double?
    let json: Bool
    let kind = "DFM"
    init(_ receiver: DFMReceiver, tunedHz: Double?, json: Bool) { self.receiver = receiver; self.tunedHz = tunedHz; self.json = json }
    var rejectedHeaders: Int { receiver.rejectedHeaders }
    func process(iq: [UInt8]) -> [SondeOutput] { convert(receiver.process(iq: iq)) }
    func process(audio: [Float]) -> [SondeOutput] { convert(receiver.process(audio: audio)) }

    private func convert(_ events: [DFMEvent]) -> [SondeOutput] {
        events.map { event in
            let frame = event.frame
            let blocks = ([frame.config] + frame.data).map { $0.isIntact ? "\($0.corrected) fixed" : "\($0.failed) bad" }
            let note = "blocks (config, data, data): \(blocks.joined(separator: ", "))" + (event.inverted ? ", inverted" : "")
            var frequencyKHz: Int?
            if let tunedHz { frequencyKHz = Int(((tunedHz + (event.frequencyOffsetHz ?? 0)) / 1000).rounded()) }
            return SondeOutput(kind: kind, json: event.report?.json(frequencyKHz: frequencyKHz), line: event.report?.line, note: note,
                               corrected: frame.config.corrected + frame.data[0].corrected + frame.data[1].corrected > 0,
                               offsetHz: event.frequencyOffsetHz, sampleIndex: event.sampleIndex)
        }
    }
}

/// Prints radiosonde reports: the decoders' JSON lines with `--json`, otherwise one readable line each.
private final class SondePrinter: @unchecked Sendable {
    let receivers: [SondeReceiving]
    let sampleRate: Double
    let json: Bool
    let verbose: Bool
    private(set) var frames = 0, repaired = 0, reports = 0

    init(receivers: [SondeReceiving], sampleRate: Double, json: Bool, verbose: Bool) {
        self.receivers = receivers
        self.sampleRate = sampleRate
        self.json = json
        self.verbose = verbose
    }

    func process(iq: [UInt8]) { for receiver in receivers { print(receiver.process(iq: iq)) } }
    func process(audio: [Float]) { for receiver in receivers { print(receiver.process(audio: audio)) } }

    private func print(_ outputs: [SondeOutput]) {
        for output in outputs {
            frames += 1
            if output.corrected { repaired += 1 }
            if let text = json ? output.json : output.line {
                reports += 1
                var line = text
                if !json, let offset = output.offsetHz { line += String(format: "  (%+.1f kHz)", offset / 1000) }
                Swift.print(line)
            } else if verbose {
                Swift.print(String(format: "%@ frame at %.2f s: %@", output.kind, output.sampleIndex / sampleRate, output.note))
            }
        }
    }

    func summary() {
        let rejected = receivers.map(\.rejectedHeaders).reduce(0, +)
        FileHandle.standardError.write(Data("frames: \(frames), error-corrected: \(repaired), reports: \(reports), headers without a frame: \(rejected)\n".utf8))
    }
}

/// The scan loop's decoder for one sonde type: listens beside each narrow signal in 400-406 MHz for a few seconds. The
/// shared state serves every dwell, so a sonde's calibration keeps filling from one visit to the next.
private final class SondeScanDecoder: SignalDecoder {
    let name: String
    let type: SondeType
    let dwellSeconds: Double
    let json: Bool
    let shared: SondeSharedState

    init(type: SondeType, dwellSeconds: Double, json: Bool, shared: SondeSharedState) {
        self.type = type
        name = type.name
        self.dwellSeconds = dwellSeconds
        self.json = json
        self.shared = shared
    }

    func wants(_ detection: Detection) -> Bool {
        type.frequencyRange.contains(Int(detection.frequencyHz.rounded())) && detection.bandwidthHz < type.maximumBandwidthHz
    }

    func decode(_ dwell: Dwell) -> [DecodedMessage] {
        let receiver = type.receiver(sampleRate: dwell.sampleRate, offsetHz: dwell.signalOffsetHz, cutoffHz: nil,
                                     tunedHz: Double(dwell.tunedHz), shared: shared, json: json)
        return receiver.process(iq: dwell.samples).compactMap { output in
            guard let text = json ? output.json : output.line else { return nil }
            return DecodedMessage(decoder: name, frequencyHz: Double(dwell.tunedHz) + (output.offsetHz ?? dwell.signalOffsetHz), text: text)
        }
    }
}

/// `sonde --scan`: sweeps the band for signals and dwells on each with the chosen decoders, as radiosonde_auto_rx does
/// (without its continuous tracking once a sonde is found: every sonde is revisited each round).
private func scanForSondes(_ arguments: Arguments, types: [SondeType], json: Bool, verbose: Bool) {
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
        let shared = SondeSharedState()
        let decoders = types.map { SondeScanDecoder(type: $0, dwellSeconds: arguments.double("dwell", default: 3), json: json, shared: shared) }
        let loop = ScanLoop(scanner: scanner, decoders: decoders)
        print("scanning \(megahertz(Double(from)))-\(megahertz(Double(to))) for \(types.map(\.name).joined(separator: ", ")) radiosondes; Ctrl-C to stop")
        let started = monotonicSeconds()
        while monotonicSeconds() - started < seconds {
            let round = try loop.runRound()
            if verbose {
                FileHandle.standardError.write(Data("round \(round.number): \(round.detections.count) signal(s), \(round.dwells.count) dwell(s)\n".utf8))
            }
            for dwell in round.dwells {
                for message in dwell.messages { print(json ? message.text : "\(megahertz(message.frequencyHz))  \(message.text)") }
                if verbose && dwell.messages.isEmpty {
                    FileHandle.standardError.write(Data("  \(megahertz(dwell.detection.frequencyHz)): no sonde decoded\n".utf8))
                }
            }
        }
    } catch { fail(error.localizedDescription) }
}

/// `sonde`: radiosondes (400-406 MHz) of the types in `--type` (RS41 by default), from the dongle, a recording of u8
/// I/Q, or FM audio in a WAV file.
func sonde(_ arguments: Arguments) {
    let json = arguments.flag("json"), verbose = arguments.flag("verbose")
    let typeText = arguments.option("type")
    if arguments.flag("scan") {
        // Scanning tries every type unless told which.
        let types = typeText.map { [SondeType.parse($0)] } ?? SondeType.allCases
        scanForSondes(arguments, types: types, json: json, verbose: verbose)
        return
    }
    let type = SondeType.parse(typeText)
    let shared = SondeSharedState()
    let taggedHz = arguments.option("freq").flatMap { Double($0) }
    let options = SondeOptions(arguments)

    if let path = arguments.option("wav") {
        let wav: WAVFile
        do { wav = try WAVFile(path: path) } catch { fail("\(error)") }
        let receiver = type.receiver(audioRate: wav.sampleRate, tunedHz: taggedHz, shared: shared, json: json, options: options)
        let printer = SondePrinter(receivers: [receiver], sampleRate: wav.sampleRate, json: json, verbose: verbose)
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
        let receiver = type.receiver(sampleRate: rate, offsetHz: arguments.double("offset", default: 0),
                                     cutoffHz: arguments.option("cutoff").flatMap { Double($0) }, tunedHz: taggedHz,
                                     shared: shared, json: json, options: options)
        let printer = SondePrinter(receivers: [receiver], sampleRate: rate, json: json, verbose: verbose)
        while true {
            let chunk = file.readData(ofLength: 1 << 18)
            if chunk.isEmpty { break }
            printer.process(iq: [UInt8](chunk))
        }
        printer.summary()
        return
    }

    // Live: tune 40 kHz below the sonde so that it is clear of the dongle's DC spike.
    let frequency = arguments.int("freq", default: 0)
    let range = type.frequencyRange
    guard range.contains(frequency) else {
        fail("--freq is the sonde's frequency, \(range.lowerBound / 1_000_000) to \(range.upperBound / 1_000_000) MHz (e.g. --freq 403.5e6)")
    }
    let seconds = arguments.double("seconds", default: 1e9)
    let receiver = type.receiver(sampleRate: rate, offsetHz: 40_000, cutoffHz: nil, tunedHz: Double(frequency - 40_000),
                                 shared: shared, json: json, options: options)
    let printer = SondePrinter(receivers: [receiver], sampleRate: rate, json: json, verbose: verbose)
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
            backlog.submit(block) { printer.process(iq: $0) }
        }
        print("listening on \(megahertz(Double(frequency))) (\(type.description)); Ctrl-C to stop")
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
