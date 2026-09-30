// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRDecoders
import RTLSDRKit
import RTLSDRScan
import RTLSDRServer

/// One Meteor-M reception: demodulator, decoder and what a dashboard shows. All decoding happens on `queue`.
private final class MeteorSession: @unchecked Sendable {
    let queue = DispatchQueue(label: "meteor")
    let mode: LRPT.Mode
    let decoder: LRPTDecoder
    let demodulator: LRPTDemodulator?
    let sampleRate: Double
    let symbolRate: Double
    let frequency: Int
    let source: String
    private let spectrum = SpectrumEstimator(fftSize: 256)
    private var spectrumDB: [Double] = []
    private var levelDBFS = -100.0
    private var ribbon: [Int] = []
    private(set) var streamSeconds = 0.0
    private var caduFile: FileHandle?
    private var softFile: FileHandle?

    init(mode: LRPT.Mode, sampleRate: Double, symbolRate: Double, frequency: Int, iq: Bool, source: String, cadu: String?,
         writeSoft: String?) {
        self.mode = mode
        self.sampleRate = sampleRate
        self.symbolRate = symbolRate
        self.frequency = frequency
        self.source = source
        decoder = LRPTDecoder(mode: mode)
        demodulator = iq ? LRPTDemodulator(sampleRate: sampleRate, symbolRate: symbolRate, offset: mode.isOffset) : nil
        if let cadu {
            _ = FileManager.default.createFile(atPath: cadu, contents: nil)
            caduFile = FileHandle(forWritingAtPath: cadu)
            if caduFile == nil { fail("cannot write \(cadu)") }
        }
        if let writeSoft {
            _ = FileManager.default.createFile(atPath: writeSoft, contents: nil)
            softFile = FileHandle(forWritingAtPath: writeSoft)
            if softFile == nil { fail("cannot write \(writeSoft)") }
        }
        decoder.onFrame = { [unowned self] frame in
            if frame.isValid { caduFile?.write(Data(frame.bytes)) }
            ribbon.append(frame.corrected.map { $0 > 0 ? 2 : 1 } ?? 0)
            if ribbon.count > 4000 { ribbon.removeFirst(ribbon.count - 4000) }      // no dashboard collecting them
        }
    }

    /// Call on `queue`.
    func feedIQ(_ block: [UInt8]) {
        guard let demodulator else { return }
        if let power = spectrum?.averagePower(Array(block.prefix(256 * 2 * 8))) {
            let db = power.map { 10 * log10(max($0, 1e-12)) }
            spectrumDB = spectrumDB.count == db.count ? zip(spectrumDB, db).map { 0.7 * $0 + 0.3 * $1 } : db
        }
        var sum = 0.0
        var index = 0
        while index + 1 < block.count {
            let i = Double(block[index]) - 127.5, q = Double(block[index + 1]) - 127.5
            sum += i * i + q * q
            index += 2
        }
        levelDBFS = 10 * log10(max(sum / Double(max(1, block.count / 2)), 1e-9) / (127.5 * 127.5))
        let soft = demodulator.process(block)
        softFile?.write(Data(soft.map { UInt8(bitPattern: $0) }))
        decoder.process(soft: soft)
        streamSeconds += Double(block.count / 2) / sampleRate
    }

    /// Call on `queue`.
    func feedSoft(_ soft: [Int8]) {
        decoder.process(soft: soft)
        streamSeconds += Double(soft.count / 2) / symbolRate
    }

