# Decoders (`RTLSDRDecoders`)

Protocol decoders for signals listed in section 5 of [WHAT-TO-BUILD.md](WHAT-TO-BUILD.md). The library depends on
nothing (not even RTLSDRKit): feed it u8 I/Q from the dongle, from a file, or from any other source.
**None of the decoders has received a live signal from this driver yet**: everything below is synthetic signals,
published messages and recordings made with other receivers. The on-air checks are listed in
[HARDWARE.md](../HARDWARE.md).

| | Mode S / ADS-B | UAT | ISM sensors |
|---|---|---|---|
| Frequency, sample rate | 1090 MHz, 2 MS/s | 978 MHz (US only), 2.083334 MS/s | 433.92 MHz (also 315, 868, 915), 250 kS/s |
| What it carries | Airliner and GA transponders: identity, position, altitude, velocity, squawk | GA ADS-B, and from ground stations FIS-B: NEXRAD radar mosaics, METAR/TAF/winds text, NOTAMs, airspace status | Weather stations, thermometers, remotes: 11 rtl_433 protocols, 50-odd models (below) |
| Written from | The public protocol description (ICAO Annex 10 Vol. IV, as laid out in *The 1090 MHz Riddle*) | A port of dump978 by Oliver Jowett (GPL-2.0-or-later); the formal UAT specifications are not public | A port of rtl_433 25.02 (GPL-2.0-or-later): its baseband, pulse detector, slicers, bit buffer and device decoders |
| Command | `rtlsdr-tool adsb [--ifile FILE] [--raw]` | `rtlsdr-tool uat [--ifile FILE \| --frames FILE] [--raw] [--nexrad DIR]` | `rtlsdr-tool ism [--ifile FILE] [--json] [--protocols N,...]`, `--code '{36}...'` |
| Output compatible with | dump1090 `--raw` (AVR `*hex;` lines) | dump978 (`-hex;` / `+hex;rs=N;` lines) | rtl_433 `-F json` (same fields, same numbers, same time stamps for files) |

## How they were checked

### Mode S / ADS-B

* **Published messages** from *The 1090 MHz Riddle*: identification (KLM1023), an even/odd position pair (52.2572°,
  3.9194°, 38 000 ft), ground and air velocity.
* **An independent decoder as oracle** (pyModeS 3.6.0): 70 altitude codes (40 of them Gillham 100 ft codes) and 20
  squawks in DF4/DF5 replies, NL at 15 latitudes, 28 random CPR pairs and 14 local fixes
  (`Tools/generate-modes-vectors.py`, `Tests/RTLSDRDecodersTests/Resources/`). One bug was found this way: impossible
  latitudes from mismatched pairs were not rejected.
* **dump1090 on the same frames.** `Tools/modes-oracle.py` renders about 1450 random frames (70 % DF17, 15 % DF11,
  15 % DF4) from a continuous-time pulse model: random carrier phase, random timing within the sample, six signal levels
  over noise of 2.5 ADC codes. It renders each at the rate its decoder needs: 2.0 MS/s for this one, 2.4 MS/s for
  dump1090-mutability 1.15 (which only reads 2.4 MS/s files). Frames decoded, two runs:

  | signal (codes) | 80 | 40 | 20 | 12 | 8 | 6 |
  |---|---|---|---|---|---|---|
  | dump1090 (run 1) | 229/243 | 239/251 | 217/240 | 58/246 | 16/246 | 12/237 |
  | this decoder (run 1) | 225/243 | 234/251 | 153/240 | 84/246 | 17/246 | 12/237 |
  | dump1090 (run 2) | 207/224 | 210/230 | 226/255 | 55/222 | 19/254 | 24/254 |
  | this decoder (run 2) | 202/224 | 205/230 | 178/255 | 76/222 | 20/254 | 20/254 |

  Neither decoder produced a frame with wrong content. A few DF11 replies whose only bit error is in the interrogator
  code are accepted for known aircraft, as dump1090 also does. The gap at mid levels is the price of 2 MS/s: when a
  0.5 µs pulse straddles two samples, each holds half its energy. A 2.4 MS/s demodulator (as dump1090-fa and readsb
  use) would close it; it has not been written.
