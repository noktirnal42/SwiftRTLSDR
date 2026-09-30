// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRKit

// rtlsdr-tool: a small command-line front end for RTLSDRKit. Every command takes --device <index> (as `list` numbers
// them) or --serial <serial> to pick a dongle; otherwise the first one is used.

let usage = """
usage:
  rtlsdr-tool list
  rtlsdr-tool capture --freq <Hz|e-notation> [--rate 2048000] [--gain auto|<dB>] [--ppm 0] [--seconds 2] [--out FILE]
  rtlsdr-tool lockscan [--from 20e6] [--to 1800e6] [--step 5e6] [--fast]
  rtlsdr-tool stream [--rate 2400000] [--seconds 20]
  rtlsdr-tool retunebench [--freq 100e6] [--step 25e3] [--hop 433.92e6] [--count 200] [--mode compare|none|bus|vco|all] [--streaming]
  rtlsdr-tool monitor --freq <Hz> [--rate 2048000] [--seconds 10] [--gain auto|<dB>] [--guard] [--agc <target dBFS>]
  rtlsdr-tool scan --from <Hz> --to <Hz> [--rate 2400000] [--gain 29.7] [--fft 1024] [--frames 16] [--threshold 10]
                   [--sweeps 1] [--no-cover] [--fast] [--csv FILE]
  rtlsdr-tool eeprom [--out FILE]
  rtlsdr-tool set-serial <serial> [--write] [--backup FILE]
  rtlsdr-tool adsb [--ifile FILE] [--raw] [--gain 49.6|auto] [--lat <deg> --lon <deg>] [--seconds N]
  rtlsdr-tool uat [--ifile FILE | --frames FILE] [--raw] [--nexrad DIR] [--gain 49.6|auto] [--seconds N]
  rtlsdr-tool ism [--ifile FILE] [--freq 433.92e6] [--rate 250000] [--json] [--protocols 2,12,...] [--fsk classic|minmax]
                  [--analyze] [--codes] [--list-protocols] [--gain auto|<dB>] [--seconds N]
  rtlsdr-tool ism --code '[19]{36}b5a8f0470' [--json]
  rtlsdr-tool serve [--address 127.0.0.1] [--port 1234] [--rate 2048000] [--freq 100e6] [--gain auto|<dB>] [--allow-bias-tee] [--fast]

  every command: [--device <index> | --serial <serial>]
"""

let allArguments = Array(CommandLine.arguments.dropFirst())
guard let command = allArguments.first else { print(usage); exit(0) }
let arguments = Arguments(words: Array(allArguments.dropFirst()))

switch command {
case "list":
    let devices = RTLSDRDevice.connectedDevices()
    if devices.isEmpty { print("No RTL-SDR devices found."); exit(0) }
    for (index, device) in devices.enumerated() {
        print("\(index): \(device.name)  [\(String(device.vendorID, radix: 16)):\(String(device.productID, radix: 16))]  \(device.manufacturer) \(device.product)  serial \(device.serial)")
    }
    let serials = devices.map(\.serial)
    if Set(serials).count < serials.count {
        print("Some dongles share a serial number, so --serial cannot tell them apart. Use --device, or give each its own with set-serial.")
    }

case "capture":
    guard arguments.option("freq") != nil else { fail("--freq is required\n\(usage)") }
    let freq = arguments.double("freq", default: 0)
    let rate = arguments.int("rate", default: 2_048_000)
    let seconds = arguments.double("seconds", default: 2)
    let ppm = arguments.int("ppm", default: 0)
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        print("Opened \(device.info?.name ?? "device") with \(device.tuner.rawValue) tuner")
        try device.setFrequencyCorrection(ppm: ppm)
        let actualRate = try device.setSampleRate(rate)
        try device.setCenterFrequency(Int(freq))
        try arguments.applyGain(to: device)
        print("Tuned \(Int(freq)) Hz, \(actualRate) S/s, PLL \(device.pllLocked ? "locked" : "NOT locked"), VCO sub-band \(device.tunerVCOBandCode)")

        let bytes = try device.readSamples(byteCount: Int(actualRate * 2 * seconds))
        let statistics = SampleStatistics(bytes)
        // "clipped" keeps its original meaning: the share of I/Q pairs with either value on a rail.
        var clippedPairs = 0
        for pair in stride(from: 0, to: bytes.count - 1, by: 2) where bytes[pair] == 0 || bytes[pair] == 255 || bytes[pair + 1] == 0 || bytes[pair + 1] == 255 {
            clippedPairs += 1
        }
        print(String(format: "%d samples: mean I %.2f Q %.2f, power %.1f dBFS, clipped %.3f%%", statistics.sampleCount,
                     statistics.dcOffset.i, statistics.dcOffset.q, statistics.meanPowerDBFS,
                     100 * Double(clippedPairs) / Double(max(1, statistics.sampleCount))))
        if let path = arguments.option("out") {
            try Data(bytes).write(to: URL(fileURLWithPath: path))
            print("Wrote \(bytes.count) bytes to \(path)")
        }
    } catch {
        fail(error.localizedDescription)
    }

case "lockscan":
    lockScan(arguments)

case "stream":
    let rate = arguments.int("rate", default: 2_400_000)
    let seconds = arguments.double("seconds", default: 20)
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        let actual = try device.setSampleRate(rate)
        try device.setCenterFrequency(100_000_000)
        try device.setAutomaticGain()
        let stats = StreamStats()
        let dead = FailureBox()
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

case "retunebench":
    retuneBenchmark(arguments)

case "monitor":
    monitor(arguments)

case "scan":
    scan(arguments)

case "eeprom":
    eepromDump(arguments)

case "set-serial":
    setSerial(arguments)

case "serve":
    serve(arguments)

case "adsb":
    adsb(arguments)

case "uat":
    uat(arguments)

case "ism":
    ism(arguments)

default:
    print(usage)
    exit(command == "help" ? 0 : 1)
}

/// Counts what a stream delivers, from the USB completion queue.
final class StreamStats: @unchecked Sendable {
    struct Snapshot { var bytes: Int; var blocks: Int; var elapsed: Double; var longestGap: Double }
    private let lock = NSLock()
    private var bytes = 0, blocks = 0
    private var first: Double?, last: Double?
    private var longestGap = 0.0
    func record(_ count: Int) {
        let now = monotonicSeconds()
        lock.lock()
        if let last { longestGap = max(longestGap, now - last) }
        if first == nil { first = now }
        last = now
        bytes += count; blocks += 1
        lock.unlock()
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(bytes: bytes, blocks: blocks, elapsed: (first.flatMap { f in last.map { $0 - f } }) ?? 0, longestGap: longestGap)
    }
}
