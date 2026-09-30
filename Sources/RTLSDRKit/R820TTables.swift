// SPDX-License-Identifier: GPL-2.0-or-later
//
// R820T RF front-end tuning table (one row per start frequency).
// GENERATED from the reference implementation's published table by Tools/generate-tables.py and checked
// into the repository; see PROVENANCE.md. These are hardware constants, not code.

enum R820TTables {
    /// One tuning band. `startMHz` is where the band begins.
    struct Band: Sendable {
        let startMHz: Int
        let openDrain: UInt8
        let rfMuxPolyMux: UInt8
        let trackingFilter: UInt8
        let crystalCap20pF: UInt8
        let crystalCap10pF: UInt8
        let crystalCap0pF: UInt8
    }

    static let bands: [Band] = [
        Band(startMHz: 0, openDrain: 0x08, rfMuxPolyMux: 0x02, trackingFilter: 0xdf, crystalCap20pF: 0x02, crystalCap10pF: 0x01, crystalCap0pF: 0x00),
        Band(startMHz: 50, openDrain: 0x08, rfMuxPolyMux: 0x02, trackingFilter: 0xbe, crystalCap20pF: 0x02, crystalCap10pF: 0x01, crystalCap0pF: 0x00),
        Band(startMHz: 55, openDrain: 0x08, rfMuxPolyMux: 0x02, trackingFilter: 0x8b, crystalCap20pF: 0x02, crystalCap10pF: 0x01, crystalCap0pF: 0x00),
        Band(startMHz: 60, openDrain: 0x08, rfMuxPolyMux: 0x02, trackingFilter: 0x7b, crystalCap20pF: 0x02, crystalCap10pF: 0x01, crystalCap0pF: 0x00),
        Band(startMHz: 65, openDrain: 0x08, rfMuxPolyMux: 0x02, trackingFilter: 0x69, crystalCap20pF: 0x02, crystalCap10pF: 0x01, crystalCap0pF: 0x00),
        Band(startMHz: 70, openDrain: 0x08, rfMuxPolyMux: 0x02, trackingFilter: 0x58, crystalCap20pF: 0x02, crystalCap10pF: 0x01, crystalCap0pF: 0x00),
        Band(startMHz: 75, openDrain: 0x00, rfMuxPolyMux: 0x02, trackingFilter: 0x44, crystalCap20pF: 0x02, crystalCap10pF: 0x01, crystalCap0pF: 0x00),
        Band(startMHz: 80, openDrain: 0x00, rfMuxPolyMux: 0x02, trackingFilter: 0x44, crystalCap20pF: 0x02, crystalCap10pF: 0x01, crystalCap0pF: 0x00),
        Band(startMHz: 90, openDrain: 0x00, rfMuxPolyMux: 0x02, trackingFilter: 0x34, crystalCap20pF: 0x01, crystalCap10pF: 0x01, crystalCap0pF: 0x00),
        Band(startMHz: 100, openDrain: 0x00, rfMuxPolyMux: 0x02, trackingFilter: 0x34, crystalCap20pF: 0x01, crystalCap10pF: 0x01, crystalCap0pF: 0x00),
        Band(startMHz: 110, openDrain: 0x00, rfMuxPolyMux: 0x02, trackingFilter: 0x24, crystalCap20pF: 0x01, crystalCap10pF: 0x01, crystalCap0pF: 0x00),
        Band(startMHz: 120, openDrain: 0x00, rfMuxPolyMux: 0x02, trackingFilter: 0x24, crystalCap20pF: 0x01, crystalCap10pF: 0x01, crystalCap0pF: 0x00),
        Band(startMHz: 140, openDrain: 0x00, rfMuxPolyMux: 0x02, trackingFilter: 0x14, crystalCap20pF: 0x01, crystalCap10pF: 0x01, crystalCap0pF: 0x00),
        Band(startMHz: 180, openDrain: 0x00, rfMuxPolyMux: 0x02, trackingFilter: 0x13, crystalCap20pF: 0x00, crystalCap10pF: 0x00, crystalCap0pF: 0x00),
        Band(startMHz: 220, openDrain: 0x00, rfMuxPolyMux: 0x02, trackingFilter: 0x13, crystalCap20pF: 0x00, crystalCap10pF: 0x00, crystalCap0pF: 0x00),
        Band(startMHz: 250, openDrain: 0x00, rfMuxPolyMux: 0x02, trackingFilter: 0x11, crystalCap20pF: 0x00, crystalCap10pF: 0x00, crystalCap0pF: 0x00),
        Band(startMHz: 280, openDrain: 0x00, rfMuxPolyMux: 0x02, trackingFilter: 0x00, crystalCap20pF: 0x00, crystalCap10pF: 0x00, crystalCap0pF: 0x00),
        Band(startMHz: 310, openDrain: 0x00, rfMuxPolyMux: 0x41, trackingFilter: 0x00, crystalCap20pF: 0x00, crystalCap10pF: 0x00, crystalCap0pF: 0x00),
        Band(startMHz: 450, openDrain: 0x00, rfMuxPolyMux: 0x41, trackingFilter: 0x00, crystalCap20pF: 0x00, crystalCap10pF: 0x00, crystalCap0pF: 0x00),
        Band(startMHz: 588, openDrain: 0x00, rfMuxPolyMux: 0x40, trackingFilter: 0x00, crystalCap20pF: 0x00, crystalCap10pF: 0x00, crystalCap0pF: 0x00),
        Band(startMHz: 650, openDrain: 0x00, rfMuxPolyMux: 0x40, trackingFilter: 0x00, crystalCap20pF: 0x00, crystalCap10pF: 0x00, crystalCap0pF: 0x00),
    ]

    /// Power-on register values, starting at register 0x05.
    static let initialRegisters: [UInt8] = [0x83, 0x32, 0x75, 0xc0, 0x40, 0xd6, 0x6c, 0xf5, 0x63, 0x75, 0x68, 0x6c, 0x83, 0x80, 0x00, 0x0f, 0x00, 0xc0, 0x30, 0x48, 0xcc, 0x60, 0x00, 0x54, 0xae, 0x4a, 0xc0]
}
