// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRKit

private func describe(_ image: EEPROMImage) -> String {
    var lines = [
        String(format: "  USB IDs         %04x:%04x", image.vendorID, image.productID) + (image.hasSignature ? "" : "   (signature missing!)"),
        "  serial enabled  \(image.serialEnabled ? "yes" : "no")",
        "  IR endpoint     \(image.irEndpointEnabled ? "yes" : "no")",
        "  remote wakeup   \(image.remoteWakeup ? "yes" : "no")",
    ]
    do {
        let strings = try image.strings()
        lines += ["  manufacturer    \(strings.manufacturer)", "  product         \(strings.product)", "  serial          \(strings.serial)"]
    } catch {
        lines.append("  strings         unreadable: \(error.localizedDescription)")
    }
    return lines.joined(separator: "\n")
}

/// `eeprom`: show what the EEPROM holds, and optionally save all 256 bytes as a backup.
func eepromDump(_ arguments: Arguments) {
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        let image = try device.readEEPROM()
        print(describe(image))
        print(image.hexDump)
        if let path = arguments.option("out") {
            try Data(image.bytes).write(to: URL(fileURLWithPath: path))
            print("saved to \(path)")
        }
    } catch { fail(error.localizedDescription) }
}

/// `set-serial`: give one dongle a new serial number. Dry run unless `--write`; always backs up before writing.
func setSerial(_ arguments: Arguments) {
    guard let serial = arguments.positional else { fail("usage: rtlsdr-tool set-serial <new serial> [--device N] [--write] [--backup FILE]") }
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        let current = try device.readEEPROM()
        let updated = try current.replacingSerial(serial)
        print("current:\n\(describe(current))")
        let changes = updated.differences(from: current)
        print("new serial \(serial): \(changes.count) byte(s) change, at offsets \(changes.map { String(format: "0x%02x", $0) }.joined(separator: " "))")
        guard arguments.flag("write") else {
            print("dry run: nothing written. Add --write to program the EEPROM (on a dongle you can afford to lose, the first time).")
            return
        }
        let oldSerial = (try? current.strings().serial) ?? "unknown"
        let backup = arguments.option("backup") ?? "eeprom-backup-\(oldSerial)-\(Int(Date().timeIntervalSince1970)).bin"
        try Data(current.bytes).write(to: URL(fileURLWithPath: backup))
        print("backup of the old contents: \(backup)")
        let written = try device.writeEEPROM(updated)
        print("wrote \(written.count) byte(s) and read everything back: it matches. Unplug and replug the dongle for the new serial to show.")
    } catch { fail(error.localizedDescription) }
}
