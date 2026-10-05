// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRKit

/// Sums block statistics between reports, from the USB completion queue.
private final class Accumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var statistics = SampleStatistics()
    func add(_ block: SampleStatistics) { lock.lock(); statistics.merge(block); lock.unlock() }
    func take() -> SampleStatistics { lock.lock(); defer { statistics = SampleStatistics(); lock.unlock() }; return statistics }
}

/// `monitor`: level, clipping and DC once a second; optionally with the overload guard or the host AGC in charge.
func monitor(_ arguments: Arguments) {
    guard arguments.option("freq") != nil else { fail("--freq is required") }
    let seconds = arguments.double("seconds", default: 10)
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        try device.setSampleRate(arguments.int("rate", default: 2_048_000))
        try arguments.applyFrequencyCorrection(to: device)
        try device.setCenterFrequency(Int(arguments.double("freq", default: 0)))

        var control: HostGainControl?
        if let target = arguments.option("agc") {
            guard let dbfs = Double(target) else { fail("--agc needs a target level in dBFS, such as -25") }
            control = try HostGainControl(device: device, configuration: .automatic(targetDBFS: dbfs), onChange: report)
            print("host AGC: target \(dbfs) dBFS, starting at \(Double(control!.gainTenthsDB) / 10) dB")
        } else if arguments.flag("guard") {
            let ceiling = Int((arguments.double("gain", default: 49.6) * 10).rounded())
            control = try HostGainControl(device: device, configuration: .overloadGuard(ceilingTenthsDB: ceiling), onChange: report)
            print("overload guard: ceiling \(Double(control!.gainTenthsDB) / 10) dB")
        } else {
            try arguments.applyGain(to: device)
        }

        let accumulator = Accumulator()
        let failure = FailureBox()
        let activeControl = control
        try device.startStreaming(onError: { failure.set($0) }) { block in
            let statistics = SampleStatistics(block)
            accumulator.add(statistics)
            activeControl?.observe(statistics)
        }
        print("   time   level dBFS   rails %    DC I/Q      gain")
        let started = monotonicSeconds()
        while monotonicSeconds() - started < seconds, failure.value == nil {
            Thread.sleep(forTimeInterval: 1)
            let statistics = accumulator.take()
            let gain = control.map { Double($0.gainTenthsDB) / 10 }.map { String(format: "%.1f dB", $0) }
                ?? device.tunerGainTenthsDB.map { String(format: "%.1f dB", Double($0) / 10) } ?? "auto"
            print(String(format: "%6.1f s   %8.1f   %8.3f   %+5.1f/%+5.1f   ", monotonicSeconds() - started, statistics.meanPowerDBFS,
                         100 * statistics.railFraction, statistics.dcOffset.i, statistics.dcOffset.q) + gain)
        }
        control?.stop()
        device.stopStreaming()
        if let error = failure.value { print("STREAM ERROR: \(error.localizedDescription)") }
    } catch { fail(error.localizedDescription) }
}

private let report: @Sendable (HostGainControl.Change) -> Void = { change in
    print(String(format: "  gain %.1f -> %.1f dB (", Double(change.fromTenthsDB) / 10, Double(change.toTenthsDB) / 10) + "\(change.reason)"
          + String(format: ": level %.1f dBFS, rails %.3f %%)", change.statistics.meanPowerDBFS, 100 * change.statistics.railFraction))
}

final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    func set(_ error: Error) { lock.lock(); if stored == nil { stored = error }; lock.unlock() }
    var value: Error? { lock.lock(); defer { lock.unlock() }; return stored }
}
