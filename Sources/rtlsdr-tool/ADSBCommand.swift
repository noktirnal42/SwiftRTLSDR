// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRDecoders
import RTLSDRKit

/// Demodulates and prints Mode S frames; shared by the live and the file paths.
private final class ADSBPrinter: @unchecked Sendable {
    private let demodulator = ModeSDemodulator()
    private let tracker: AircraftTracker
    private let raw: Bool
    private var lastTable = 0.0

    init(raw: Bool, receiver: (latitude: Double, longitude: Double)?) {
        self.raw = raw
        tracker = AircraftTracker(receiverLocation: receiver)
    }

    /// `time`: seconds since the start (stream position for files, wall clock for live reception).
    func process(_ block: [UInt8], time: Double? = nil) {
        for frame in demodulator.process(block) { handle(frame, time: time) }
        if !raw, let time, time - lastTable >= 10 {
            lastTable = time
            tracker.expire(olderThan: 300, now: time)                 // aircraft unheard for 5 minutes leave the table
            printTable()
        }
    }

    /// End of a recording: decode what the demodulator still holds back.
    func finish() {
        for frame in demodulator.flush() { handle(frame, time: nil) }
    }

    private func handle(_ frame: ModeSFrame, time: Double?) {
        let when = time ?? Double(frame.sampleIndex) / Double(ModeSDemodulator.sampleRate)
        tracker.update(frame.message, at: when)
        if raw {
            print("*\(frame.message.hex);")
        } else {
            print(String(format: "%8.3f s %6.1f dBFS  ", when, frame.signalDBFS) + describe(frame.message) + (frame.correctedBit.map { "  (bit \($0) repaired)" } ?? ""))
        }
    }

    func printTable() {
        let aircraft = tracker.aircraft
        guard !aircraft.isEmpty else { return }
        print("  ICAO    callsign  squawk  altitude  speed  track   v-rate   latitude   longitude  msgs")
        for plane in aircraft {
            let position = plane.latitude.map { String(format: "%9.4f  %10.4f", $0, plane.longitude ?? 0) } ?? String(repeating: " ", count: 21)
            print("  " + plane.addressHex + "  " + (plane.callsign ?? "").padding(toLength: 8, withPad: " ", startingAt: 0)
                  + "  " + (plane.squawk ?? "    ") + "  " + (plane.altitudeFeet.map { String(format: "%8d", $0) } ?? "        ")
                  + "  " + (plane.groundSpeedKnots.map { String(format: "%5.0f", $0) } ?? "     ")
                  + "  " + (plane.trackDegrees.map { String(format: "%5.1f", $0) } ?? "     ")
                  + "  " + (plane.verticalRateFPM.map { String(format: "%7d", $0) } ?? "       ")
                  + "  " + position + String(format: "  %4d", plane.messages))
        }
    }

    private func describe(_ message: ModeSMessage) -> String {
        let head = String(format: "DF%-2d %06X  ", message.downlinkFormat, message.address)
        switch message.content {
        case let .altitude(feet): return head + "altitude " + (feet.map { "\($0) ft" } ?? "unknown")
        case let .identity(squawk): return head + "squawk \(squawk)"
        case let .allCall(capability): return head + "all-call reply, capability \(capability)"
        case .other: return head + message.hex
        case let .extendedSquitter(squitter):
            switch squitter {
            case let .identification(id): return head + "callsign \(id.callsign)"
            case let .airbornePosition(position):
                return head + "position (\(position.cpr.isOdd ? "odd" : "even") CPR), " + (position.altitudeFeet.map { "\($0) ft" + (position.altitudeIsGNSS ? " GNSS" : "") } ?? "altitude unknown")
            case let .velocity(velocity):
                var text = head
                switch velocity.kind {
                case let .ground(speed, track)?: text += String(format: "ground speed %.0f kt, track %.1f°", speed, track)
                case let .air(heading, airspeed, isTrue)?:
                    text += (airspeed.map { "\(isTrue ? "TAS" : "IAS") \($0) kt" } ?? "airspeed unknown") + (heading.map { String(format: ", heading %.1f°", $0) } ?? "")
                case nil: text += "velocity unavailable"
                }
                return text + (velocity.verticalRateFPM.map { ", vertical rate \($0) ft/min" } ?? "")
            case let .emergency(state, squawk): return head + "emergency state \(state), squawk \(squawk)"
            case let .other(typeCode): return head + "type code \(typeCode)"
            }
        }
    }
}

/// `adsb`: ADS-B and Mode S on 1090 MHz, from the dongle or from a file of u8 I/Q recorded at 2 MS/s.
func adsb(_ arguments: Arguments) {
    let raw = arguments.flag("raw")
    var receiver: (latitude: Double, longitude: Double)?
    if arguments.option("lat") != nil || arguments.option("lon") != nil {
        guard arguments.option("lat") != nil, arguments.option("lon") != nil else { fail("give both --lat and --lon, or neither") }
        let latitude = arguments.double("lat", default: 0), longitude = arguments.double("lon", default: 0)
        guard abs(latitude) <= 90, abs(longitude) <= 180 else { fail("--lat must be within ±90 and --lon within ±180 degrees") }
        receiver = (latitude, longitude)
    }
    let printer = ADSBPrinter(raw: raw, receiver: receiver)

    if let path = arguments.option("ifile") {
        guard let file = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
        while true {
            let chunk = file.readData(ofLength: 1 << 18)
            if chunk.isEmpty { break }
            printer.process([UInt8](chunk))
        }
        printer.finish()
        if !raw { printer.printTable() }
        return
    }

    let seconds = arguments.double("seconds", default: 1e9)                // until Ctrl-C by default
    do {
        let device = try arguments.openDevice()
        defer { device.close() }
        try device.setSampleRate(ModeSDemodulator.sampleRate)
        try device.setCenterFrequency(Int(arguments.double("freq", default: 1_090_000_000)))
        try arguments.applyGain(to: device, default: "49.6")
        let backlog = Backlog(label: "adsb")
        let started = monotonicSeconds()
        let failure = FailureBox()
        try device.startStreaming(onError: { failure.set($0) }) { block in
            backlog.submit(block) { printer.process($0, time: monotonicSeconds() - started) }
        }
        if !raw { print("listening on 1090 MHz; Ctrl-C to stop") }
        while monotonicSeconds() - started < seconds, failure.value == nil {
            Thread.sleep(forTimeInterval: 0.5)
            let dropped = backlog.newlyDropped()
            if dropped > 0 { FileHandle.standardError.write(Data("warning: decoding fell behind; dropped \(dropped) block(s)\n".utf8)) }
        }
        device.stopStreaming()
        backlog.sync {}
        if let error = failure.value { fail(error.localizedDescription) }
    } catch { fail(error.localizedDescription) }
}