* **Synthetic streams** in the unit tests: frames at block boundaries, straddled pulses, the address-confirmation rules
  (repaired bits and address/parity replies are trusted only for aircraft already heard cleanly), 8 s of noise with no
  false frame.

### UAT

* **Reed-Solomon** (written for this package): parity equals reedsolo's; 135 correctable words are repaired exactly as
  Phil Karn's decoder (the one dump978 uses) repairs them; all 45 words beyond repair are refused
  (`Tools/generate-uat-rs-vectors.py`).
* **Every real frame in dump978's sample data** (1143: 439 aircraft, 704 ground station) decodes field for field as
  dump978's own `uat_decode.c` decodes it (`Tools/uat-oracle-fields.c`), and all 720 NEXRAD blocks match
  `extract_nexrad` line for line. One deliberate difference: aircraft size uses the DO-282B table, as FlightAware's
  dump978 does, because the original read the length from the wrong bits.
* **dump978 on the same signal.** `Tools/uat-oracle.py` takes 300 of those real frames, adds parity with reedsolo (not
  this package's encoder) and modulates them as continuous-phase FSK (modulation index 0.6) with random timing, carrier
  phase and ±40 kHz frequency offset, at five noise levels. Two runs: this decoder's output was **byte-identical to
  dump978's**, repair counts included (213 and 208 frames of 300; no false frames).
* **Deliberate differences from dump978**, each where dump978 looks wrong and the sample data cannot tell: aircraft
  size uses the DO-282B table (dump978 read the length from the wrong bits); FIS-B times with month, day and seconds
  keep all six bits of the seconds (dump978 masked off the top one); empty-block bitmaps above 60°N step over the
  ring's wide blocks (dump978's numbering there does not line up with the rings). None of these occurs in the sample
  data, so the byte-for-byte comparisons above are unaffected, and none has been checked on air.
* **What real data did not cover:** the sample recording has no rain (every radar bin is intensity 0), so colour
  rendering is covered by a synthetic test only; there were no CONUS mosaics (product 64) in it either.

### ISM sensors

The whole receive chain is ported so that it finds the same packages: rtl_433's fixed-point envelope and FM
discriminator, its OOK and FSK pulse detectors (classic and min/max), the PCM, PPM, PWM and Manchester slicers, the bit
buffer (including how rows share storage) and the device decoders with their field names and single-precision
arithmetic. Ported protocols (rtl_433 numbers):

| # | Protocol | Models |
|---|---|---|
| 2 | Rubicson | Rubicson, TFA 30.3197, InFactory PT-310 |
| 12 | Oregon Scientific v2.1 and v3 | THGR122N, THGR968, THN132N, THR228N, AWR129, RTGN318, RTGN129, RTGR328N, THGR328N, THN129, RTHN129, BTHR918, BHTR968, BTHGN129, RGR968, WGR968, UVR128, THGR810, THN802, UV800, PCR800, WGR800 (not the OWL CM160/CM180 energy monitors that share v3) |
| 18 | Fine Offset WH2 | WH2, WH2A, WH5, Telldus/Proove |
| 19 | Nexus | Nexus, FreeTec NC-7345, NX-3980, Solight TE82S, TFA 30.3209 |
| 20 | Ambient Weather F007TH | F007TH, F012TH, TFA 30.3208.02, SwitchDoc F016TH |
| 30 | Generic remote | PT2260/PT2262, SC2260/SC2262, EV1527 remotes and sensors |
| 40 | AcuRite "TXR" family | 592TXR Tower, Iris 5-n-1, Notos 3-n-1, Atlas (with and without lightning), 6045M, 899 rain, 515 fridge/freezer, 1190 leak |
| 73 | LaCrosse TX141 | TX141-Bv2/Bv3, TX141TH-Bv2, TX141W, TX145wsdth (and TFA, ORIA rebrands) |
| 78 | Fine Offset WH25 and relatives | WH25, WH32, WH32B, WN32B, WH24, WH65B, HP1000, WH0290 (Ecowitt, Ambient Weather, Misol) |
| 119 | Bresser 5-in-1 | Bresser 5-in-1, Professional Rain Gauge |
| 172 | Bresser 6-in-1 | 6-in-1, 7-in-1 indoor, new 5-in-1, 3-in-1 wind gauge, soil and pool sensors, Froggit WH6000, Ventus C8488A |