    /// The dashboard's telemetry, as JSON. Call on `queue`.
    func telemetry() -> String {
        let statistics = decoder.statistics
        let status = demodulator?.status
        let constellation: [Int] = (demodulator?.recentSymbols ?? []).suffix(400).flatMap {
            [Int(max(-127, min(127, $0.0 / 2))), Int(max(-127, min(127, $0.1 / 2)))]
        }
        let imager = decoder.imager
        let channels = imager.orderedChannels.map { ["apid": $0.apid, "lines": $0.lines, "started": $0.startedLines] }
        let apids = Set(imager.channels.keys)
        var object: [String: Any] = [
            "t": streamSeconds, "frequency": frequency, "sampleRate": sampleRate, "source": source,
            "mode": (mode == .qpsk ? "QPSK " : "OQPSK ") + "\(Int(symbolRate / 1000))k" + (mode.isDifferential ? " NRZ-M" : ""),
            "nominalRate": symbolRate,
            "carrier": status?.carrierOffsetHz ?? 0, "locked": status?.locked ?? true, "snr": status?.snrDB ?? 0,
            "gain": Double(status?.gain ?? 0), "symbolRate": status?.symbolRate ?? symbolRate, "level": levelDBFS,
            "constellation": constellation,
            "frames": ["total": statistics.frames, "valid": statistics.validFrames, "corrected": statistics.correctedSymbols,
                       "viterbi": statistics.viterbiMetric, "marker": statistics.markerScore, "counter": statistics.lastCounter],
            "ribbon": ribbon,
            "packets": Dictionary(uniqueKeysWithValues: statistics.packetsPerAPID.map { (String($0.key), $0.value) }),
            "packetsTotal": statistics.packets, "channels": channels, "height": imager.commonHeight,
        ]
        if !apids.isEmpty {
            // The channels meteor_decode's composite uses: red 66 or 68, green 65 or 67, blue 64 or 69.
            let red = [66, 68].first { apids.contains($0) }, green = [65, 67].first { apids.contains($0) }
            let blue = [64, 69].first { apids.contains($0) }
            let bands = [red, green, blue].map { $0.map { String($0 - 63) } ?? "–" }
            object["composite"] = ["name": "RGB " + bands.joined(), "apids": [red, green, blue].map { $0 ?? 0 }]
        }
        if let hz = status?.coarseCarrierHz, let db = status?.coarseStrengthDB { object["coarse"] = ["hz": hz, "db": db] }
        if let spacecraft = statistics.spacecraft.max(by: { $0.value < $1.value })?.key { object["spacecraft"] = spacecraft }
        if !spectrumDB.isEmpty { object["spectrum"] = ["bins": spectrumDB, "span": sampleRate] }
        ribbon.removeAll()
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Rows `from ..< to` of a channel (`apid`) or of the composite ("rgb"), as PNG. Call on `queue`.
    func strip(_ apid: String, from: Int, to: Int) -> [UInt8]? {
        let imager = decoder.imager
        let height = imager.commonHeight
        let start = max(0, min(from, height)), end = max(start, min(to, height))
        guard end > start else { return nil }
        let width = MSUMRChannel.width
        if apid == "rgb" {
            guard let image = imager.composite(height: end) else { return nil }
            let rows = Array(image.pixels[(start * width * 3)..<(end * width * 3)])
            return PNG.encode(width: width, height: end - start, channels: 3, pixels: rows)
        }
        guard let number = Int(apid), let image = imager.image(apid: number) else { return nil }
        let rows = Array(image.pixels[(start * width)..<(end * width)])
        return PNG.encode(width: width, height: end - start, channels: 1, pixels: rows)
    }

    func finish(directory: String) {
        decoder.flush()
        finishMeteor(decoder, directory: directory)
    }
}

/// Serves the dashboard for a session; the telemetry is pushed five times a second.
private final class MeteorDashboard: @unchecked Sendable {
    let server: HTTPServer
    private let session: MeteorSession
    private var timer: DispatchSourceTimer?

    init(session: MeteorSession, host: String, port: UInt16) throws {
        self.session = session
        server = try HTTPServer(host: host, port: port) { request in
            switch request.path {
            case "/", "/index.html": return .content(type: "text/html; charset=utf-8", body: Array(meteorPage.utf8))
            case "/events": return .eventStream
            case "/strip":
                let png = session.queue.sync {
                    session.strip(request.query["apid"] ?? "rgb", from: request.integer("from") ?? 0, to: request.integer("to") ?? 8)
                }
                return png.map { .content(type: "image/png", body: $0) } ?? .notFound
            case "/image":
                let png = session.queue.sync { session.strip(request.query["apid"] ?? "rgb", from: 0, to: Int.max / 2) }
                return png.map { .content(type: "image/png", body: $0) } ?? .notFound
            default: return .notFound
            }
        }
        server.start()
        // Sending happens off the decoding queue: a stalled browser may hold a send for its 2 s timeout.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "meteor-dashboard"))
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let telemetry = self.session.queue.sync { self.session.telemetry() }
            self.server.broadcast(event: "telemetry", data: telemetry)
        }
        timer.resume()
        self.timer = timer
    }
}

