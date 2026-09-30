# Why this driver reads about 1.7 dB lower than librtlsdr (investigation, 2026-09-29)

**Status: understood well enough to document, not fully explained.** The register traffic of this driver and of
`librtlsdr` is byte-identical where it matters, yet on the one dongle tested the received level differs by a
roughly constant amount. We know *which event* in `librtlsdr`'s start-up causes its higher level. We do **not**
know the analog mechanism.

Hardware: one "Generic RTL2832U OEM" dongle (Realtek RTL2838UHIDIR, R820T tuner), no antenna attached, macOS 27.
Everything below is a single-dongle observation.

## What was measured

Same settings on both drivers: 100 MHz, 2.048 MS/s, manual tuner gain, 1 s captures, compared as mean power in dBFS.
Back-to-back repeat runs of one driver agree to about ±0.1 dB (over the session both drivers slowly drifted down together by about 2 dB, so only interleaved pairs are compared); the reference is louder in every pairing, in either run order.

| Tuner gain | native | librtlsdr | difference |
|---|---|---|---|
| 33.8 dB | −39.5 | −38.0 | −1.5 dB |
| 44.5 dB | −32.0 | −30.2 | −1.8 dB |
| 49.6 dB | −30.6 | −28.9 | −1.7 dB |

* The gain *steps* track each other one for one (including a non-monotonic 48.0 → 49.6 dB step that both show), so
  the gain table and gain programming are faithful. At low gains the difference shrinks only because the ADC's
  quantisation floor dominates with no antenna (only eight ADC codes are in use at 29.7 dB).
* The difference is flat across the band (every 128 kHz sub-band within 1.0–1.6 dB) and constant in time.
* Coherent spurs (the dongle's own 28.8 MHz crystal harmonics at 86.4 / 115.2 / 144 MHz) are also 0.7–1.8 dB lower,
  and peak-over-floor is unchanged (native 14.6 / 17.7 / 7.5 dB versus 14.2 / 16.9 / 7.6 dB). So this looks like
  a gain difference, not a sensitivity loss. With an antenna and a real signal this should be re-checked.

## How it was narrowed down

Tools (in `Tools/`): `trace-librtlsdr.c` logs every USB control transfer of an unmodified `rtl_sdr` (a
`DYLD_INSERT_LIBRARIES` shim); `RTLSDR_TRACE=<file>` makes this driver log the same format; `replay-trace.py`
replays a trace into a register file so two sessions' final register state can be diffed.

1. **Final register state is identical**: all 30 R820T registers, all demodulator registers, USB/system registers.
   (Two real differences were found and fixed on the way: `librtlsdr` writes zeros to reserved tuner registers
   0x20–0x22 because its 27-value table sits in a 30-byte array; this driver now does too.)
2. **Not the USB read path.** The first suspect: `librtlsdr` keeps 15 transfers queued, this driver first used one
   synchronous request. Moving to queued asynchronous streaming (which was needed anyway to avoid FIFO overflow)
   changed nothing. Sending the reference's *recorded control transfers* through this driver's USB layer reproduced
   the reference's level.
3. **Bisecting the recorded sequence** (replaying hybrids of the two traces, three interleaved rounds each):

   | Variant | level relative to native |
   |---|---|
   | native sequence | baseline |
   | + reference's probes for E4000 / FC0013 tuners | no change |
   | + reference's "manual gain at 0 dB" step before the real gain | no change |
   | + only `12 60` (raise VCO current) | no change |
   | + reference's early tuning episode (the failed PLL write and low-band mux writes) | **+1.5 to 2 dB, matches reference** |
   | + only the failed PLL write | +1.5 to 2 dB |
   | + only the early low-band mux/divider writes | +1.5 to 2 dB |

4. **The trigger, verified in the code.** `r820t_set_bw()` in `librtlsdr` ends with an unconditional
   `rtlsdr_set_center_freq(dev, dev->freq)`. `rtlsdr_set_sample_rate()` calls it while `dev->freq` is still 0, so
   every `rtl_sdr` start-up first "tunes" to 0 Hz + IF (3.57 MHz), which the PLL cannot lock. That is the
   `[R82XX] PLL not locked!` line everyone sees. Current Osmocom master and the RTL-SDR Blog fork both still have this;
   the community `librtlsdr/librtlsdr` fork restructured the function.
5. After lock the tuner's status register reports a VCO sub-band code that differs by one step between the two
   sessions (0x38 for `librtlsdr`, 0x37 for this driver). Under any ordinary tuning history this driver always lands on
   0x37 (tried 24, 56, 60, 150, 400 and 900 MHz first), and the level does not change. **This is a correlation.** We have not shown that the sub-band is
   the cause of the level change.

## What the literature says (searched 2026-09-29)

* `[R82XX] PLL not locked!` at start-up is widely reported and treated as benign
  ([rtl_433 discussion](https://github.com/merbanan/rtl_433/discussions/2987): "not an error, ignore it"). I found no
  report that it, or the state it leaves behind, changes the received level. That may just mean nobody measured it.
* PLL limits are dongle- and probably temperature-dependent, and near the low end the PLL can report lock while
  producing a slightly different frequency (asked for 25 MHz, gets 27 MHz)
  ([Joanne Dow's fork README](https://github.com/ms-jdow/rtlsdr-Cplusplus-VS2010/blob/master/README): the author's
  measurement and opinion). Relevant to this driver's 24–1766 MHz range claim, which is unverified at the edges.
* The RTL-SDR Blog driver added a "VCO PLL current fix" for PLL lock above ~1.5 GHz in hot conditions
  ([announcement](https://www.rtl-sdr.com/in-testing-customized-drivers-for-rtl-sdr-blog-v3-sdrs/)). In the source
  it writes VCO current (register 0x12) unconditionally instead of Osmocom's "0x80, retry with 0x60". This driver
  follows Osmocom.
* The community [`librtlsdr` fork](https://github.com/librtlsdr/librtlsdr/blob/master/README_improvements.md) falls
  back to harmonic mixing when the PLL will not lock (above ~1.76 GHz), and exposes VGA as a third gain stage.
* A 2013 thread reported R820T "spur prevention" code deliberately detuning the VCO by up to tens of kHz
  ([Osmocom list](https://lists.osmocom.org/pipermail/osmocom-sdr/2013-April/000709.html)). That was an early driver;
  the `librtlsdr` source this driver was checked against contains no such logic.
* An "internal AGC" alarm about the R820T ([1](https://lists.osmocom.org/pipermail/osmocom-sdr/2013-August/000908.html))
  was retracted by its author: the cause was DC from his noise source into an input with no blocking capacitor
  ([2](https://lists.osmocom.org/pipermail/osmocom-sdr/2013-August/000912.html)). Not related.
* Cold-start drift is documented for frequency (settling over ~20–30 minutes, from search snippets of forum posts).
  Our levels also drifted downward by about 2 dB over the ~40 minutes of testing, in both drivers together (a dongle warming up is the obvious suspect, unproven). I did not
  find a source for noise-floor warm-up, so treat that as an observation, not a documented effect.

## Decision

* **Do not copy `librtlsdr`'s failed retune.** It is an accident of call ordering, and both states are locked and equally
  sensitive by the spur-over-floor measure.
* Expect absolute levels to differ from `librtlsdr`-based tools by up to about 2 dB, and to depend on tuning history
  in ways nobody has characterised. Do not use this driver for calibrated power measurements without calibrating.
* Open questions for whoever continues this: does the state persist across later retunes in `librtlsdr`; does another dongle
  (or an R820T2) show it; what does an antenna with a known carrier show; is the sub-band really the cause.
