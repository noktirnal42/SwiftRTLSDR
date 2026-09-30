// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// The command line after the command name: `--name value` options, `--flag` switches and positional words.
struct Arguments {
    let words: [String]

    func option(_ name: String) -> String? {
        guard let index = words.firstIndex(of: "--\(name)"), index + 1 < words.count else { return nil }
        return words[index + 1]
    }

    func flag(_ name: String) -> Bool { words.contains("--\(name)") }

    /// The first word that is neither an option name nor an option's value.
    var positional: String? {
        var index = 0
        while index < words.count {
            if words[index].hasPrefix("--") {
                // Switches take no value; everything else consumes the next word.
                index += Self.switches.contains(words[index]) ? 1 : 2
                continue
            }
            return words[index]
        }
        return nil
    }

    static let switches: Set<String> = ["--fast", "--write", "--guard", "--streaming", "--allow-bias-tee", "--no-cover"]

    func double(_ name: String, default value: Double) -> Double {
        guard let text = option(name) else { return value }
        guard let number = Double(text) else { fail("--\(name) needs a number, got \(text)") }
        return number
    }

    func int(_ name: String, default value: Int) -> Int { Int(double(name, default: Double(value))) }

    /// Opens the dongle chosen by `--device <index>` (as `list` numbers them) or `--serial <serial>`, else the first.
    func openDevice() throws -> RTLSDRDevice {
        if let text = option("device") {
            guard let index = Int(text) else { fail("--device needs an index from `rtlsdr-tool list`") }
            let devices = RTLSDRDevice.connectedDevices()
            guard devices.indices.contains(index) else { fail("there is no device \(index); `rtlsdr-tool list` shows \(devices.count)") }
            return try RTLSDRDevice.open(devices[index])
        }
        return try RTLSDRDevice.openFirst(serial: option("serial"))
    }

    /// `--gain auto|<dB>` applied to `device`.
    func applyGain(to device: RTLSDRDevice, default value: String = "auto") throws {
        switch option("gain") ?? value {
        case "auto": try device.setAutomaticGain()
        case let text:
            guard let db = Double(text) else { fail("--gain must be 'auto' or a number of dB") }
            try device.setTunerGain(tenthsDB: Int((db * 10).rounded()))
        }
    }

    /// `--fast` turns every retune shortcut on.
    func applyRetuneShortcuts(to device: RTLSDRDevice) throws {
        if flag("fast") { try device.setRetuneShortcuts(.all) }
    }
}

/// Seconds on a monotonic clock.
func monotonicSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func megahertz(_ hertz: Double) -> String { String(format: "%.4f MHz", hertz / 1e6) }
