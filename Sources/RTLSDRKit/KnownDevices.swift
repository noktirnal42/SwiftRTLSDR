// SPDX-License-Identifier: GPL-2.0-or-later
//
// USB vendor/product IDs of dongles built around the RTL2832U, and their marketing names.
// GENERATED from the reference implementation's published list by Tools/generate-tables.py; see PROVENANCE.md.

enum KnownDevices {
    struct Entry: Sendable {
        let vendorID: UInt16
        let productID: UInt16
        let name: String
    }

    static let all: [Entry] = [
        Entry(vendorID: 0x0bda, productID: 0x2832, name: "Generic RTL2832U"),
        Entry(vendorID: 0x0bda, productID: 0x2838, name: "Generic RTL2832U OEM"),
        Entry(vendorID: 0x0413, productID: 0x6680, name: "DigitalNow Quad DVB-T PCI-E card"),
        Entry(vendorID: 0x0413, productID: 0x6f0f, name: "Leadtek WinFast DTV Dongle mini D"),
        Entry(vendorID: 0x0458, productID: 0x707f, name: "Genius TVGo DVB-T03 USB dongle (Ver. B)"),
        Entry(vendorID: 0x0ccd, productID: 0x00a9, name: "Terratec Cinergy T Stick Black (rev 1)"),
        Entry(vendorID: 0x0ccd, productID: 0x00b3, name: "Terratec NOXON DAB/DAB+ USB dongle (rev 1)"),
        Entry(vendorID: 0x0ccd, productID: 0x00b4, name: "Terratec Deutschlandradio DAB Stick"),
        Entry(vendorID: 0x0ccd, productID: 0x00b5, name: "Terratec NOXON DAB Stick - Radio Energy"),
        Entry(vendorID: 0x0ccd, productID: 0x00b7, name: "Terratec Media Broadcast DAB Stick"),
        Entry(vendorID: 0x0ccd, productID: 0x00b8, name: "Terratec BR DAB Stick"),
        Entry(vendorID: 0x0ccd, productID: 0x00b9, name: "Terratec WDR DAB Stick"),
        Entry(vendorID: 0x0ccd, productID: 0x00c0, name: "Terratec MuellerVerlag DAB Stick"),
        Entry(vendorID: 0x0ccd, productID: 0x00c6, name: "Terratec Fraunhofer DAB Stick"),
        Entry(vendorID: 0x0ccd, productID: 0x00d3, name: "Terratec Cinergy T Stick RC (Rev.3)"),
        Entry(vendorID: 0x0ccd, productID: 0x00d7, name: "Terratec T Stick PLUS"),
        Entry(vendorID: 0x0ccd, productID: 0x00e0, name: "Terratec NOXON DAB/DAB+ USB dongle (rev 2)"),
        Entry(vendorID: 0x1554, productID: 0x5020, name: "PixelView PV-DT235U(RN)"),
        Entry(vendorID: 0x15f4, productID: 0x0131, name: "Astrometa DVB-T/DVB-T2"),
        Entry(vendorID: 0x15f4, productID: 0x0133, name: "HanfTek DAB+FM+DVB-T"),
        Entry(vendorID: 0x185b, productID: 0x0620, name: "Compro Videomate U620F"),
        Entry(vendorID: 0x185b, productID: 0x0650, name: "Compro Videomate U650F"),
        Entry(vendorID: 0x185b, productID: 0x0680, name: "Compro Videomate U680F"),
        Entry(vendorID: 0x1b80, productID: 0xd393, name: "GIGABYTE GT-U7300"),
        Entry(vendorID: 0x1b80, productID: 0xd394, name: "DIKOM USB-DVBT HD"),
        Entry(vendorID: 0x1b80, productID: 0xd395, name: "Peak 102569AGPK"),
        Entry(vendorID: 0x1b80, productID: 0xd397, name: "KWorld KW-UB450-T USB DVB-T Pico TV"),
        Entry(vendorID: 0x1b80, productID: 0xd398, name: "Zaapa ZT-MINDVBZP"),
        Entry(vendorID: 0x1b80, productID: 0xd39d, name: "SVEON STV20 DVB-T USB & FM"),
        Entry(vendorID: 0x1b80, productID: 0xd3a4, name: "Twintech UT-40"),
        Entry(vendorID: 0x1b80, productID: 0xd3a8, name: "ASUS U3100MINI_PLUS_V2"),
        Entry(vendorID: 0x1b80, productID: 0xd3af, name: "SVEON STV27 DVB-T USB & FM"),
        Entry(vendorID: 0x1b80, productID: 0xd3b0, name: "SVEON STV21 DVB-T USB & FM"),
        Entry(vendorID: 0x1d19, productID: 0x1101, name: "Dexatek DK DVB-T Dongle (Logilink VG0002A)"),
        Entry(vendorID: 0x1d19, productID: 0x1102, name: "Dexatek DK DVB-T Dongle (MSI DigiVox mini II V3.0)"),
        Entry(vendorID: 0x1d19, productID: 0x1103, name: "Dexatek Technology Ltd. DK 5217 DVB-T Dongle"),
        Entry(vendorID: 0x1d19, productID: 0x1104, name: "MSI DigiVox Micro HD"),
        Entry(vendorID: 0x1f4d, productID: 0xa803, name: "Sweex DVB-T USB"),
        Entry(vendorID: 0x1f4d, productID: 0xb803, name: "GTek T803"),
        Entry(vendorID: 0x1f4d, productID: 0xc803, name: "Lifeview LV5TDeluxe"),
        Entry(vendorID: 0x1f4d, productID: 0xd286, name: "MyGica TD312"),
        Entry(vendorID: 0x1f4d, productID: 0xd803, name: "PROlectrix DV107669"),
    ]

    static func name(vendorID: UInt16, productID: UInt16) -> String? {
        all.first { $0.vendorID == vendorID && $0.productID == productID }?.name
    }
}