/// `meteor`: Meteor-M LRPT weather images on 137 MHz, from soft symbols, a recording of u8 I/Q, or the dongle, with an
/// optional live dashboard in the browser.
func meteor(_ arguments: Arguments) {
    let mode: LRPT.Mode
    switch arguments.option("mode") ?? "oqpsk" {
    case "qpsk": mode = .qpsk
    case "oqpsk": mode = .oqpskNRZM
    default: fail("--mode is qpsk (Meteor-M N2) or oqpsk (N2-3, N2-4, the default)")
    }
    let output = arguments.option("out") ?? "meteor"
    let frequency = arguments.int("freq", default: 137_900_000)
    let rate = arguments.double("rate", default: 288_000)
    // 72 ksym/s. (Meteor-M N2-3 and N2-4 sometimes send 80 ksym/s, interleaved, which is not decoded yet.)
    let symbolRate = Double(LRPT.symbolRate)
    guard rate >= 2 * symbolRate else { fail("--rate must be at least twice the symbol rate (\(Int(2 * symbolRate)))") }
    let softPath = arguments.option("soft")
    let iqPath = arguments.option("ifile")
    let source = softPath != nil ? "soft symbols" : iqPath != nil ? "recording" : "live"
    let session = MeteorSession(mode: mode, sampleRate: rate, symbolRate: symbolRate, frequency: frequency, iq: softPath == nil,
                                source: source, cadu: arguments.option("cadu"), writeSoft: arguments.option("write-soft"))

    var dashboard: MeteorDashboard?
    if let port = arguments.option("web") {
        guard let number = UInt16(port) else { fail("--web needs a port number") }
        let host = arguments.option("host") ?? "127.0.0.1"
        do {
            dashboard = try MeteorDashboard(session: session, host: host, port: number)
            print("dashboard: http://\(host):\(dashboard!.server.port)/")
        } catch { fail("cannot start the dashboard: \(error)") }
    }
    // With a dashboard, recordings play back at their own pace (or --speed times it) so the display is live.
    let speed = arguments.double("speed", default: dashboard != nil ? 1 : 0)

    if let path = softPath ?? iqPath {
        guard let file = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
        let started = monotonicSeconds()
        var lastReport = -10.0
        while true {
            let chunk = file.readData(ofLength: softPath != nil ? 1 << 14 : 1 << 16)
            if chunk.isEmpty { break }
            let seconds: Double = session.queue.sync {
                if softPath != nil { session.feedSoft(chunk.map { Int8(bitPattern: $0) }) } else { session.feedIQ([UInt8](chunk)) }
                return session.streamSeconds
            }
            if speed > 0 {
                let ahead = seconds / speed - (monotonicSeconds() - started)
                if ahead > 0 { Thread.sleep(forTimeInterval: ahead) }
            }
            if dashboard == nil && seconds - lastReport >= 5 {
                lastReport = seconds
                session.queue.sync { reportProgress(session, seconds) }
            }
        }
        session.queue.sync { session.finish(directory: output) }
        if dashboard != nil {
            print("recording finished; the dashboard stays up until Ctrl-C")
            while true { Thread.sleep(forTimeInterval: 3600) }
        }
        return
    }

    let seconds = arguments.double("seconds", default: 1e9)
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        _ = try device.setSampleRate(Int(rate))
        try device.setCenterFrequency(frequency)
        try arguments.applyGain(to: device, default: "40.2")
        let backlog = Backlog(label: "meteor-input")
        let failure = FailureBox()
        try device.startStreaming(onError: { failure.set($0) }) { block in
            backlog.submit(block) { copy in session.queue.sync { session.feedIQ(copy) } }
        }
        print("listening on \(megahertz(Double(frequency))) at \(Int(rate)) S/s (\(mode == .qpsk ? "QPSK" : "OQPSK, NRZ-M"), \(Int(symbolRate)) sym/s); Ctrl-C to stop")
        let started = monotonicSeconds()
        var lastReport = started
        while monotonicSeconds() - started < seconds, failure.value == nil {
            Thread.sleep(forTimeInterval: 0.5)
            let dropped = backlog.newlyDropped()
            if dropped > 0 { FileHandle.standardError.write(Data("warning: decoding fell behind; dropped \(dropped) block(s)\n".utf8)) }
            if dashboard == nil && monotonicSeconds() - lastReport >= 5 {
                lastReport = monotonicSeconds()
                session.queue.sync { reportProgress(session, session.streamSeconds) }
            }
        }
        device.stopStreaming()
        backlog.sync {}
        session.queue.sync { session.finish(directory: output) }
        if let error = failure.value { fail(error.localizedDescription) }
    } catch { fail(error.localizedDescription) }
}

private func reportProgress(_ session: MeteorSession, _ seconds: Double) {
    let statistics = session.decoder.statistics
    var line = String(format: "%7.1f s  ", seconds)
    if let status = session.demodulator?.status {
        line += String(format: "carrier %+6.0f Hz ", status.carrierOffsetHz) + (status.locked ? "locked   " : "searching")
        line += String(format: "  SNR %4.1f dB  ", status.snrDB)
    }
    line += "frames \(statistics.validFrames)/\(statistics.frames)  lines \(session.decoder.imager.commonHeight)"
    print(line)
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
