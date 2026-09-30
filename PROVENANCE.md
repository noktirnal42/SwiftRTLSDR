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
| Tests, fake dongle, trace logger, CLI, tools | Written for this package | New. |
| Golden traces | Recorded from an unmodified `rtl_sdr` (Homebrew librtlsdr 2.0.2) on real hardware | Test data: what the reference wrote on the wire. |

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
