// SPDX-License-Identifier: GPL-2.0-or-later
//
// The ISM receive chain (envelope and FM → pulse detector → pulse slicer → device decoders), following rtl_433's
// sdr_callback and run_ook_demods/run_fsk_demods (rtl_433.c, r_api.c; GPL-2.0-or-later, release 25.02).
// See PROVENANCE.md.

/// The devices ported so far, in rtl_433's protocol order.
public enum ISMDevices {
    public static let all: [any ISMDevice] = [
        RubicsonSensor(), OregonScientific(), FineOffsetWH2(), NexusSensor(), AmbientWeatherF007TH(), GenericRemote(),
        AcuriteTXR(), LaCrosseTX141(), FineOffsetWH25(), Bresser5in1(), Bresser6in1(),
    ].sorted { $0.protocolNumber < $1.protocolNumber }
}

/// rtl_433's reading of a recording's name: `433.92M` is the centre frequency, `250k` the sample rate (also `Hz`,
/// `sps` and their k/M/G forms), anywhere in the path.
public enum ISMFileName {
    public static func parse(_ path: String) -> (frequency: Int?, sampleRate: Int?) {
        var frequency: Int?, sampleRate: Int?
        let characters = Array(path.utf8)
        var index = 0
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        func isLetter(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
        while index < characters.count {
            if isDigit(characters[index]) {
                let start = index
                while index < characters.count && isDigit(characters[index]) { index += 1 }
                if index < characters.count && characters[index] == 46 {         // "."
                    index += 1
                    if index >= characters.count || !isDigit(characters[index]) { continue }
                    while index < characters.count && isDigit(characters[index]) { index += 1 }
                }
                let number = Double(String(decoding: characters[start..<index], as: UTF8.self)) ?? 0
                let unitStart = index
                while index < characters.count && isLetter(characters[index]) { index += 1 }
                let unit = String(decoding: characters[unitStart..<index], as: UTF8.self)
                let scale: Double = ["k": 1e3, "K": 1e3, "M": 1e6, "m": 1e6, "G": 1e9, "g": 1e9][unit.first.map(String.init) ?? ""] ?? 1
                let lower = unit.lowercased()
                if lower == "m" { frequency = Int(number * 1e6) }
                else if lower == "k" { sampleRate = Int(number * 1e3) }
                else if lower == "hz" { frequency = Int(number) }
                else if lower == "sps" { sampleRate = Int(number) }
                else if lower.count == 3 && lower.hasSuffix("hz") && scale > 1 { frequency = Int(number * scale) }
                else if lower.count == 4 && lower.hasSuffix("sps") && scale > 1 { sampleRate = Int(number * scale) }
            } else if isLetter(characters[index]) {
                while index < characters.count && (isLetter(characters[index]) || isDigit(characters[index])) { index += 1 }
            } else {
                index += 1
            }
        }
        return (frequency, sampleRate)
    }
}

/// A decoded message and the package it came from.
public struct ISMEvent: Sendable {
    public let report: ISMReport
    public let protocolNumber: Int
    /// Stream position (samples) where the package started.
    public let sampleIndex: Int
    public let isFSK: Bool
}

/// Decodes 433/868/915 MHz sensors (weather stations, thermometers, remotes) from u8 I/Q, the way rtl_433 does.
///
/// rtl_433's default sample rate is 250 kHz, which the RTL2832U can do directly; its devices' timings are in
/// microseconds, so other rates work too. Feed blocks in order; call `flush()` at the end of a recording.
public final class ISMReceiver {
    public static let defaultSampleRate = 250_000
    /// What rtl_433 appends at the end of a file (one buffer of silence) so the last package ends.
    public static let flushSamples = 131_072

    public let sampleRate: Int
    public let devices: [any ISMDevice]
    public let fskDetector: FSKPulseDetector
    private var baseband: ISMBaseband
    private var detector: PulseDetector
    private var position = 0                        // stream samples consumed
    private var pendingByte: UInt8?
    private var envelope: [Int16] = []
    private var fm: [Int16] = []

    public private(set) var ookPackages = 0
    public private(set) var fskPackages = 0
    /// Called with every package, decoded or not (for pulse analysis and raw dumps).
    public var onPackage: ((PulseTrain, _ isFSK: Bool, _ decoded: Int) -> Void)?
    /// Called with every bit buffer handed to a decoder (as it was before decoding) and the decoder's result: for
    /// debugging and for making test vectors (`BitBuffer.codes` is rtl_433's `-y` notation).
    public var onBits: ((_ protocolNumber: Int, _ bits: BitBuffer, _ result: Int) -> Void)?

