// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Merges Mode S messages into one record per aircraft, like the table `dump1090 --interactive` shows.
///
/// Positions come from an even and an odd CPR fix less than 10 s apart whenever such a pair exists (global decoding needs
/// no reference, so it also corrects a wrong track); otherwise from one fix and the aircraft's recent position; otherwise
/// from one fix and the receiver's location. A position resting on the receiver's location is `positionIsProvisional`
/// until a pair confirms it, because an aircraft more than about 180 NM away resolves to a wrong, mirrored position.
/// A position that would need more than `maximumSpeedKnots` to reach from a confirmed one is dropped as a decoding error.
public final class AircraftTracker {
    public struct Aircraft: Sendable, Equatable {
        public var address: UInt32
        public var callsign: String?
        public var squawk: String?
        public var altitudeFeet: Int?
        public var latitude: Double?
        public var longitude: Double?
        public var groundSpeedKnots: Double?
        public var trackDegrees: Double?
        public var verticalRateFPM: Int?
        public var emergency: Int?
        public var messages = 0
        public var firstSeen: Double
        public var lastSeen: Double
        public var lastPosition: Double?
        /// The position rests on the receiver's location, not yet on an even/odd pair.
        public var positionIsProvisional = false

        public var addressHex: String { String(format: "%06X", address) }
    }

    public var maximumSpeedKnots = 1_000.0
    /// Positions resolved against the receiver's location farther away than this are dropped.
    public var maximumRangeNM = 250.0
    private let receiver: (latitude: Double, longitude: Double)?
    private var records: [UInt32: Aircraft] = [:]
    private var lastFix: [UInt32: (even: (CPRPosition, Double)?, odd: (CPRPosition, Double)?)] = [:]

    /// - Parameter receiverLocation: lets the first position resolve from a single fix (it must be within about
    ///   180 NM of the aircraft).
    public init(receiverLocation: (latitude: Double, longitude: Double)? = nil) {
        receiver = receiverLocation
    }

    public var aircraft: [Aircraft] { records.values.sorted { $0.address < $1.address } }
    public subscript(address: UInt32) -> Aircraft? { records[address] }

    /// Forgets aircraft not heard from since `time - age` seconds.
    public func expire(olderThan age: Double, now time: Double) {
        records = records.filter { time - $0.value.lastSeen <= age }
        lastFix = lastFix.filter { records[$0.key] != nil }
    }

    /// Takes one message received at `time` (seconds, any monotonic clock).
    public func update(_ message: ModeSMessage, at time: Double) {
        var record = records[message.address] ?? Aircraft(address: message.address, firstSeen: time, lastSeen: time)
        record.messages += 1
        record.lastSeen = time
        switch message.content {
        case let .altitude(feet):
            if let feet { record.altitudeFeet = feet }
        case let .identity(squawk):
            record.squawk = squawk
        case let .extendedSquitter(squitter):
            apply(squitter, to: &record, at: time)
        case .allCall, .other:
            break
        }
        records[message.address] = record
    }

    private func apply(_ squitter: ExtendedSquitter, to record: inout Aircraft, at time: Double) {
        switch squitter {
        case let .identification(identification):
            if !identification.callsign.isEmpty { record.callsign = identification.callsign }
        case let .airbornePosition(position):
            if let feet = position.altitudeFeet, !position.altitudeIsGNSS { record.altitudeFeet = feet }
            resolve(position.cpr, into: &record, at: time)
        case let .velocity(velocity):
            if case let .ground(speed, track) = velocity.kind {
                record.groundSpeedKnots = speed
                record.trackDegrees = track
            }
            if let rate = velocity.verticalRateFPM { record.verticalRateFPM = rate }
        case let .emergency(state, squawk):
            record.emergency = state
            record.squawk = squawk
        case .other:
            break
        }
    }

    private func resolve(_ fix: CPRPosition, into record: inout Aircraft, at time: Double) {
        var fixes = lastFix[record.address] ?? (nil, nil)
        if fix.isOdd { fixes.odd = (fix, time) } else { fixes.even = (fix, time) }
        lastFix[record.address] = fixes

        var candidate: (latitude: Double, longitude: Double)?
        var provisional = false
        var global = false
        if let even = fixes.even, let odd = fixes.odd, abs(even.1 - odd.1) < 10,
           let position = CPR.global(even: even.0, odd: odd.0, newestIsOdd: fix.isOdd) {
            candidate = position
            global = true
        } else if let latitude = record.latitude, let longitude = record.longitude, let when = record.lastPosition, time - when < 60 {
            candidate = CPR.local(fix, reference: (latitude, longitude))
            provisional = record.positionIsProvisional
        } else if let receiver {
            let position = CPR.local(fix, reference: receiver)
            guard Self.distanceNM(receiver.latitude, receiver.longitude, position.latitude, position.longitude) <= maximumRangeNM else { return }
            candidate = position
            provisional = true
        }
        guard let candidate else { return }
        // A confirmed position limits how far the next one can be. A provisional one does not stop a global fix from
        // replacing it: that is how a mirrored first fix gets corrected.
        if let latitude = record.latitude, let longitude = record.longitude, let when = record.lastPosition,
           !(global && record.positionIsProvisional) {
            let reach = maximumSpeedKnots * max(time - when, 1) / 3600 + 5                // nautical miles, with slack
            guard Self.distanceNM(latitude, longitude, candidate.latitude, candidate.longitude) <= reach else { return }
        }
        record.latitude = candidate.latitude
        record.longitude = candidate.longitude
        record.lastPosition = time
        record.positionIsProvisional = provisional
    }

    /// Great-circle distance in nautical miles.
    static func distanceNM(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radians = Double.pi / 180
        let dLat = (lat2 - lat1) * radians, dLon = (lon2 - lon1) * radians
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * radians) * cos(lat2 * radians) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * atan2(a.squareRoot(), (1 - a).squareRoot()) * 3440.065
    }
}
