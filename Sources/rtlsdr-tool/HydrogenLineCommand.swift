// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRKit
import RTLSDRScan

/// Where the antenna points, for the LSR velocity column.
private struct Pointing {
    var rightAscension: Double?, declination: Double?
    var azimuth: Double?, elevation: Double?
    var latitude: Double, longitude: Double

    func lsrCorrection(at date: Date) -> Double? {
        var ra = rightAscension, dec = declination
        if ra == nil, let azimuth, let elevation {
            (ra, dec) = LSRCorrection.equatorial(azimuth: azimuth, elevation: elevation, date: date, latitude: latitude, longitude: longitude)
        }
        guard let ra, let dec else { return nil }
        return LSRCorrection.velocity(rightAscension: ra, declination: dec, date: date, latitude: latitude, longitude: longitude)
    }
}

private func writeSpectrum(_ spectrometer: SwitchedSpectrometer, centerHz: Double, smoothing: Int, lsr: Double?, to path: String) -> (hz: Double, ratio: Double)? {
    guard let ratio = spectrometer.ratio(smoothing: smoothing) else { return nil }
    let s = Double(max(1, spectrometer.signalTransforms)), r = Double(max(1, spectrometer.referenceTransforms))
    var lines = ["frequency_mhz,offset_khz,velocity_kms" + (lsr != nil ? ",vlsr_kms" : "") + ",signal_db,reference_db,ratio"]
    var peak: (hz: Double, ratio: Double)?
    let usable = Int(Double(spectrometer.fftSize) * 0.05)           // the outer 5% either side is the anti-alias roll-off
    for (k, offset) in spectrometer.binOffsets.enumerated() {
        let hz = centerHz + offset
        let velocity = HydrogenLine.radioVelocity(frequencyHz: hz)
        var line = String(format: "%.6f,%.3f,%.2f", hz / 1e6, offset / 1000, velocity)
        if let lsr { line += String(format: ",%.2f", velocity + lsr) }
        line += String(format: ",%.3f,%.3f,%.6f", 10 * log10(max(spectrometer.signal[k] / s, 1e-30)),
                       10 * log10(max(spectrometer.reference[k] / r, 1e-30)), ratio[k])
        lines.append(line)
        if k >= usable && k < spectrometer.fftSize - usable && ratio[k] > (peak?.ratio ?? -.infinity) { peak = (hz, ratio[k]) }
    }
    try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    return peak
}

/// `hline`: the 21 cm hydrogen line by frequency switching, integrated as long as asked and written as CSV. Needs a
/// dish (or horn) and a low-noise amplifier at 1420 MHz: the bare dongle does not see the line.
func hydrogenLine(_ arguments: Arguments) {
    let center = arguments.double("freq", default: HydrogenLine.restHz)
    let rate = arguments.double("rate", default: 2_400_000)
    let fftSize = arguments.int("fft", default: 1024)
    let referenceOffset = arguments.double("reference", default: 2_500_000)
    let dwell = arguments.double("switch", default: 1)
    let seconds = arguments.double("seconds", default: 600)
    let smoothing = max(1, arguments.int("smooth", default: 1))
    let csv = arguments.option("csv") ?? "hline.csv"
    guard let spectrometer = SwitchedSpectrometer(fftSize: fftSize, sampleRate: rate) else { fail("--fft must be a power of two") }
    guard dwell > 0.05 else { fail("--switch is the seconds spent in each tuning before switching (at least 0.05)") }
    var pointing: Pointing?
    if arguments.option("lat") != nil {
        pointing = Pointing(rightAscension: arguments.option("ra").flatMap(Double.init), declination: arguments.option("dec").flatMap(Double.init),
                            azimuth: arguments.option("az").flatMap(Double.init), elevation: arguments.option("el").flatMap(Double.init),
                            latitude: arguments.double("lat", default: 0), longitude: arguments.double("lon", default: 0))
        let p = pointing!
        let sky = p.rightAscension != nil && p.declination != nil, horizon = p.azimuth != nil && p.elevation != nil
        let partial = (p.rightAscension == nil) != (p.declination == nil) || (p.azimuth == nil) != (p.elevation == nil)
        if partial || (!sky && !horizon) {
            fail("for LSR velocities give --ra HOURS and --dec DEGREES, or --az and --el (degrees), with --lat and --lon")
        }
    }
    // When a recording was made (for its LSR velocities): --time (ISO 8601, UTC), else the file's modification time.
    var recorded: Date?
    if let path = arguments.option("ifile") {
        if let text = arguments.option("time") {
            guard let date = ISO8601DateFormatter().date(from: text) else { fail("--time is ISO 8601, e.g. 2026-10-05T21:30:00Z") }
            recorded = date
        } else if pointing != nil {
            recorded = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            if let recorded { print("LSR velocities for \(ISO8601DateFormatter().string(from: recorded)), the file's modification time (--time to say when it was recorded)") }
        }
    }
    let started = Date()

    func report(final: Bool) {
        let middle = started.addingTimeInterval(Date().timeIntervalSince(started) / 2)
        let lsr = pointing?.lsrCorrection(at: recorded ?? middle)
        guard let peak = writeSpectrum(spectrometer, centerHz: center, smoothing: smoothing, lsr: lsr, to: csv) else { return }
        let (on, off) = spectrometer.integratedSeconds
        let velocity = HydrogenLine.radioVelocity(frequencyHz: peak.hz)
        var line = String(format: "%6.0f s on, %6.0f s off   peak %+.4f at %.4f MHz, %+.1f km/s", on, off, peak.ratio, peak.hz / 1e6, velocity)
        if let lsr { line += String(format: " (LSR %+.1f)", velocity + lsr) }
        print(line + (final ? "   -> \(csv)" : ""))
    }

    if let path = arguments.option("ifile") {
        guard let referencePath = arguments.option("reference-file") else { fail("--ifile needs --reference-file (the same length, tuned off the line)") }
        for (file, position) in [(path, SwitchedSpectrometer.Position.signal), (referencePath, .reference)] {
            guard let handle = FileHandle(forReadingAtPath: file) else { fail("cannot read \(file)") }
            while true {
                let chunk = handle.readData(ofLength: 2 * fftSize * 256)
                if chunk.isEmpty { break }
                spectrometer.add([UInt8](chunk), to: position)
            }
        }
        report(final: true)
        return
    }

    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        _ = try device.setSampleRate(Int(rate))
        try arguments.applyFrequencyCorrection(to: device)
        try arguments.applyGain(to: device, default: "40.2")
        let settle = Int(rate * 0.01) * 2                                     // after each retune
        let bytes = Int(rate * dwell) * 2
        print("hydrogen line: signal at \(megahertz(center)), reference \(String(format: "%+.1f", referenceOffset / 1e6)) MHz, "
              + "\(Int(rate)) S/s, \(fftSize)-point spectra (\(String(format: "%.2f", rate / Double(fftSize) / 1000)) kHz), "
              + "switching every \(dwell) s for \(Int(seconds)) s; the CSV is rewritten every 10 rounds")
        var round = 0
        while Date().timeIntervalSince(started) < seconds {
            for position in [SwitchedSpectrometer.Position.signal, .reference] {
                try device.setCenterFrequency(Int((position == .signal ? center : center + referenceOffset).rounded()))
                let samples = try device.readSamples(byteCount: settle + bytes)
                spectrometer.add(Array(samples.dropFirst(settle)), to: position)
            }
            round += 1
            if round % 10 == 0 { report(final: false) }
        }
        report(final: true)
    } catch { fail(error.localizedDescription) }
}