    /// `frequency` chooses the FSK pulse detector (min/max above 800 MHz, classic below) unless one is given.
    public init(sampleRate: Int = ISMReceiver.defaultSampleRate, frequency: Int = 433_920_000,
                devices: [any ISMDevice] = ISMDevices.all, fskDetector: FSKPulseDetector? = nil) {
        self.sampleRate = sampleRate
        self.devices = devices.sorted { $0.protocolNumber < $1.protocolNumber }
        self.fskDetector = fskDetector ?? .automatic(forFrequency: frequency)
        baseband = ISMBaseband(fmLowPass: self.fskDetector.fmLowPass)
        detector = PulseDetector(fskMode: self.fskDetector)
    }

    public func process(_ block: [UInt8]) -> [ISMEvent] {
        block.withUnsafeBufferPointer { process($0) }
    }

    public func process(_ block: UnsafeBufferPointer<UInt8>) -> [ISMEvent] {
        guard !block.isEmpty else { return [] }
        if let pending = pendingByte {                  // an I left over from an odd-length block
            pendingByte = nil
            return process([pending] + Array(block))
        }
        let whole = block.count & ~1
        if whole < block.count { pendingByte = block[whole] }
        guard whole > 0 else { return [] }
        return run(UnsafeBufferPointer(rebasing: block[0..<whole]))
    }

    /// Ends the recording: feeds the buffer of silence rtl_433 feeds, so a package still open is completed.
    public func flush() -> [ISMEvent] {
        pendingByte = nil
        return process([UInt8](repeating: 128, count: Self.flushSamples * 2))
    }

    private func run(_ iq: UnsafeBufferPointer<UInt8>) -> [ISMEvent] {
        baseband.process(iq, envelope: &envelope, fm: &fm)
        var events: [ISMEvent] = []
        let blockStart = position
        envelope.withUnsafeBufferPointer { envelopeBuffer in
            fm.withUnsafeBufferPointer { fmBuffer in
                while let package = detector.next(envelope: envelopeBuffer, fm: fmBuffer, sampleRate: sampleRate, blockStart: blockStart) {
                    let isFSK = package == .fsk
                    let pulses = isFSK ? detector.fsk : detector.ook
                    if isFSK { fskPackages += 1 } else { ookPackages += 1 }
                    // Stamped with the start of the envelope's package, as rtl_433 does (an FSK train that ran past
                    // the pulse limit has shed its start).
                    let found = decode(pulses, isFSK: isFSK, start: detector.ook.offset)
                    events += found
                    onPackage?(pulses, isFSK, found.count)
                }
            }
        }
        position += iq.count / 2
        return events
    }

    /// Decodes a bit buffer written in rtl_433's `-y` notation (`{36}b5a8f0470`, optionally prefixed `[19]` for one
    /// protocol) with every device that accepts it, as rtl_433's `-y` does.
    public static func decode(code: String, devices: [any ISMDevice] = ISMDevices.all) -> [ISMEvent] {
        var text = Substring(code)
        var only: Int?
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            only = Int(text[text.index(after: text.startIndex)..<close])
            text = text[text.index(after: close)...]
        }
        var events: [ISMEvent] = []
        for device in devices.sorted(by: { $0.protocolNumber < $1.protocolNumber }) where only == nil || device.protocolNumber == only {
            var bits = BitBuffer(code: String(text))
            var reports: [ISMReport] = []
            _ = device.decode(&bits, into: &reports)
            events += reports.map { ISMEvent(report: $0, protocolNumber: device.protocolNumber, sampleIndex: 0, isFSK: device.modulation.isFSK) }
        }
        return events
    }

    /// Runs the devices by priority; a later priority runs only if nothing decoded at an earlier one.
    private func decode(_ pulses: PulseTrain, isFSK: Bool, start: Int) -> [ISMEvent] {
        var events: [ISMEvent] = []
        for priority in Set(devices.map(\.priority)).sorted() {
            for device in devices where device.priority == priority && device.modulation.isFSK == isFSK {
                var reports: [ISMReport] = []
                let observer: PulseSlicer.Observer? = onBits.map { onBits in { onBits(device.protocolNumber, $0, $1) } }
                _ = PulseSlicer.run(device, on: pulses, into: &reports, observer: observer)
                events += reports.map { ISMEvent(report: $0, protocolNumber: device.protocolNumber, sampleIndex: start, isFSK: isFSK) }
            }
            if !events.isEmpty { break }
        }
        return events
    }
}
