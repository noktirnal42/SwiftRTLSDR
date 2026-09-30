// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRKit
import RTLSDRScan

/// `scan`: sweep a range, list what stands above the noise floor, optionally save the spectrum as CSV.
func scan(_ arguments: Arguments) {
    guard arguments.option("from") != nil, arguments.option("to") != nil else { fail("--from and --to are required") }
    let from = Int(arguments.double("from", default: 0)), to = Int(arguments.double("to", default: 0))
    guard from < to else { fail("--from must be below --to") }
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        try device.setSampleRate(arguments.int("rate", default: 2_400_000))
        try arguments.applyGain(to: device, default: "29.7")      // a fixed gain keeps hops comparable
        try arguments.applyRetuneShortcuts(to: device)

        var configuration = BandScanner.Configuration(range: from...to)
        configuration.fftSize = arguments.int("fft", default: 1024)
        configuration.framesPerHop = arguments.int("frames", default: 16)
        configuration.coverDCHoles = !arguments.flag("no-cover")
        configuration.detector.thresholdDB = arguments.double("threshold", default: 10)
        let scanner = try BandScanner(receiver: device, configuration: configuration)
        print("\(scanner.plan.centers.count) hops of \(Int(device.sampleRate)) S/s, \(String(format: "%.0f", scanner.plan.binWidth)) Hz bins")

        for sweep in 1...max(1, arguments.int("sweeps", default: 1)) {
            let started = monotonicSeconds()
            let spectrum = try scanner.sweep()
            let took = monotonicSeconds() - started
            let detections = scanner.detect(in: spectrum)
            print(String(format: "sweep %d: %.2f s, %d signal(s)", sweep, took, detections.count))
            for detection in detections.sorted(by: { $0.snrDB > $1.snrDB }) {
                print("  \(megahertz(detection.frequencyHz))   " + String(format: "%6.1f dB   SNR %5.1f dB   width %6.1f kHz",
                                                                            detection.powerDB, detection.snrDB, detection.bandwidthHz / 1e3))
            }
            if let path = arguments.option("csv") {
                var text = "frequency_hz,power_db\n"
                for (bin, power) in spectrum.powerDB.enumerated() where !power.isNaN {
                    text += String(format: "%.0f,%.2f\n", spectrum.frequency(ofBin: bin), power)
                }
                try text.write(toFile: path, atomically: true, encoding: .utf8)
                print("  spectrum written to \(path)")
            }
        }
    } catch { fail(error.localizedDescription) }
}
