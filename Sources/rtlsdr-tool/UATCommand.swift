// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRDecoders
import RTLSDRKit

/// Demodulates, prints UAT frames and collects NEXRAD blocks into mosaics. Used from one queue at a time.
private final class UATPrinter: @unchecked Sendable {
    private let demodulator = UATDemodulator()
    private let raw: Bool
    private let nexradDirectory: String?
    private var composites: [String: NEXRADComposite] = [:]
    private var written: [String: Int] = [:]          // blocks in a mosaic when it was last written

    init(raw: Bool, nexradDirectory: String?) {
        self.raw = raw
        self.nexradDirectory = nexradDirectory
    }

    func process(_ block: [UInt8]) {
        for frame in demodulator.process(block) { handle(frame) }
    }

    func handle(_ frame: UATFrame) {
        if raw { print(frame.dump978Line) }
        switch frame.kind {
        case .downlink:
            if !raw { print(describe(UATADSBMessage(payload: frame.payload))) }
        case .uplink:
            let uplink = UATUplinkMessage(payload: frame.payload)
            if !raw {
                print(String(format: "UPLINK  station %.4f %.4f  slot %d", uplink.latitude, uplink.longitude, uplink.slotID)
                      + (frame.correctedSymbols > 0 ? "  (\(frame.correctedSymbols) bytes repaired)" : ""))
            }
            for product in (uplink.informationFrames ?? []).compactMap(\.fisb) {
                let blocks = NEXRADBlock.blocks(in: product)
                for block in blocks {
                    let key = "\(block.product.rawValue.lowercased())-" + String(format: "%02d%02d", block.hours, block.minutes)
                    composites[key, default: NEXRADComposite(product: block.product, hours: block.hours, minutes: block.minutes)].add(block)
                }
                guard !raw else { continue }
                let time = String(format: "%02d:%02d", product.hours, product.minutes)
                if !blocks.isEmpty {
                    print("  FIS-B \(product.productName) \(time): \(blocks.count) block(s)")
                } else if product.productID == 413 {
                    for report in product.reports { print("  FIS-B \(time) " + report.replacingOccurrences(of: "\n", with: "\n      ")) }
                } else {
                    print("  FIS-B \(product.productName) \(time), \(product.payload.count) bytes")
                }
            }
        }
    }

    private func describe(_ message: UATADSBMessage) -> String {
        var text = "ADS-B   \(message.addressHex)"
        if let callsign = message.modeStatus?.callsign { text += message.modeStatus!.callsignIsSquawk ? "  squawk \(callsign)" : "  \(callsign)" }
        if let vector = message.stateVector {
            if let lat = vector.latitude, let lon = vector.longitude { text += String(format: "  %.4f %.4f", lat, lon) }
            if let altitude = vector.altitude { text += "  \(altitude.feet) ft" + (altitude.type == .geometric ? " (GNSS)" : "") }
            if let speed = vector.speedKnots { text += "  \(speed) kt" }
            if let track = vector.track { text += "  \(track.degrees)°" }
            if let rate = vector.verticalRate { text += "  \(rate.feetPerMinute) ft/min" }
            if vector.airGround == .onGround { text += "  on ground" }
        }
        if message.addressQualifier == .tisbICAO || message.addressQualifier == .tisbTrackFile { text += "  (TIS-B)" }
        return text
    }

    /// Writes each mosaic that gained blocks since it was last written: a PNG and a text file with its bounds.
    func writeMosaics() {
        guard let directory = nexradDirectory else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (key, composite) in composites where composite.blocks.count != written[key] {
            guard let image = composite.image(), let bounds = composite.bounds else { continue }
            let base = (directory as NSString).appendingPathComponent("nexrad-\(key)")
            do {
                try Data(image.png).write(to: URL(fileURLWithPath: base + ".png"))
                let info = String(format: "north %.4f\nsouth %.4f\nwest %.4f\neast %.4f\nblocks %d\nwidth %d\nheight %d\n",
                                  Double(bounds.north) / 60, Double(bounds.south) / 60, Double(bounds.west) / 60, Double(bounds.east) / 60,
                                  composite.blocks.count, image.width, image.height)
                try info.write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                written[key] = composite.blocks.count
                if !raw { print("wrote \(base).png (\(composite.blocks.count) blocks, \(image.width)x\(image.height))") }
            } catch {
                FileHandle.standardError.write(Data("cannot write \(base).png: \(error.localizedDescription)\n".utf8))
            }
        }
    }
}

/// `uat`: UAT on 978 MHz (US): aircraft ADS-B and ground-station FIS-B weather, from the dongle, from a file of u8 I/Q
/// recorded at 2.083334 MS/s, or from dump978's text output.
func uat(_ arguments: Arguments) {
    let printer = UATPrinter(raw: arguments.flag("raw"), nexradDirectory: arguments.option("nexrad"))

    if let path = arguments.option("frames") {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
        for line in text.split(separator: "\n") { if let frame = UATFrame(dump978Line: line) { printer.handle(frame) } }
        printer.writeMosaics()
        return
    }

    if let path = arguments.option("ifile") {
        guard let file = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
        while true {
            let chunk = file.readData(ofLength: 1 << 18)
            if chunk.isEmpty { break }
            printer.process([UInt8](chunk))
        }
        // The demodulator holds back one frame's worth of samples as look-ahead: flush it with silence.
        printer.process([UInt8](repeating: 128, count: 20_000))
        printer.writeMosaics()
        return
    }

    let seconds = arguments.double("seconds", default: 1e9)
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        try device.setSampleRate(UAT.sampleRate)
        try device.setCenterFrequency(Int(arguments.double("freq", default: Double(UAT.frequency))))
        try arguments.applyGain(to: device, default: "49.6")
        let queue = DispatchQueue(label: "uat")
        let failure = FailureBox()
        try device.startStreaming(onError: { failure.set($0) }) { block in
            let copy = Array(block)
            queue.async { printer.process(copy) }
        }
        if !arguments.flag("raw") { print("listening on 978 MHz; Ctrl-C to stop") }
        let started = monotonicSeconds()
        var lastWrite = started
        while monotonicSeconds() - started < seconds, failure.value == nil {
            Thread.sleep(forTimeInterval: 0.5)
            if monotonicSeconds() - lastWrite > 60 {
                lastWrite = monotonicSeconds()
                queue.async { printer.writeMosaics() }
            }
        }
        device.stopStreaming()
        queue.sync { printer.writeMosaics() }
        if let error = failure.value { fail(error.localizedDescription) }
    } catch { fail(error.localizedDescription) }
}
