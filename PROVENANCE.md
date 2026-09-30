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
| ISM sensor decoders (`RTLSDRDecoders/ISM`): envelope and FM baseband, OOK/FSK pulse detection, pulse slicers, bit buffer, checksums, the receive loop and decoder priorities, JSON output, 11 device protocols | rtl_433 release 25.02, GPL-2.0-or-later (https://github.com/merbanan/rtl_433): `baseband.c`, `pulse_detect.c`, `pulse_detect_fsk.c`, `pulse_data.c`, `pulse_slicer.c`, `bitbuffer.c`, `bit_util.c`, `rtl_433.c`, `r_api.c`, `output_file.c`, `fileformat.c` and `devices/` `rubicson.c`, `oregon_scientific.c`, `fineoffset.c`, `nexus.c`, `ambient_weather.c`, `generic_remote.c`, `acurite.c`, `lacrosse_tx141x.c`, `bresser_5in1.c`, `bresser_6in1.c` | Ported to Swift, keeping the fixed-point and single-precision arithmetic so that both find the same packages and print the same numbers; provenance comments in each file. Every ported file says "version 2 of the License, or (at your option) any later version". rtl_433 itself is the oracle: its output on the rtl_433_tests recordings must match byte for byte (see docs/DECODERS.md). |
| ISM test vectors | Bit buffers the decoders saw in [rtl_433_tests](https://github.com/merbanan/rtl_433_tests) recordings, with rtl_433's output for each (`Tools/generate-ism-vectors.py`) | Short bit strings and decoded values only. The recordings are not included: that repository has no licence. |
| Meteor-M LRPT demodulator (`RTLSDRDecoders/LRPT/LRPTDemodulator.swift`): AGC, root-raised-cosine filter, carrier loop, symbol clock, fixed-point sine | meteor_demod by dbdexter-dev, MIT (https://github.com/dbdexter-dev/meteor_demod, commit `bf8f6eb`, 2021-06-03): `demod.c`, `dsp/agc.c`, `dsp/filter.c`, `dsp/pll.c`, `dsp/timing.c`, `dsp/sincos.c` | Ported to Swift, keeping its arithmetic. The coarse carrier search that starts the loop and moves it off false locks (`LRPTCarrierSearch`) is new. |
| LRPT frames, packets and images (`LRPTFrames`, `ConvolutionalCode`, `LRPTPackets`, `MSUMR`): marker correlator, Viterbi decoder, derandomiser, M_PDU parser, MSU-MR Huffman decoding and fixed-point IDCT, channel assembly and composite | meteor_decode by dbdexter-dev, MIT (https://github.com/dbdexter-dev/meteor_decode, commit `e7ca456`, 2021-09-04): `decode.c`, `correlator/correlator.c`, `utils.c`, `ecc/viterbi.c`, `ecc/descramble.c`, `parser/mpdu_parser.c`, `parser/mcu_parser.c`, `jpeg/huffman.c`, `jpeg/jpeg.c`, `channel.c`, `main.c` | Ported, with provenance comments in each file; meteor_decode is also the oracle (same frames, pixel-identical images on a real recording). New: the mirrored phases, the search around the expected marker, the marker written as sent. MIT is compatible with GPL-2.0-or-later; the notice is in NOTICE. |
| NRZ-M decoding for Meteor-M N2-3/N2-4 (on the bits after the Viterbi decoder), CCSDS Reed-Solomon parameters for LRPT (conventional basis, β = α¹¹, first root 112) | SatDump (GPL-3.0, https://github.com/SatDump/SatDump) was read for these format facts only, and the CCSDS TM synchronisation and channel coding standard (131.0-B) for the code | No SatDump code was taken. SatDump 1.2.2, built from Ubuntu's source package `satdump_1.2.2.orig.tar.gz` (SHA-256 `2ab7c6126e426ad79972b274cc380c0bb04c9e755d746d67f3af92c1dd569209`), was run as an oracle (see docs/DECODERS.md). |
| LRPT test signals and data (`Tools/lrpt-oracle.py`, `Tools/lrpt-encode.py`, `lrpt-scene.cadu`) | Written for this package from the format descriptions above; reedsolo computes the parity | New. The real recording used for comparison (from the YAM2D repository) is not included: it has no licence. |
| Dashboard (`rtlsdr-tool meteor --web`), HTTP server (`RTLSDRServer/HTTPServer.swift`) | Written for this package | New. SatDump's live view was the prompt for having one; none of its code or layout was used. |
| Tests, fake dongle, trace logger, CLI, tools | Written for this package | New. |
| Golden traces | Recorded from an unmodified `rtl_sdr` (Homebrew librtlsdr 2.0.2) on real hardware | Test data: what the reference wrote on the wire. |

The rtl_433 source ported is release 25.02 from Ubuntu's source package `rtl-433_25.02.orig.tar.gz` (SHA-256
`5a409ea10e6d3d7d4aa5ea91d2d6cc92ebb2d730eb229c7b37ade65458223432`).

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
`librtlsdr/librtlsdr` community fork (harmonic reception, extra gain stages), or from `rtl_power`/`rtl_fm`.
Those were read for background only (see LEVEL-DIFFERENCES.md for what was learned and cited). rtl_433 is the source of
the ISM decoders, and dbdexter-dev's programs of the LRPT decoder, as listed above, but nothing of them is in the driver
itself. Other Meteor projects were searched for test recordings only (MeteorDemod, meteor_decoder, weatherdump, YAM2D);
none contributed code, and the one recording used (YAM2D's) is not included.
