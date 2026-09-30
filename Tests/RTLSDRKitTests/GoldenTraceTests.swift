// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRKit

/// Runs a session on the driver, against a fake dongle, the way `rtl_sdr` runs one, and requires every register
/// to end up exactly where the real `rtl_sdr` left it on real hardware (recorded traces in Resources/golden).
struct GoldenTraceTests {
    struct Session: Sendable, CustomTestStringConvertible {
        let name: String            // trace file
        let frequency: Int
        let rate: Int
        let gainTenthsDB: Int?      // nil = automatic
        let ppm: Int
        var testDescription: String { name }
    }

    static let sessions: [Session] = [
        Session(name: "fm-100M-2048k-g297", frequency: 100_000_000, rate: 2_048_000, gainTenthsDB: 297, ppm: 0),
        Session(name: "uhf-433M-250k-auto", frequency: 433_920_000, rate: 250_000, gainTenthsDB: nil, ppm: 0),
        Session(name: "adsb-1090M-2400k-g496", frequency: 1_090_000_000, rate: 2_400_000, gainTenthsDB: 496, ppm: 0),
        Session(name: "voice-162M-1024k-g207-ppm5", frequency: 162_550_000, rate: 1_024_000, gainTenthsDB: 207, ppm: 5),
        Session(name: "low-30M-2048k-auto", frequency: 30_000_000, rate: 2_048_000, gainTenthsDB: nil, ppm: 0),
        Session(name: "high-1700M-3200k-g372", frequency: 1_700_000_000, rate: 3_200_000, gainTenthsDB: 372, ppm: 0),
        Session(name: "trunk-851M-1200k-g09", frequency: 851_012_500, rate: 1_200_000, gainTenthsDB: 9, ppm: 0),
    ]

    /// The order `rtl_sdr` uses: sample rate, frequency, gain, then ppm, then start the stream.
    private func run(_ session: Session) throws -> [Transfer] {
        let fake = RecordingTransport()
        let device = try RTLSDRDevice(transport: fake)
        try device.setSampleRate(session.rate)
        try device.setCenterFrequency(session.frequency)
        if let gain = session.gainTenthsDB { try device.setTunerGain(tenthsDB: gain) } else { try device.setAutomaticGain() }
        if session.ppm != 0 { try device.setFrequencyCorrection(ppm: session.ppm) }
        try device.startStreaming { _ in }
        device.stopStreaming()
        device.close()
        return fake.transfers
    }

    @Test("a whole session leaves the registers as rtl_sdr does", arguments: sessions)
    func sessionMatchesRtlSdr(session: Session) throws {
        let golden = RegisterFile(try goldenTrace(named: session.name))
        let ours = RegisterFile(try run(session))
        let differences = ours.differences(from: golden)
        #expect(differences.isEmpty, "\(differences.joined(separator: "\n"))")
    }

    @Test("the registers at the moment streaming starts match too, not just the final state", arguments: sessions)
    func registersAtStreamStartMatch(session: Session) throws {
        let golden = RegisterFile(try goldenTrace(named: session.name), upTo: isBufferReset)
        let ours = RegisterFile(try run(session), upTo: isBufferReset)
        let differences = ours.differences(from: golden)
        #expect(differences.isEmpty, "\(differences.joined(separator: "\n"))")
    }
}
