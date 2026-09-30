// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRKit

// rtlsdr-tool: a small command-line front end for RTLSDRKit.
//
//   rtlsdr-tool list
//   rtlsdr-tool capture --freq 100e6 [--rate 2048000] [--gain auto|<dB>] [--ppm 0] [--seconds 2] [--out iq.u8] [--serial ID]
//   rtlsdr-tool lockscan [--from 20e6] [--to 1800e6] [--step 5e6]      does the oscillator lock across the range?
//   rtlsdr-tool stream [--rate 2400000] [--seconds 20]                 does the sample stream keep up?

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let usage = """
usage:
  rtlsdr-tool list
  rtlsdr-tool capture --freq <Hz|e-notation> [--rate 2048000] [--gain auto|<dB>] [--ppm 0] [--seconds 2] [--out FILE] [--serial ID]
  rtlsdr-tool lockscan [--from 20e6] [--to 1800e6] [--step 5e6]
  rtlsdr-tool stream [--rate 2400000] [--seconds 20]
"""

let allArguments = Array(CommandLine.arguments.dropFirst())
guard let command = allArguments.first else { print(usage); exit(0) }
let arguments = Array(allArguments.dropFirst())

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

switch command {
case "list":
    let devices = RTLSDRDevice.connectedDevices()
    if devices.isEmpty { print("No RTL-SDR devices found."); exit(0) }
    for (index, device) in devices.enumerated() {
        print("\(index): \(device.name)  [\(String(device.vendorID, radix: 16)):\(String(device.productID, radix: 16))]  \(device.manufacturer) \(device.product)  serial \(device.serial)")
    }

case "capture":
    guard let freqText = option("freq"), let freq = Double(freqText) else { fail("--freq is required\n\(usage)") }
    let rate = Int(option("rate") ?? "") ?? 2_048_000
    let seconds = Double(option("seconds") ?? "") ?? 2
    let ppm = Int(option("ppm") ?? "") ?? 0
    do {
        let device = try RTLSDRDevice.openFirst(serial: option("serial"))
        defer { device.close() }
        print("Opened \(device.info?.name ?? "device") with \(device.tuner.rawValue) tuner")
        try device.setFrequencyCorrection(ppm: ppm)
        let actualRate = try device.setSampleRate(rate)
        try device.setCenterFrequency(Int(freq))
        switch option("gain") ?? "auto" {
        case "auto": try device.setAutomaticGain()
        case let text:
            guard let db = Double(text) else { fail("--gain must be 'auto' or a number of dB") }
            try device.setTunerGain(tenthsDB: Int(db * 10))
        }
        print("Tuned \(Int(freq)) Hz, \(actualRate) S/s, PLL \(device.pllLocked ? "locked" : "NOT locked"), VCO sub-band \(device.tunerVCOBandCode)")

        let bytes = try device.readSamples(byteCount: Int(actualRate * 2 * seconds))
        // Statistics over unsigned 8-bit I/Q (127.5 is zero).
        var sumI = 0.0, sumQ = 0.0, power = 0.0
        var clipped = 0
        for pair in stride(from: 0, to: bytes.count - 1, by: 2) {
            let i = Double(bytes[pair]) - 127.5, q = Double(bytes[pair + 1]) - 127.5
            sumI += i; sumQ += q; power += i * i + q * q
            if bytes[pair] == 0 || bytes[pair] == 255 || bytes[pair + 1] == 0 || bytes[pair + 1] == 255 { clipped += 1 }
        }
        let count = Double(bytes.count / 2)
        let dbfs = 10 * log10(max(1e-12, power / count / (127.5 * 127.5)))
        print(String(format: "%d samples: mean I %.2f Q %.2f, power %.1f dBFS, clipped %.3f%%", Int(count), sumI / count, sumQ / count, dbfs, 100 * Double(clipped) / count))
        if let path = option("out") {
            try Data(bytes).write(to: URL(fileURLWithPath: path))
            print("Wrote \(bytes.count) bytes to \(path)")
        }
    } catch {
        fail(error.localizedDescription)
    }

case "lockscan":
    let from = Double(option("from") ?? "") ?? 20e6, to = Double(option("to") ?? "") ?? 1800e6, step = Double(option("step") ?? "") ?? 5e6
    do {
        let device = try RTLSDRDevice.openFirst(serial: option("serial"))
        defer { device.close() }
        try device.setSampleRate(2_048_000)
        try device.setAutomaticGain()
        var failed: [Int] = [], refused: [Int] = [], attempts = 0
        var slowest = 0.0, total = 0.0
        var codes: [Int: Int] = [:]
        var hertz = from
        while hertz <= to {
            let target = Int(hertz)
            attempts += 1
            let started = Date()
            do {
                try device.setCenterFrequency(target)
                if device.pllLocked { codes[device.tunerVCOBandCode, default: 0] += 1 } else { failed.append(target) }
            } catch { refused.append(target) }
            let took = Date().timeIntervalSince(started)
            slowest = max(slowest, took); total += took
            hertz += step
        }
        print("tried \(attempts) frequencies from \(Int(from / 1e6)) to \(Int(to / 1e6)) MHz in \(Int(step / 1e3)) kHz steps")
        print("  locked: \(attempts - failed.count - refused.count)   did not lock: \(failed.count)   refused by range check: \(refused.count)")
        if !failed.isEmpty { print("  no lock at (MHz): \(failed.map { String(format: "%.1f", Double($0) / 1e6) }.joined(separator: ", "))") }
        if !refused.isEmpty { print("  refused (MHz): \(refused.map { String(format: "%.1f", Double($0) / 1e6) }.joined(separator: ", "))") }
        print(String(format: "  retune time: mean %.1f ms, slowest %.1f ms", 1000 * total / Double(max(1, attempts)), 1000 * slowest))
        print("  VCO sub-bands used: \(codes.keys.sorted().map { "\($0)×\(codes[$0]!)" }.joined(separator: " "))")
    } catch { fail(error.localizedDescription) }

case "stream":
    let rate = Int(option("rate") ?? "") ?? 2_400_000
    let seconds = Double(option("seconds") ?? "") ?? 20
    do {
        let device = try RTLSDRDevice.openFirst(serial: option("serial"))
        defer { device.close() }
        let actual = try device.setSampleRate(rate)
        try device.setCenterFrequency(100_000_000)
        try device.setAutomaticGain()
        let stats = StreamStats()
        let dead = StreamStats.Failure()
        try device.startStreaming(onError: { dead.set($0) }, handler: { stats.record($0.count) })
        Thread.sleep(forTimeInterval: seconds)
        device.stopStreaming()
        let snapshot = stats.snapshot()
        let expected = actual * 2 * snapshot.elapsed
        print(String(format: "requested %.0f S/s for %.1f s: received %d bytes in %d blocks", actual, snapshot.elapsed, snapshot.bytes, snapshot.blocks))
        print(String(format: "  achieved %.4f MS/s (%.3f%% of nominal)", Double(snapshot.bytes) / 2 / snapshot.elapsed / 1e6, 100 * Double(snapshot.bytes) / expected))
        print(String(format: "  block gap: mean %.2f ms, longest %.2f ms", 1000 * snapshot.elapsed / Double(max(1, snapshot.blocks)), 1000 * snapshot.longestGap))
        if let error = dead.value { print("  STREAM ERROR: \(error.localizedDescription)") }
    } catch { fail(error.localizedDescription) }

default:
    print(usage)
    exit(command == "help" ? 0 : 1)
}

/// Counts what a stream delivers, from the USB completion queue.
final class StreamStats: @unchecked Sendable {
    final class Failure: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Error?
        func set(_ error: Error) { lock.lock(); stored = error; lock.unlock() }
        var value: Error? { lock.lock(); defer { lock.unlock() }; return stored }
    }
    struct Snapshot { var bytes: Int; var blocks: Int; var elapsed: Double; var longestGap: Double }
    private let lock = NSLock()
    private var bytes = 0, blocks = 0
    private var first: Date?, last: Date?
    private var longestGap = 0.0
    func record(_ count: Int) {
        let now = Date()
        lock.lock()
        if let last { longestGap = max(longestGap, now.timeIntervalSince(last)) }
        if first == nil { first = now }
        last = now
        bytes += count; blocks += 1
        lock.unlock()
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(bytes: bytes, blocks: blocks, elapsed: (first.flatMap { f in last.map { $0.timeIntervalSince(f) } }) ?? 0, longestGap: longestGap)
    }
}
