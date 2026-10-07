// SPDX-License-Identifier: GPL-2.0-or-later
//
// What an iMet frame says, in the units people use. The JSON follows what rs1729's imet1rs_dft prints with `--json` (the
// form radiosonde_auto_rx reads). Written for this package. See PROVENANCE.md.
import Foundation

/// One position report from an iMet-1 or iMet-4.
public struct IMetReport: Sendable {
    /// The sonde's packet counter, one a second.
    public var frame: Int?
    public var gps: IMetGPS
    public var ptu: IMetPTU?
    /// Instrument data in the frame, each as hexadecimal text.
    public var aux: [IMetXData]

    /// The time of day from the GPS receiver, "HH:MM:SS" (the sonde sends no date and does not say whether the clock has
    /// the leap seconds applied; radiosonde_auto_rx treats it as GPS time).
    public var timeOfDay: String { String(format: "%02d:%02d:%02d", gps.hour, gps.minute, gps.second) }

    /// Whether the frame's PTU packet came through too: without it there is no frame number and no sensor readings.
    public var isComplete: Bool { ptu != nil }

    /// The JSON line imet1rs_dft writes with `--json`, for a complete report only (as it does; the line form shows the
    /// position of a frame whose PTU packet was damaged). It has no serial number: the sonde sends none.
    public func json(frequencyKHz: Int? = nil) -> String? {
        guard let ptu else { return nil }
        var text = "{ \"type\": \"IMET\", \"frame\": \(ptu.number), \"id\": \"iMet\", \"datetime\": \"\(timeOfDay)Z\", "
        text += String(format: "\"lat\": %.5f, \"lon\": %.5f, \"alt\": %d, \"sats\": %d", gps.latitude, gps.longitude, gps.altitude, gps.satellites)
        text += String(format: ", \"temp\": %.2f, \"humidity\": %.2f, \"pressure\": %.2f, \"batt\": %.1f",
                       ptu.temperature, ptu.humidity, ptu.pressure, ptu.batteryVolts)
        if !aux.isEmpty { text += ", \"aux\": \"\(aux.map(\.hex).joined(separator: "#"))\"" }
        if let frequencyKHz { text += ", \"freq\": \(frequencyKHz)" }
        return text + ", \"ref_datetime\": \"GPS\", \"ref_position\": \"MSL\" }"
    }

    /// A one-line summary.
    public var line: String {
        var text = String(format: "%@  lat: %.5f  lon: %.5f  alt: %dm  sats: %d", timeOfDay, gps.latitude, gps.longitude, gps.altitude, gps.satellites)
        if let velocity = gps.velocity {
            var heading = atan2(velocity.east, velocity.north) * 180 / .pi
            if heading < 0 { heading += 360 }
            text += String(format: "  vH: %.1f  D: %.1f  vV: %.1f", (velocity.east * velocity.east + velocity.north * velocity.north).squareRoot(),
                           heading, velocity.up)
        }
        if let ptu {
            text += String(format: "  P: %.2f mb  T: %.2f C  U: %.2f %%  batt: %.1f V", ptu.pressure, ptu.temperature, ptu.humidity, ptu.batteryVolts)
        }
        return text
    }
}

/// Turns iMet frames into reports.
public struct IMetDecoder: Sendable {
    public init() {}

    /// The report a frame gives: its position, with the pressure, temperature and humidity of the same frame when their
    /// packet came through.
    public func report(_ frame: IMetFrame) -> IMetReport? {
        guard let gps = frame.gps, gps.isPlausible else { return nil }
        let ptu = frame.ptu
        return IMetReport(frame: ptu?.number, gps: gps, ptu: ptu, aux: frame.xdata)
    }
}
