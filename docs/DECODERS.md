# Decoders (`RTLSDRDecoders`)

Protocol decoders for signals listed in section 5 of [WHAT-TO-BUILD.md](WHAT-TO-BUILD.md). The library depends on
nothing (not even RTLSDRKit): feed it u8 I/Q from the dongle, from a file, or from any other source.
**None of the decoders has received a live signal from this driver yet**: everything below is synthetic signals,
published messages and recordings made with other receivers. The on-air checks are listed in
[HARDWARE.md](../HARDWARE.md).

| | Mode S / ADS-B | UAT | ISM sensors | Meteor-M LRPT | Radiosondes |
|---|---|---|---|---|---|
| Frequency, sample rate | 1090 MHz, 2 MS/s | 978 MHz (US only), 2.083334 MS/s | 433.92 MHz (also 315, 868, 915), 250 kS/s | 137.9 or 137.1 MHz, 288 kS/s (any rate over twice the symbol rate) | 400-406 MHz, 240 kS/s (any rate from 48 kS/s), or FM audio |
| What it carries | Airliner and GA transponders: identity, position, altitude, velocity, squawk | GA ADS-B, and from ground stations FIS-B: NEXRAD radar mosaics, METAR/TAF/winds text, NOTAMs, airspace status | Weather stations, thermometers, remotes: 11 rtl_433 protocols, 50-odd models (below) | Weather-satellite images: the MSU-MR imager's three daytime (or night-time infrared) channels, 1568 pixels a line, about 1 km each | Vaisala RS41 weather balloons: position, altitude, velocity, temperature, serial, battery, burst-kill countdown |
| Written from | The public protocol description (ICAO Annex 10 Vol. IV, as laid out in *The 1090 MHz Riddle*) | A port of dump978 by Oliver Jowett (GPL-2.0-or-later); the formal UAT specifications are not public | A port of rtl_433 25.02 (GPL-2.0-or-later): its baseband, pulse detector, slicers, bit buffer and device decoders | A port of meteor_demod and meteor_decode by dbdexter-dev (MIT), with a new carrier acquisition and marker search (below); SatDump 1.2.2 as oracle only | Written for this package from the frame format as rs1729's RS project documents it (GPL-3.0, read for format facts only); its rs41mod as oracle |
| Command | `rtlsdr-tool adsb [--ifile FILE] [--raw]` | `rtlsdr-tool uat [--ifile FILE \| --frames FILE] [--raw] [--nexrad DIR]` | `rtlsdr-tool ism [--ifile FILE] [--json] [--protocols N,...]`, `--code '{36}...'` | `rtlsdr-tool meteor [--ifile FILE \| --soft FILE] [--mode oqpsk\|qpsk] [--web PORT]` | `rtlsdr-tool sonde [--freq HZ \| --scan \| --ifile FILE \| --wav FILE] [--json]` |
| Output compatible with | dump1090 `--raw` (AVR `*hex;` lines) | dump978 (`-hex;` / `+hex;rs=N;` lines) | rtl_433 `-F json` (same fields, same numbers, same time stamps for files) | PNG channel images and composite (as meteor_decode makes them), `.cadu` frames (as SatDump writes them), soft symbols (as meteor_demod writes them) | rs41mod `--json` (the JSON lines radiosonde_auto_rx reads) |

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

### Meteor-M LRPT