How it was checked:

* **rtl_433 on the same recordings.** `Tools/ism-oracle-compare.py` runs rtl_433 25.02 (built from Ubuntu's source
  package) and `rtlsdr-tool ism` on the recordings of [rtl_433_tests](https://github.com/merbanan/rtl_433_tests), both
  limited to the protocols above so that decoder priorities work alike, and compares the JSON line for line. In the
  directories of the ported devices, **all 606 recordings give byte-identical output** (366 messages, time stamps
  included); in 37 directories of other devices (checking for false positives), all 493 recordings match too (70
  messages). Two recordings were skipped because they need rtl_433 options not ported (`-Y magest`, `-Y filter`).
  122 s of recordings concatenated also match byte for byte, across rtl_433's buffer boundaries.
* **rtl_433 on the same bits.** `Tools/generate-ism-vectors.py` keeps bit buffers that the decoders saw in those
  recordings (up to three per model, 40 models, plus some that fail their checksums) with rtl_433's output for each
  (`rtl_433 -y`). The test suite decodes them all; the recordings themselves are not part of this package (the
  rtl_433_tests repository has no licence).
* **Synthetic transmissions** in the unit tests, built from the protocol descriptions with checksums computed:
  Nexus (PPM), LaCrosse TX141TH-Bv2 (PWM with sync pulses), an EV1527 remote, Bresser 6-in-1 (FSK), in noise, with odd
  block lengths, and noise alone.
* **Not ported** from rtl_433: the other 260-odd protocols, the flex decoder, magnitude (instead of amplitude)
  envelopes, the level and filter options (`-Y`), the automatic level, and the signal-strength fields (`-M level`).

## Speed

Decoding the oracle recordings on one core of the Linux build machine: ADS-B 2.4 s of signal in 0.29 s (release build)
or 4.5 s (debug build); UAT 1.17 s of signal in 0.04 s (release) or 0.84 s (debug); ISM 122 s of signal in 0.74 s
(release; rtl_433 takes 0.44 s). Live, a decoder that falls behind
drops whole blocks and reports it rather than queueing without limit, so use a release build for ADS-B.

## Rerunning the comparisons

The oracles need dump1090-mutability, dump978, rtl_433 and a few Python packages; none of that is needed for `swift test`.

```
Tools/modes-oracle.py 7 /tmp/modes                        # numpy
dump1090 --ifile /tmp/modes/modes-2400.u8 --raw > /tmp/modes/dump1090.txt
rtlsdr-tool adsb --ifile /tmp/modes/modes-2000.u8 --raw > /tmp/modes/ours.txt
Tools/modes-oracle-compare.py /tmp/modes

Tools/uat-oracle.py 5 /tmp/uat Tests/RTLSDRDecodersTests/Resources/dump978-sample-data.txt   # numpy, reedsolo
dump978 < /tmp/uat/uat.u8 > /tmp/uat/dump978.txt
rtlsdr-tool uat --ifile /tmp/uat/uat.u8 --raw > /tmp/uat/ours.txt
Tools/uat-oracle-compare.py /tmp/uat

git clone https://github.com/merbanan/rtl_433_tests                                         # recordings
Tools/ism-oracle-compare.py rtl_433 rtlsdr-tool rtl_433_tests/tests nexus acurite ...        # rtl_433 25.02
Tools/generate-ism-vectors.py rtl_433 rtlsdr-tool rtl_433_tests/tests Tests/RTLSDRDecodersTests/Resources/ism-code-vectors.txt nexus ...
```
