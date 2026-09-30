// SPDX-License-Identifier: GPL-2.0-or-later

/// A dongle that is plugged in.
public struct RTLSDRDeviceInfo: Sendable, Equatable, Hashable {
    public var vendorID: UInt16
    public var productID: UInt16
    /// Marketing name from the built-in table of known dongles.
    public var name: String
    public var manufacturer: String
    public var product: String
    public var serial: String
    public var locationID: UInt32
    /// Identifies this exact device in the I/O Registry (so it can be reopened).
    public var registryEntryID: UInt64
}
