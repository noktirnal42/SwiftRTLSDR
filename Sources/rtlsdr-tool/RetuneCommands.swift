// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRKit

/// `retunebench`: how long retunes take, with and without the shortcuts, and whether the oscillator still locks.
func retuneBenchmark(_ arguments: Arguments) {
    let base = arguments.double("freq", default: 100e6)
    let step = arguments.double("step", default: 25e3)
    let hop = arguments.double("hop", default: 433.92e6)
    let count = max(10, arguments.int("count", default: 200))
    let modes: [(String, RTLSDRDevice.RetuneShortcuts)]
    switch arguments.option("mode") ?? "compare" {
    case "none": modes = [("none", [])]
    case "bus": modes = [("keepTunerBusOpen", .keepTunerBusOpen)]
    case "vco": modes = [("reuseVCOStatus", .reuseVCOStatus)]
    case "all": modes = [("all", .all)]
    case "compare": modes = [("none", []), ("all", .all), ("none", []), ("all", .all)]    // interleaved against drift
    case let other: fail("--mode must be none, bus, vco, all or compare, not \(other)")
    }

    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        try device.setSampleRate(arguments.int("rate", default: 2_400_000))
        try arguments.applyGain(to: device)
        if arguments.flag("streaming") { try device.startStreaming { _ in } }
        defer { device.stopStreaming() }
        print("\(count) retunes per pattern\(arguments.flag("streaming") ? ", while streaming" : ""); times in ms")
        print("mode              pattern                        mean  median   p95    max  unlocked")

        for (name, shortcuts) in modes {
            try device.setRetuneShortcuts(shortcuts)
            try device.setCenterFrequency(Int(base))                         // warm-up
            let patterns: [(String, (Int) -> Int)] = [
                ("small steps (\(Int(step / 1e3)) kHz)", { Int(base + Double($0 % 2 == 0 ? 1 : 2) * step) }),
                ("band hops (\(Int(base / 1e6))<->\(Int(hop / 1e6)) MHz)", { Int($0 % 2 == 0 ? hop : base) }),
            ]
            for (label, target) in patterns {
                var times: [Double] = []
                var unlocked = 0
                for index in 0..<count {
                    let started = monotonicSeconds()
                    try device.setCenterFrequency(target(index))
                    times.append((monotonicSeconds() - started) * 1000)
                    if !device.pllLocked { unlocked += 1 }
                }
                times.sort()
                let mean = times.reduce(0, +) / Double(times.count)
                let label = label.padding(toLength: 28, withPad: " ", startingAt: 0)
                print(name.padding(toLength: 16, withPad: " ", startingAt: 0) + "  " + label + "  "
                      + String(format: "%6.2f  %6.2f  %6.2f  %6.2f  %d", mean, times[times.count / 2],
                               times[Int(Double(times.count) * 0.95)], times.last!, unlocked))
            }
        }
    } catch { fail(error.localizedDescription) }
}

/// `lockscan`: does the oscillator lock across the range?
func lockScan(_ arguments: Arguments) {
    let from = arguments.double("from", default: 20e6), to = arguments.double("to", default: 1800e6), step = arguments.double("step", default: 5e6)
    guard step >= 1 else { fail("--step must be at least 1 Hz") }
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        try device.setSampleRate(2_048_000)
        try device.setAutomaticGain()
        try arguments.applyRetuneShortcuts(to: device)
        var failed: [Int] = [], refused: [Int] = [], attempts = 0
        var slowest = 0.0, total = 0.0
        var codes: [Int: Int] = [:]
        var hertz = from
        while hertz <= to {
            let target = Int(hertz)
            attempts += 1
            let started = monotonicSeconds()
            do {
                try device.setCenterFrequency(target)
                if device.pllLocked { codes[device.tunerVCOBandCode, default: 0] += 1 } else { failed.append(target) }
            } catch { refused.append(target) }
            let took = monotonicSeconds() - started
            slowest = max(slowest, took); total += took
            hertz += step
        }
        print("tried \(attempts) frequencies from \(Int(from / 1e6)) to \(Int(to / 1e6)) MHz in \(Int(step / 1e3)) kHz steps\(arguments.flag("fast") ? " (retune shortcuts on)" : "")")
        print("  locked: \(attempts - failed.count - refused.count)   did not lock: \(failed.count)   refused by range check: \(refused.count)")
        if !failed.isEmpty { print("  no lock at (MHz): \(failed.map { String(format: "%.1f", Double($0) / 1e6) }.joined(separator: ", "))") }
        if !refused.isEmpty { print("  refused (MHz): \(refused.map { String(format: "%.1f", Double($0) / 1e6) }.joined(separator: ", "))") }
        print(String(format: "  retune time: mean %.1f ms, slowest %.1f ms", 1000 * total / Double(max(1, attempts)), 1000 * slowest))
        print("  VCO sub-bands used: \(codes.keys.sorted().map { "\($0)×\(codes[$0]!)" }.joined(separator: " "))")
    } catch { fail(error.localizedDescription) }
}
