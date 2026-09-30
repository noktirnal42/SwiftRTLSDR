# Decoders (`RTLSDRDecoders`)

Protocol decoders for signals listed in section 5 of [WHAT-TO-BUILD.md](WHAT-TO-BUILD.md). The library depends on
nothing (not even RTLSDRKit): feed it u8 I/Q from the dongle, from a file, or from any other source.
**Neither decoder has received a real signal yet**: everything below is synthetic signals, published messages and
recorded frames. The on-air checks are listed in [HARDWARE.md](../HARDWARE.md).

| | Mode S / ADS-B | UAT |
|---|---|---|
| Frequency, sample rate | 1090 MHz, 2 MS/s | 978 MHz (US only), 2.083334 MS/s |
| What it carries | Airliner and GA transponders: identity, position, altitude, velocity, squawk | GA ADS-B, and from ground stations FIS-B: NEXRAD radar mosaics, METAR/TAF/winds text, NOTAMs, airspace status |
| Written from | The public protocol description (ICAO Annex 10 Vol. IV, as laid out in *The 1090 MHz Riddle*) | A port of dump978 by Oliver Jowett (GPL-2.0-or-later); the formal UAT specifications are not public |
| Command | `rtlsdr-tool adsb [--ifile FILE] [--raw]` | `rtlsdr-tool uat [--ifile FILE \| --frames FILE] [--raw] [--nexrad DIR]` |
| Output compatible with | dump1090 `--raw` (AVR `*hex;` lines) | dump978 (`-hex;` / `+hex;rs=N;` lines) |

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
* **What real data did not cover:** the sample recording has no rain (every radar bin is intensity 0), so colour
  rendering is covered by a synthetic test only; there were no CONUS mosaics (product 64) in it either.

## Rerunning the comparisons

The oracles need dump1090-mutability, dump978 and a few Python packages; none of that is needed for `swift test`.

```
Tools/modes-oracle.py 7 /tmp/modes                        # numpy
dump1090 --ifile /tmp/modes/modes-2400.u8 --raw > /tmp/modes/dump1090.txt
rtlsdr-tool adsb --ifile /tmp/modes/modes-2000.u8 --raw > /tmp/modes/ours.txt
Tools/modes-oracle-compare.py /tmp/modes

Tools/uat-oracle.py 5 /tmp/uat Tests/RTLSDRDecodersTests/Resources/dump978-sample-data.txt   # numpy, reedsolo
dump978 < /tmp/uat/uat.u8 > /tmp/uat/dump978.txt
rtlsdr-tool uat --ifile /tmp/uat/uat.u8 --raw > /tmp/uat/ours.txt
Tools/uat-oracle-compare.py /tmp/uat
```
