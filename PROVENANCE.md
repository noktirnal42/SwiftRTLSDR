# Provenance

Where everything in this package came from, so nobody has to guess and nobody is misled.

## The short version

This is a **port**, not a clean-room design. The register-level behaviour of the RTL2832U and the R820T was learned
by reading [librtlsdr](https://github.com/osmocom/rtl-sdr) (GPL-2.0-or-later), and this package reproduces that
behaviour in Swift. It is therefore a derivative work and is licensed accordingly (GPL-2.0-or-later). The upstream
copyright holders are named in [NOTICE](NOTICE). No vendor datasheet for the RTL2832U or the R820T was consulted;
register meanings come from the reference driver's code and comments.

## What came from where

| Part | Source | How |
|---|---|---|
| R820T tuning table (`R820TTables.bands`), power-on register values | `tuner_r82xx.c` in librtlsdr (Mauro Carvalho Chehab, Steve Markgraf; derived from the Linux kernel's `r820t.c`) | Extracted mechanically by `Tools/generate-tables.py`; `--check` proves the checked-in file is exactly its output. Hardware constants. |
| USB ID list (`KnownDevices`) | `librtlsdr.c` | Extracted mechanically by the same script. |
| R820T logic: PLL programming, IF filter selection, gain stepping, filter calibration, standby, shadow-register handling | `tuner_r82xx.c` | Re-written in Swift with a different structure (pure planning functions plus thin hardware writers). The algorithms and constants follow the reference; this is a port. |
| RTL2832U logic: baseband initialisation, resampler ratio, IF word, ppm word, FIR packing, GPIO, buffer reset, power-down | `librtlsdr.c` | Same: re-written in Swift, algorithms and register values follow the reference. |
| Gain table (29 steps) | The list a real R820T dongle reports through `rtl_test`, cross-checked against the reference tables | Recorded from hardware. |
| USB transport | Written for this package on Apple's `IOUSBHost` (control transfers, queued asynchronous bulk reads) | New. The reference uses `libusb`. |
| EEPROM layout and access (`EEPROMImage`, `readEEPROM`, `writeEEPROM`) | `rtl_eeprom.c` (layout, string descriptors, the 78-byte limit) and `librtlsdr.c` (`rtlsdr_read_eeprom`/`rtlsdr_write_eeprom`: address 0xa0, one byte per transfer, write only changed bytes, 5 ms between writes) | Ported. Deliberate differences: the header (bytes 0-8) is never written (`rtl_eeprom` regenerates bytes 7 and 8 when it sets a serial), and every write is verified by reading the whole EEPROM back. |
| `rtl_tcp` protocol (`RTLSDRServer`) | `rtl_tcp.c` (header, command codes and their meaning) | The protocol is re-implemented; the server's structure (POSIX sockets, bounded drop-oldest queue, one client, bias tee off by default) is new. |
| Retune shortcuts | Written for this package | New, and a deliberate departure from the reference's retune sequence (off by default; see `RTLSDRDevice.RetuneShortcuts`). |
| Sample statistics, gain loop, host gain control, FFT, sweep planning, peak detection, scan loop | Written for this package | New. `radiosonde_auto_rx` was the model for the scan-then-decode idea only; none of its code was read. |
| Mode S / ADS-B decoder (`RTLSDRDecoders/ModeS`) | ICAO Annex 10 Vol. IV as laid out in Junzi Sun, *The 1090 MHz Riddle* (2nd ed., TU Delft OPEN, 2021) | Written from those descriptions. No dump1090 or pyModeS code was read or ported; both serve only as oracles (pyModeS 3.6.0 produced expected values in the test data; dump1090-mutability decoded the same synthetic frames, see docs/DECODERS.md). |
| UAT decoder: framing, demodulation method, ADS-B and uplink/FIS-B message layouts, NEXRAD block geometry (`RTLSDRDecoders/UAT`) | dump978 by Oliver Jowett, GPL-2.0-or-later (https://github.com/mutability/dump978): `uat.h`, `fec.c`, `dump978.c`, `uat_decode.c`, `extract_nexrad.c`, `plot_nexrad.py` | Ported to Swift, with provenance comments in each file. The formal specifications (RTCA DO-282, DO-358) are not public. dump978's own decoder and `extract_nexrad` are the test oracles (all 1143 sample frames and 720 NEXRAD blocks must match). |
| UAT aircraft size table | DO-282B Table 2-35 as used in FlightAware's dump978 (BSD-2-Clause, https://github.com/flightaware/dump978) | 16 (length, width) pairs; the original dump978 decoded the length from the wrong bits. |
| Reed-Solomon codec (`ReedSolomon.swift`) | Textbook algorithms (Berlekamp-Massey, Chien, Forney) | Written for this package. dump978 uses Phil Karn's LGPL library; that library was compiled only as a test oracle. Parameters (polynomial 0x187, first root 120) are dump978's. |
| UAT test data | `sample-data.txt.gz` from dump978 (GPL-2.0-or-later) | Real frames, included uncompressed as test data. |
| Tests, fake dongle, trace logger, CLI, tools | Written for this package | New. |
| Golden traces | Recorded from an unmodified `rtl_sdr` (Homebrew librtlsdr 2.0.2) on real hardware | Test data: what the reference wrote on the wire. |

The librtlsdr source consulted for the EEPROM and `rtl_tcp` work (2026-09-30) is release 2.0.2, the version the golden
traces were recorded with, taken from Ubuntu's source package `rtl-sdr_2.0.2.orig.tar.xz` (SHA-256
`b40e5113231fbda333f2c69dd576c3dded54cf5a98f3750a0d4042cc870e792a`).

## How the port was checked

The reference source was read, ported, and then checked against **real wire traffic** rather than against the source:
every USB control transfer of the real `rtl_sdr` was recorded (`Tools/trace-librtlsdr.c`) and this driver's sessions
are required to leave the same register state (see the README). That process found and fixed two mismatches that
reading alone had missed (the crystal-corrected tuner PLL under a ppm correction, and the demodulator power-down on
close). It also showed where this driver deliberately differs from the reference:

* It does not probe for E4000/FC0013 tuners (it supports only the R820T).
* It skips register writes that would change nothing.
* It does not reproduce librtlsdr's start-up retune to 0 Hz (the source of the `[R82XX] PLL not locked!` message),
  which leaves the tuner in a slightly different analog state; see [docs/LEVEL-DIFFERENCES.md](docs/LEVEL-DIFFERENCES.md).

## Things not taken

Nothing from `libusb`, from the RTL-SDR Blog fork's changes (V3/V4 support, VCO-current rewrite), from the
`librtlsdr/librtlsdr` community fork (harmonic reception, extra gain stages), or from `rtl_433`/`rtl_power`/`rtl_fm`.
Those were read for background only (see LEVEL-DIFFERENCES.md for what was learned and cited).