The receive chain: a demodulator ported from meteor_demod (DC-removing AGC, root-raised-cosine matched filter,
Costas-style carrier loop, Mueller-Müller symbol clock; QPSK for Meteor-M N2, offset QPSK for N2-3 and N2-4, 72
ksym/s), then a frame decoder ported from meteor_decode (marker correlator, K=7 Viterbi decoder, derandomiser), NRZ-M
undone on the decoded bits for N2-3/N2-4 (where SatDump undoes it), Reed-Solomon (255,223) in the conventional basis
(this package's codec with β = α¹¹, first root 112), the M_PDU packet parser, and the MSU-MR image decoder (Huffman,
quantisation, meteor_decode's fixed-point IDCT, channel assembly by packet sequence and time).

Three things are new, where the originals lose frames:

* **Carrier acquisition.** meteor_demod starts its loop at 0 Hz and sweeps ±3.4 kHz at 10⁻⁶ rad/symbol², which takes
  seconds, and its lock detector can be fooled: on a −1500 Hz test signal it reported lock at +247 Hz and stayed off
  frequency for 15 s. Here the signal is also raised to the fourth power (which strips QPSK and OQPSK modulation and
  leaves a line at four times the carrier offset), transformed, and the loop is started on that line and moved to it
  when it claims a lock well away from it. A continuous-wave spur, which has such a line too, is recognised by its line
  in the plain spectrum and ignored.
* **Eight phases, not four.** An offset-QPSK carrier loop that settles a quarter turn off pairs the wrong channels:
  re-paired on the marker, the constellation comes out mirrored (Q negated), which no rotation undoes. meteor_decode
  tries the four rotations only (its source notes "might also need I<->Q swaps?"); here the correlator also tries
  their mirror images, which also covers swapped I/Q leads.
* **Where to look for the next marker.** meteor_decode takes the marker at the expected place once it matches 42 of
  64 bits in any rotation. For NRZ-M the marker one soft symbol away (after a carrier slip) also passes that, in some
  other phase, and every frame after the slip is lost. Here the best match within ±16 soft symbols of the expected
  place wins if it reaches 48, otherwise the best in the whole window. The first bit of each output frame's marker is
  written as sent (NRZ-M decodes it against the previous frame's last bit, which a phase flip between frames inverts);
  the marker is not part of the Reed-Solomon codewords, so nothing else changes.

How it was checked:

* **A real recording** (Meteor-M N2, QPSK, soft symbols, 22 July 2018, 35 s: `2018_07_22_LRPT_21-57-39.s` from
  [YAM2D](https://github.com/DancingVixen/YAM2D); not included, that repository has no licence). All 261 frames that
  meteor_decode and SatDump 1.2.2 recover are recovered, byte-identical (SatDump leaves two parity bits uncorrected in
  two frames), all 1017 packets are found, and the three channel images are pixel-identical to meteor_decode's (within
  one grey level of SatDump's).
* **Synthetic I/Q from real frames.** `Tools/lrpt-oracle.py` randomises, NRZ-M codes (OQPSK), convolutionally encodes
  and RRC-shapes those 261 frames with its own code, adds a carrier offset and drift, a 30 ppm clock error and noise
  (Es/N0 12 dB unless stated), 288 kS/s. SatDump recovered exactly the frames sent from the signals it acquired, which
  checks the modulator. Valid frames of 261, against meteor_demod's soft symbols put through this package's frame
  decoder (meteor_decode at the commit ported predates N2-3: it has no NRZ-M decoding, its `--diff` being an older
  symbol-level scheme, and it found no packets in the OQPSK signals):

  | carrier offset | OQPSK: this demodulator | OQPSK: meteor_demod | QPSK: this demodulator | QPSK: meteor_demod |
  |---|---|---|---|---|
  | 0 Hz | 260 | 251 | | |
  | +1500 Hz | 260 | 235 | 260 | 250 |
  | −1500 Hz | 260 | 108 | 260 | 177 |
  | −2050 → +450 Hz | 260 | 149 | 260 | 179 |
  | +4000 → +1000 Hz (outside the ±3.4 kHz search range for the first 6 s) | 212 | 112 | 213 | 96 |
  | −2500 → −1500 Hz, Es/N0 6 dB | 259 | 214 | | |
  | −2500 → −1500 Hz, Es/N0 3 dB | 0 | 0 | | |

  The frame lost in every row is the first: the carrier search needs its first transform (0.11 s).
* **A synthetic scene end to end.** `Tools/lrpt-encode.py` draws a 400-line, three-channel weather scene (fractal land,
  sea and cloud), compresses it the way MSU-MR does (8×8 DCT, JPEG quantisation scaled by a per-packet quality,
  JPEG luminance Huffman tables, 14 blocks a packet) and packs it into 312 frames with reedsolo parity; `lrpt-oracle.py`
  modulates them (OQPSK, −2050 → +450 Hz, Es/N0 11 dB). Demodulated from I/Q: 310 frames valid, each byte-identical to
  the frame sent; the images are pixel-identical to those decoded from ideal symbols, and 37-39 dB PSNR against the
  source scene (the compression's loss). SatDump 1.2.2 recovered nothing from that signal: its OQPSK loop acquired
  some of these test signals and not others (258 frames at 0 Hz, 232 at −1500 Hz, none at +1500 Hz or on this one),
  and it crashed on some runs.
* **Unit tests**: the pseudo-noise sequence; Reed-Solomon parity against reedsolo and 16 symbol errors repaired;
  frames through all eight phases in both modes with an odd lead; frames after an offset-QPSK carrier slip; noise alone
  giving no valid frame; the carrier search on a modulated signal, a tone and noise; the demodulator end to end on a
  signal from a modulator written in the test (textbook RRC formula) at −1500, 0 and +2200 Hz; and the image chain on
  six frames from `lrpt-encode.py` (`Tests/RTLSDRDecodersTests/Resources/lrpt-scene.cadu`) against the source scene's
  8×8 block statistics.
* **Not done:** a pass received with this driver (none recorded yet); the 80 ksym/s mode N2-3 and N2-4 sometimes use,
  which interleaves the symbols and inserts a marker every 80 (meteor_decode's `--int`); Meteor's other virtual channels
  and telemetry; geometric correction, map overlays or pass prediction; the 3 dB case above, which a better loop might
  reach.

#### The dashboard

`--web PORT` serves a live page while decoding (recordings play back in real time, or `--speed` times it): the receive
chain as five stages (RF level, carrier with Doppler rate and the fourth-power estimate, symbol SNR and clock, frames,
image lines), each with a sparkline; the imagery building up line by line (composite or any channel, contrast stretch,
PNG download); a constellation drawn as a persistence heat map; spectrum and waterfall with the loop's carrier and the
coarse estimate marked; a ribbon of every frame (clean, repaired, lost); SNR and carrier over the pass with loss of
lock shaded; and packets per APID. Server-Sent Events push the numbers five times a second; image rows are fetched as
PNG strips once every channel shown has them complete.

### Radiosondes (Vaisala RS41)

The RS41 sends one 320-byte frame a second at 4800 bit/s (GFSK): whitened, protected by two interleaved Reed-Solomon
(255,231) codewords, and split into blocks with CRCs (status and a 16-byte piece of the calibration table, PTU counts,
GPS time, GPS position and velocity). The frame layer follows the format as rs1729's RS project documents it (its notes
and its decoder rs41mod, GPL-3.0, read for these facts only); the receiver is this package's own:

* **Channel.** An oscillator moves the sonde to zero, a boxcar decimates to about 48 kHz, a ±3.7 kHz low-pass (the
  bandwidth rs41mod uses on real sondes) keeps the signal, and a discriminator gives its frequency. A filter that
  narrow needs the carrier found first (a dongle's crystal alone can be 20 kHz off at 403 MHz): the decimated spectrum
  is averaged over half a second and the receiver moves to the centre of the power standing above the noise, and each
  clear header after that fine-tunes it. The filter was the difference between failing and beating rs41mod: at
  ±12 kHz the discriminator ran below its threshold and no frame decoded at Eb/N0 10 dB.
* **Frames.** The header is found by a Pearson correlation of its 64 bits with bit integrals (taken from a running sum,
  so any sample rate works; offset, level and polarity drop out), refined to a quarter sample; the frame's bits are
  read at that timing against the frame's own mean. A frame the code cannot repair gets a second try with the bytes
  known in advance written in (block IDs and lengths, the padding block), as rs41mod's `--ecc2` does.
* **Values.** WGS84 position by Bowring's method, velocity over ground from the ECEF velocity, GPS time as sent (no leap
  seconds, as rs41mod prints it and radiosonde_auto_rx expects), temperature from the sensor and reference counts with
  the calibration table once its pieces have arrived (up to 51 s), subtype, transmit frequency and burst-kill
  countdown from their pieces.

How it was checked:

* **Real recordings** (FM audio, 48 kHz: `rs41pre_20150802.wav` and `20140717_402MHz.wav` from
  [rs1729/RS](https://github.com/rs1729/RS); not included, that repository is GPL-3.0). All 180 frames decode, and every
  field of every JSON line equals rs41mod's (`Tools/sonde-oracle-compare.py`: position and velocity to the 5 decimals
  printed, temperature to 0.1 °C, time, serial, subtype, frequency and countdown exactly).
* **Synthetic I/Q from those real frames.** `Tools/rs41-oracle.py` whitens them again and sends them with its own GFSK
  modulator (BT 0.5, ±2.4 kHz), a carrier offset, noise for the Eb/N0 asked for, 240 kS/s; rs41mod gets the same signal
  as an I/Q WAV (`--IQ`, told the exact carrier frequency), this receiver starts listening at 0 Hz. Reports of 120:

  | | 12 dB | 10 dB | 9 dB | 8 dB | 7 dB | 11 dB, carrier −8 → −4 kHz | 11 dB, +15 kHz |
  |---|---|---|---|---|---|---|---|
  | this receiver | 119 | 119 | 119 | 81 | 0 | 119 | 119 |
  | rs41mod | 120 | 120 | 118 | 27 | 0 | 35 | 120 |

  The frame this receiver loses in every column is the first, while the carrier search takes its first half second;
  rs41mod's losses on the drifting carrier are where it sat off the signal. Every report was compared with rs41mod's
  decode of the original recording: none has a wrong field. 15 s of noise gave no report. A 2.4 MS/s capture with
  the sonde 600 kHz off-centre and 3 kHz from where it was expected (what a scan dwell gives) decodes too.
* **Unit tests**: the whitening sequence against its shift-register recurrence; the CRC's check value; Reed-Solomon
  parity against reedsolo, 12 errors per codeword repaired, and the second try with known bytes; frames built field by
  field (a known position, velocity and GPS time; a calibration table with known resistors and coefficients giving a
  temperature worked out independently; subtype, frequency and countdown); the receiver on a signal from a GFSK
  modulator written in the test, 4 kHz off, from I/Q and from FM audio of the opposite polarity; noise alone.
* **Not done:** humidity and pressure (rs41mod's formulas for them are partly empirical and were not taken), extended
  frames' XDATA (ozone sondes and the like), the other sonde types radiosonde_auto_rx knows (DFM, M10/M20, RS92, iMet,
  …), uploading to SondeHub, and following one sonde continuously once `--scan` has found it (the scan loop revisits
  every sonde each round, a position every 15 s or so).

## Speed

Decoding the oracle recordings on one core of the Linux build machine: ADS-B 2.4 s of signal in 0.29 s (release build)
or 4.5 s (debug build); UAT 1.17 s of signal in 0.04 s (release) or 0.84 s (debug); ISM 122 s of signal in 0.74 s
(release; rtl_433 takes 0.44 s); Meteor-M LRPT 36 s of I/Q in 1.8 s (release, to images; meteor_demod's
demodulation alone takes 0.74 s) or 35 s of soft symbols in 0.5 s; RS41 120 s of I/Q at 240 kS/s in 1.2 s, or of FM audio in 0.4 s. Live, a decoder
that falls behind
drops whole blocks and reports it rather than queueing without limit, so use a release build for ADS-B.

## Rerunning the comparisons

The oracles need dump1090-mutability, dump978, rtl_433, meteor_demod, SatDump, rs41mod and a few Python packages; none of
that is needed for `swift test`.

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

Tools/lrpt-encode.py scene.cadu --scene-out scene/                                          # numpy, reedsolo
Tools/lrpt-oracle.py scene.cadu scene.u8 --mode oqpsk --offset -800 --doppler 2500 --esn0 11   # numpy
rtlsdr-tool meteor --ifile scene.u8 --mode oqpsk --out ours --cadu ours.cadu                  # compare with scene.cadu, scene/
meteor_demod -B -s 288000 --bps 8 -m oqpsk -o md.s scene.u8 && rtlsdr-tool meteor --soft md.s --mode oqpsk
satdump meteor_m2-x_lrpt baseband scene.u8 sd --samplerate 288000 --baseband_format cu8

git clone https://github.com/rs1729/RS && (cd RS/demod/mod && gcc -c demod_mod.c bch_ecc_mod.c && gcc rs41mod.c demod_mod.o bch_ecc_mod.o -lm -o rs41mod)
Tools/sonde-oracle-compare.py RS/demod/mod/rs41mod rtlsdr-tool RS/rs41/wav/*.wav --invert
RS/demod/mod/rs41mod -i --ecc2 -r RS/rs41/wav/20140717_402MHz.wav > frames.txt              # dewhitened frames
Tools/rs41-oracle.py frames.txt sonde --ebn0 9 --offset 3000                              # numpy
rtlsdr-tool sonde --ifile sonde.u8 --json; RS/demod/mod/rs41mod --IQ 0.0125 --lpIQ --ecc2 --json sonde.wav
```
