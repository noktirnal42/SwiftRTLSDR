// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRKit
import RTLSDRScan

private func describe(_ record: CalibrationRecord) -> String {
    var lines = [String(format: "  correction   %+.3f ppm (%d ppb)", record.ppm, record.partsPerBillion)]
    if let date = record.measured { lines.append("  measured     \(ISO8601DateFormatter().string(from: date))") }
    if let hz = record.referenceHz { lines.append("  reference    \(megahertz(Double(hz)))") }
    if let method = record.method { lines.append("  method       \(method == .knownCarrier ? "known carrier" : "entered by hand")") }
    if let label = record.label { lines.append("  label        \(label)") }
    return lines.joined(separator: "\n")
}

/// Writes `record` (nil clears it) to the dongle's EEPROM after a backup; a dry run unless `--write`.
private func store(_ record: CalibrationRecord?, _ arguments: Arguments, device: RTLSDRDevice) throws {
    let current = try device.readEEPROM()
    let updated = try current.replacingCalibration(record)
    let changes = updated.differences(from: current)
    guard !changes.isEmpty else { print("the EEPROM already holds this"); return }
    print("\(changes.count) byte(s) of the EEPROM's unused second half change (offsets 0x\(String(changes.first!, radix: 16))-0x\(String(changes.last!, radix: 16)))")
    guard arguments.flag("write") else {
        print("dry run: nothing written. Add --write to store it (on a dongle you can afford to lose, the first time).")
        return
    }
    let serial = (try? current.strings().serial) ?? "unknown"
    let backup = arguments.option("backup") ?? "eeprom-backup-\(serial)-\(Int(Date().timeIntervalSince1970)).bin"
    try Data(current.bytes).write(to: URL(fileURLWithPath: backup))
    print("backup of the old contents: \(backup)")
    try device.writeCalibration(record)
    print("written and read back. Use --ppm eeprom with any command to apply it.")
}

/// `calibrate`: measure the dongle's crystal error on a known carrier, and keep it on the dongle.
func calibrate(_ arguments: Arguments) {
    do {
        if arguments.flag("show") {
            let device = try arguments.openDevice()
            defer { device.close() }
            switch try device.readEEPROM().calibrationArea {
            case .unused: print("no calibration stored (offsets 0x80-0xff unused)")
            case .record(let record): print("stored calibration:\n\(describe(record))")
            case .damagedRecord: print("a damaged calibration record (a write cut short?): clear it, or store a new one")
            case .foreign: print("offsets 0x80-0xff hold data this driver does not recognise; it will not write there")
            }
            return
        }
        if arguments.flag("clear") {
            let device = try arguments.openDevice()
            defer { device.close() }
            try store(nil, arguments, device: device)
            return
        }
        if let text = arguments.option("set-ppm") {
            guard let ppm = Double(text), abs(ppm) < 489 else { fail("--set-ppm needs a number of ppm (within ±488)") }
            let record = CalibrationRecord(partsPerBillion: Int((ppm * 1000).rounded()), measured: Date(), method: .entered,
                                           label: arguments.option("label"))
            _ = try record.encoded()                             // fits? (before touching the dongle)
            print("to store:\n\(describe(record))")
            let device = try arguments.openDevice()
            defer { device.close() }
            try store(record, arguments, device: device)
            return
        }

        // Measure.
        let carrier: Double
        if let channel = arguments.option("atsc") {
            guard let number = Int(channel), let hz = CarrierCalibrator.atscPilotHz(channel: number) else {
                fail("--atsc is a US television channel, 2 to 36")
            }
            carrier = hz
            print("ATSC pilot: stations may sit up to about a kilohertz off the nominal frequency; measure two and compare")
        } else {
            guard arguments.option("freq") != nil else {
                fail("usage: rtlsdr-tool calibrate --freq <known carrier Hz> | --atsc CHANNEL [--seconds 10] [--write [--label TEXT]]\n"
                     + "       rtlsdr-tool calibrate --show | --set-ppm N [--write] | --clear [--write]")
            }
            carrier = arguments.double("freq", default: 0)
        }
        let rate = arguments.double("rate", default: 1_024_000)
        let tuned = arguments.option("tuned").map { _ in arguments.double("tuned", default: 0) } ?? (carrier - rate / 4)
        let seconds = arguments.double("seconds", default: 10)
        let searchPPM = arguments.double("search", default: 150)
        guard let calibrator = CarrierCalibrator(sampleRate: rate, tunedHz: tuned, carrierHz: carrier, searchPPM: searchPPM) else {
            fail("cannot measure with these settings")
        }
        print("carrier \(megahertz(carrier)), tuned \(megahertz(tuned)) at \(Int(rate)) S/s, \(String(format: "%.1f", calibrator.binHz)) Hz bins, "
              + "searching ±\(Int(searchPPM)) ppm")
        var device: RTLSDRDevice?
        if let path = arguments.option("ifile") {
            guard let file = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
            while true {
                let chunk = file.readData(ofLength: 1 << 20)
                if chunk.isEmpty { break }
                calibrator.process(iq: [UInt8](chunk))
            }
        } else {
            let opened = try arguments.openDevice()
            device = opened
            _ = try opened.setSampleRate(Int(rate))
            try opened.setFrequencyCorrection(ppm: 0)               // measure the crystal as it is
            try opened.setCenterFrequency(Int(tuned.rounded()))
            try arguments.applyGain(to: opened, default: "auto")
            _ = try opened.readSamples(byteCount: Int(rate / 4) * 2)   // let the oscillator settle
            // Each read restarts the stream, so each holds whole transforms (about a second's worth): none straddles a gap.
            let transformBytes = 2 * calibrator.fftSize
            let perRead = max(1, Int((rate / Double(calibrator.fftSize)).rounded()))
            let reads = max(1, Int((seconds * rate / Double(calibrator.fftSize * perRead)).rounded()))
            for read in 1...reads {
                calibrator.process(iq: try opened.readSamples(byteCount: perRead * transformBytes))
                calibrator.discardPartialTransform()
                if let m = calibrator.measurement() {
                    print(String(format: "  %4.1f s  %+9.2f ppm  line %5.1f dB", Double(read * perRead * calibrator.fftSize) / rate, m.ppm, m.snrDB))
                }
            }
        }
        defer { device?.close() }
        guard let m = calibrator.measurement() else { fail("not enough samples for one transform (\(calibrator.binHz) Hz bins)") }
        print(String(format: "line at %+.1f Hz from the tuned frequency, %.1f dB over the floor, %.1f Hz wide", m.offsetHz, m.snrDB, m.widthHz))
        print(String(format: "crystal error: %+.3f ppm (use --ppm %d)", m.ppm, Int(m.ppm.rounded())))
        if m.snrDB < 15 { print("warning: the line hardly stands out; is the carrier there, and inside ±\(Int(searchPPM)) ppm?") }
        if m.widthHz > 6 * m.binHz { print("warning: the line is wide: a modulated or drifting signal gives a poor reference") }
        guard let device else {
            if arguments.flag("write") { print("not stored: --write needs the dongle itself (a measurement from a recording is not kept)") }
            return
        }
        guard arguments.flag("write") else { print("to keep it on the dongle: add --write (and --label TEXT)"); return }
        let record = CalibrationRecord(partsPerBillion: Int((m.ppm * 1000).rounded()), measured: Date(),
                                       referenceHz: UInt64(carrier.rounded()), method: .knownCarrier, label: arguments.option("label"))
        try store(record, arguments, device: device)
    } catch { fail(error.localizedDescription) }
}
