#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Regenerates Sources/RTLSDRKit/R820TTables.swift and KnownDevices.swift from librtlsdr's published tables.

    Tools/generate-tables.py <directory holding librtlsdr.c and tuner_r82xx.c> [--check]

Without --check the two files are rewritten. With --check nothing is written; the exit status says whether the
files in the repository are exactly what this script produces from that source (the repository's tests do not
need the reference source; this is how the tables' provenance can be re-verified).

The tables are hardware constants (which RF band settings the R820T needs at which frequency, which USB IDs
belong to RTL2832U dongles), extracted mechanically. No logic is copied. See PROVENANCE.md.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "Sources" / "RTLSDRKit"


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def parse_bands(tuner_source: str):
    body = re.search(r"freq_ranges\[\]\s*=\s*\{(.*?)\n\};", tuner_source, re.S).group(1)
    bands = []
    for entry in re.findall(r"\{(.*?)\}", strip_comments(body), re.S):
        numbers = [int(token, 0) for token in re.findall(r"0x[0-9a-fA-F]+|\d+", entry)]
        if len(numbers) != 7:
            sys.exit(f"unexpected band entry: {entry!r}")
        bands.append(numbers)
    return bands


def parse_initial_registers(tuner_source: str):
    body = re.search(r"r82xx_init_array\[NUM_REGS\]\s*=\s*\{(.*?)\};", tuner_source, re.S).group(1)
    return [int(token, 16) for token in re.findall(r"0x[0-9a-fA-F]{2}", strip_comments(body))]


def parse_devices(library_source: str):
    body = re.search(r"known_devices\[\]\s*=\s*\{(.*?)\n\};", library_source, re.S).group(1)
    return [(int(v, 16), int(p, 16), n) for v, p, n in re.findall(r'\{\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*"([^"]*)"\s*\}', body)]


def tables_swift(bands, registers) -> str:
    rows = "\n".join(
        f"        Band(startMHz: {b[0]}, openDrain: 0x{b[1]:02x}, rfMuxPolyMux: 0x{b[2]:02x}, trackingFilter: 0x{b[3]:02x}, "
        f"crystalCap20pF: 0x{b[4]:02x}, crystalCap10pF: 0x{b[5]:02x}, crystalCap0pF: 0x{b[6]:02x})," for b in bands)
    values = ", ".join(f"0x{v:02x}" for v in registers)
    return f"""// SPDX-License-Identifier: GPL-2.0-or-later
//
// R820T RF front-end tuning table (one row per start frequency).
// GENERATED from the reference implementation's published table by Tools/generate-tables.py and checked
// into the repository; see PROVENANCE.md. These are hardware constants, not code.

enum R820TTables {{
    /// One tuning band. `startMHz` is where the band begins.
    struct Band: Sendable {{
        let startMHz: Int
        let openDrain: UInt8
        let rfMuxPolyMux: UInt8
        let trackingFilter: UInt8
        let crystalCap20pF: UInt8
        let crystalCap10pF: UInt8
        let crystalCap0pF: UInt8
    }}

    static let bands: [Band] = [
{rows}
    ]

    /// Power-on register values, starting at register 0x05.
    static let initialRegisters: [UInt8] = [{values}]
}}
"""


def devices_swift(devices) -> str:
    rows = "\n".join(f'        Entry(vendorID: 0x{v:04x}, productID: 0x{p:04x}, name: "{n}"),' for v, p, n in devices)
    return f"""// SPDX-License-Identifier: GPL-2.0-or-later
//
// USB vendor/product IDs of dongles built around the RTL2832U, and their marketing names.
// GENERATED from the reference implementation's published list by Tools/generate-tables.py; see PROVENANCE.md.

enum KnownDevices {{
    struct Entry: Sendable {{
        let vendorID: UInt16
        let productID: UInt16
        let name: String
    }}

    static let all: [Entry] = [
{rows}
    ]

    static func name(vendorID: UInt16, productID: UInt16) -> String? {{
        all.first {{ $0.vendorID == vendorID && $0.productID == productID }}?.name
    }}
}}
"""


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check = "--check" in sys.argv
    if len(args) != 1:
        print(__doc__)
        return 2
    source = Path(args[0])
    tuner = (source / "tuner_r82xx.c").read_text()
    library = (source / "librtlsdr.c").read_text()

    # The reference declares 30 registers but lists 27 values; the rest are zero and the driver pads them itself.
    outputs = {
        ROOT / "R820TTables.swift": tables_swift(parse_bands(tuner), parse_initial_registers(tuner)),
        ROOT / "KnownDevices.swift": devices_swift(parse_devices(library)),
    }
    stale = [path for path, text in outputs.items() if not path.exists() or path.read_text() != text]
    if check:
        for path in stale:
            print(f"differs from the reference: {path.name}")
        print("tables match the reference" if not stale else "MISMATCH")
        return 1 if stale else 0
    for path, text in outputs.items():
        path.write_text(text)
        print(f"wrote {path.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
