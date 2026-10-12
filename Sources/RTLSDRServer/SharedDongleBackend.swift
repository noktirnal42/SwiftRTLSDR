// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import RTLSDRKit

/// A command or stream request the owner of the dongle does not allow a network client to make. The server reports it
/// as `refused`, not as a failure.
public struct RemoteRefusal: Error, LocalizedError, Equatable, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// What a network client may do to a dongle an app is already streaming from (SH-10).
///
/// **Contract, for the app that owns the dongle:**
/// - Publish every block of your stream to the `IQFanOut` you give here: call `open()` when the device starts streaming,
///   `publish` from your streaming handler, and `finish()` when it stops. Clients get copies, and a slow one loses only its
///   own oldest blocks.
/// - The server calls `startStreaming` on its client-session thread when a client connects. This backend never starts or
///   stops the dongle; a client's `stopStreaming` only detaches that client. If the owner's stream has ended, the client is
///   refused; if it ends later, the client's `onError` is called once with `RemoteRefusal`.
/// - Remote commands (frequency, sample rate, gain, correction, bias tee) come from the client's thread. With the default
///   `.refuse` they are turned away and the dongle is not touched, so the owner keeps its settings. With `.apply(onChange:)`
///   they reach the dongle, and `onChange` is called on that same thread with a description of the change. Your settings
///   UI must re-read the device after it hears from `onChange`; the stream's sample rate or frequency may have moved.
/// - `blockSize` and `bufferCount` from the server are ignored: the owner's stream sets them.
public final class SharedDongleBackend: RTLTCPBackend, @unchecked Sendable {

    public enum RemoteControl: Sendable {
        /// Remote commands are refused (the default). The owner keeps the dongle's settings.
        case refuse
        /// Remote commands are applied to the dongle; `onChange` says what changed.
        case apply(onChange: @Sendable (String) -> Void)
    }

    private let dongle: RTLTCPBackend
    private let stream: IQFanOut
    private let remoteControl: RemoteControl
    private let lock = NSLock()
    /// The client's subscription while it is streaming, so `stopStreaming` can end it.
    private var relay: IQFanOut.Subscriber?

    /// - Parameters:
    ///   - dongle: the dongle, as the owner has it (an `RTLSDRDevice` in the app).
    ///   - stream: the fan-out the owner publishes its stream to.
    public init(dongle: RTLTCPBackend, stream: IQFanOut, remoteControl: RemoteControl = .refuse) {
        self.dongle = dongle
        self.stream = stream
        self.remoteControl = remoteControl
    }

    public var rtlTCPTunerType: UInt32 { dongle.rtlTCPTunerType }
    public var supportedGains: [Int] { dongle.supportedGains }

    private static let refusedWhileStreaming = "the owner of this dongle is streaming; remote control is refused"

    /// Whether a remote command may go through; returns the callback to report it to (`.apply` only).
    private func gate() throws -> (@Sendable (String) -> Void)? {
        switch remoteControl {
        case .refuse: throw RemoteRefusal(reason: Self.refusedWhileStreaming)
        case let .apply(onChange): return onChange
        }
    }

    public func setCenterFrequency(_ hertz: Int) throws {
        let report = try gate()
        try dongle.setCenterFrequency(hertz)
        report?("centre frequency \(hertz) Hz")
    }

    @discardableResult
    public func setSampleRate(_ rate: Int) throws -> Double {
        let report = try gate()
        let actual = try dongle.setSampleRate(rate)
        report?("sample rate \(actual) S/s")
        return actual
    }

    public func setAutomaticGain() throws {
        let report = try gate()
        try dongle.setAutomaticGain()
        report?("automatic gain")
    }

    public func setTunerGain(tenthsDB: Int) throws {
        let report = try gate()
        try dongle.setTunerGain(tenthsDB: tenthsDB)
        report?("tuner gain \(Double(tenthsDB) / 10) dB")
    }

    public func setFrequencyCorrection(ppm: Int) throws {
        let report = try gate()
        try dongle.setFrequencyCorrection(ppm: ppm)
        report?("frequency correction \(ppm) ppm")
    }

    public func setBiasTee(_ on: Bool) throws {
        let report = try gate()
        try dongle.setBiasTee(on)
        report?("bias tee \(on ? "on" : "off")")
    }

    public func startStreaming(blockSize: Int, bufferCount: Int, onError: (@Sendable (Error) -> Void)?,
                               handler: @escaping @Sendable (UnsafeBufferPointer<UInt8>) -> Void) throws {
        guard let subscriber = stream.subscribe() else { throw RemoteRefusal(reason: "the owner of this dongle is not streaming") }
        lock.lock()
        let previous = relay
        relay = subscriber
        lock.unlock()
        previous?.cancel()
        Thread.detachNewThread { [self] in
            while let block = subscriber.next() {
                block.withUnsafeBufferPointer { handler($0) }
            }
            // Ended by the owner, not by this client: tell the client once. A client's own stop clears `relay` first.
            lock.lock()
            let endedByOwner = relay === subscriber
            if endedByOwner { relay = nil }
            lock.unlock()
            if endedByOwner { onError?(RemoteRefusal(reason: "the owner stopped streaming")) }
        }
    }

    /// Detaches this client only. The owner's stream carries on.
    public func stopStreaming() {
        lock.lock()
        let current = relay
        relay = nil
        lock.unlock()
        current?.cancel()
    }
}
