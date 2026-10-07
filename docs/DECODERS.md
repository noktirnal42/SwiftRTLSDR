# Decoders (`RTLSDRDecoders`)

Protocol decoders for signals listed in section 5 of [WHAT-TO-BUILD.md](WHAT-TO-BUILD.md). The library depends on
nothing (not even RTLSDRKit): feed it u8 I/Q from the dongle, from a file, or from any other source.
**None of the decoders has received a live signal from this driver yet**: everything below is synthetic signals,
published messages and recordings made with other receivers. The on-air checks are listed in
[HARDWARE.md](../HARDWARE.md).

| | Mode S / ADS-B | UAT | ISM sensors | Meteor-M LRPT | Radiosondes | Meshtastic (LoRa) | ACARS | VDL Mode 2 |
|---|---|---|---|---|---|---|---|---|
| Frequency, sample rate | 1090 MHz, 2 MS/s | 978 MHz (US only), 2.083334 MS/s | 433.92 MHz (also 315, 868, 915), 250 kS/s | 137.9 or 137.1 MHz, 288 kS/s (any rate over twice the symbol rate) | 400-406 MHz, 240 kS/s (RS41 and DFM: any rate from 48 kS/s; M10/M20 at 288 kS/s: any rate from 96 kS/s), or FM audio | The slot Meshtastic picks for the preset and channel (US LongFast: 906.875 MHz), 1 MS/s (any multiple of the LoRa bandwidth) | 131.550, 131.125 MHz … (US), 131.525, 131.725, 131.825 MHz (Europe): several channels from one capture at 2.4 MS/s (any multiple of 12.5 kHz), or AM audio | 136.975 MHz (everywhere) and the regional ones (136.725 … 136.875 in Europe, 136.650 … 136.800 in the US), several from one capture at 1.05 MS/s (any multiple of 42 kHz) |
| What it carries | Airliner and GA transponders: identity, position, altitude, velocity, squawk | GA ADS-B, and from ground stations FIS-B: NEXRAD radar mosaics, METAR/TAF/winds text, NOTAMs, airspace status | Weather stations, thermometers, remotes: 11 rtl_433 protocols, 50-odd models (below) | Weather-satellite images: the MSU-MR imager's three daytime (or night-time infrared) channels, 1568 pixels a line, about 1 km each | Vaisala RS41, Graw DFM-06/09/17, Meteomodem M10/M20 and InterMet iMet-1/iMet-4 weather balloons: position, altitude, velocity, temperature, serial, battery (the iMet: pressure, temperature, humidity and any attached instrument's data instead of a serial) | Meshtastic mesh traffic on the default channel and any channel whose key is given: text messages, positions, node info, telemetry, traceroutes, neighbour lists, acknowledgements; any LoRa frame with an explicit header (one preset on one slot, or several presets and slots from one capture) | Airline operations messages between aircraft and ground: positions, out/off/on/in times, weather requests, free text; registration, flight number, label, message number | The digital successor of ACARS: AVLC frames between aircraft and ground stations, carrying ACARS, ground stations' announcements (GSIF), aircraft logging on with their position and destination, and ATN traffic (CPDLC and context management; not ADS-C) |
| Written from | The public protocol description (ICAO Annex 10 Vol. IV, as laid out in *The 1090 MHz Riddle*) | A port of dump978 by Oliver Jowett (GPL-2.0-or-later); the formal UAT specifications are not public | A port of rtl_433 25.02 (GPL-2.0-or-later): its baseband, pulse detector, slicers, bit buffer and device decoders | A port of meteor_demod and meteor_decode by dbdexter-dev (MIT), with a new carrier acquisition and marker search (below); SatDump 1.2.2 as oracle only | Written for this package from the frame formats as rs1729's RS project documents them (GPL-3.0, read for format facts only); its rs41mod, dfm09mod and m10m20mod as oracles; the iMet from NOAA's published packet protocol, with imet1rs_dft as oracle | Written for this package: LoRa coding from the format as gr-lora_sdr implements it, Meshtastic from its firmware and protobuf definitions (all GPL-3.0, read for format facts only); gr-lora_sdr as oracle | Written for this package: the frame format and the demodulator's method as acarsdec documents and implements them (LGPL-2.0, read, not copied); acarsdec as oracle | Written for this package from the format as dumpvdl2 implements it (GPL-3.0, read for format facts only); dumpvdl2 as oracle |
| Command | `rtlsdr-tool adsb [--ifile FILE] [--raw]` | `rtlsdr-tool uat [--ifile FILE \| --frames FILE] [--raw] [--nexrad DIR]` | `rtlsdr-tool ism [--ifile FILE] [--json] [--protocols N,...]`, `--code '{36}...'` | `rtlsdr-tool meteor [--ifile FILE \| --soft FILE] [--mode oqpsk\|qpsk] [--symbol-rate 72000\|80000] [--web PORT]` | `rtlsdr-tool sonde [--type rs41\|dfm\|m10\|imet] [--freq HZ \| --scan \| --ifile FILE \| --wav FILE] [--json]` | `rtlsdr-tool mesh [--preset LongFast] [--region US] [--channel NAME:KEY] [--ifile FILE] [--json]`; `rtlsdr-tool lora --ifile FILE` for plain LoRa; `--presets LongFast,MediumFast,...` (`--all-slots --center HZ`) for several at once | `rtlsdr-tool acars [--region us\|eu \| --freq MHZ,...] [--ifile FILE [--center HZ] \| --wav FILE] [--json]` | `rtlsdr-tool vdl2 [--region eu\|us \| --freq MHZ,...] [--ifile FILE [--center HZ]] [--json] [--raw]` |
| Output compatible with | dump1090 `--raw` (AVR `*hex;` lines) | dump978 (`-hex;` / `+hex;rs=N;` lines) | rtl_433 `-F json` (same fields, same numbers, same time stamps for files) | PNG channel images and composite (as meteor_decode makes them), `.cadu` frames (as SatDump writes them), soft symbols (as meteor_demod writes them) | rs41mod, dfm09mod, m10m20mod and imet1rs_dft `--json` (the JSON lines radiosonde_auto_rx reads) | One line, or one JSON object, a packet; field names follow Meshtastic's protobufs | acarsdec `-o 4` (its JSON fields, same values) | dumpvdl2's JSON (`vdl2`/`avlc` objects, the fields this decoder knows), or its raw frames |

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
ksym/s, or 80 ksym/s interleaved), then a frame decoder ported from meteor_decode (marker correlator, K=7 Viterbi decoder, derandomiser), NRZ-M
undone on the decoded bits for N2-3/N2-4 (where SatDump undoes it), Reed-Solomon (255,223) in the conventional basis
(this package's codec with β = α¹¹, first root 112), the M_PDU packet parser, and the MSU-MR image decoder (Huffman,
quantisation, meteor_decode's fixed-point IDCT, channel assembly by packet sequence and time).

Four things are new, where the originals lose frames:

* **Carrier acquisition.** meteor_demod starts its loop at 0 Hz and sweeps ±3.4 kHz at 10⁻⁶ rad/symbol², which takes
  seconds, and its lock detector can be fooled: on a −1500 Hz test signal it reported lock at +247 Hz and stayed off
  frequency for 15 s. Here the signal is also raised to the fourth power (which strips QPSK and OQPSK modulation and
  leaves a line at four times the carrier offset), transformed, and the loop is started on that line and moved to it
  when it claims a lock well away from it. A continuous-wave spur, which has such a line too, is recognised by its line
  in the plain spectrum and ignored. A line below the 9 dB that counts on its own still counts (from 5 dB) when the
  estimate before agreed with it within 60 Hz, since noise puts its strongest bin anywhere in the ±3.4 kHz range; and
  a line too weak to count leaves the loop where it is instead of setting it sweeping away from a weak signal. That
  took the Es/N0 3 dB signals below from no frames to 185 and 212 (SatDump: 113).
* **Eight phases, not four.** An offset-QPSK carrier loop that settles a quarter turn off pairs the wrong channels:
  re-paired on the marker, the constellation comes out mirrored (Q negated), which no rotation undoes. meteor_decode
  tries the four rotations only (its source notes "might also need I<->Q swaps?"); here the correlator also tries
  their mirror images, which also covers swapped I/Q leads.
* **Where to look for the next marker.** meteor_decode takes the marker at the expected place once it matches 42 of
  64 bits in any rotation. For NRZ-M the marker one soft symbol away (after a carrier slip) also passes that, in some
  other phase, and every frame after the slip is lost. Here the best match within ±16 soft symbols of the expected
  place wins if it reaches 48, otherwise the best in the whole window. A best under 54 may be chance (a frame's
  worth of random bits peaks around 47-49 in some phase), with the real marker just past the window: then the next
  window is searched too, and a clear marker there that is not simply the next frame after the weak one is taken, so
  the first frame after noise (before a pass, after a fade, behind the 80k interleaver) is not swallowed. The first
  bit of each output frame's marker is written as sent (NRZ-M decodes it against the previous frame's last bit, which
  a phase flip between frames inverts); the marker is not part of the Reed-Solomon codewords, so nothing else changes.
* **The 80 ksym/s mode** (`--symbol-rate 80000`) that N2-3 and N2-4 sometimes use puts the channel bits through a
  convolutional interleaver of 36 branches (branch b delays its bits by b × 2048 × 36) and sends an 8-bit marker (0x27)
  before every 72; after deinterleaving it is the 72k stream, NRZ-M and all. The deinterleaver is ported from
  meteor_decode (`deinterleave.c`, MIT). Finding the markers is new: meteor_decode correlates hard bits with themselves
  80 apart and knows four rotations; here the soft samples are correlated with the marker under all eight rotations and
  mirrors a demodulator can settle in (an offset-QPSK quarter turn also moves the pairs a sample, which the marker phase
  absorbs), over 64 markers at a time, and the best phase and rotation are followed from window to window, so symbol
  slips and phase jumps cost a window. The rotation is undone before deinterleaving, since a quarter turn swaps I and
  Q and with them the branches. The marker half a turn round agrees with the marker a quarter turn round and one sample
  on in 7 of its 8 samples; a wide hysteresis margin kept the wrong one after a phase jump (and lost every frame for
  17 s at Es/N0 4 dB) until the comparison against SatDump showed it. The interleaver holds about 18 s, so frames
  start that long after the signal, and the end of a recording is flushed through.

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
  | +4000 → +1000 Hz (outside the ±3.4 kHz search range for the first 6 s) | 212 | 112 | 212 | 96 |
  | −2500 → −1500 Hz, Es/N0 6 dB | 259 | 214 | | |
  | −2500 → −1500 Hz, Es/N0 3 dB | 185 | 0 | | |

  The frame lost in every row is the first: the carrier search needs its first transform (0.11 s).
* **The 80k mode.** `lrpt-oracle.py --interleave` interleaves the channel bits (as described above, written from the
  format) and inserts the markers before modulating at 80 ksym/s. SatDump 1.2.2's `meteor_m2-x_lrpt_80k` pipeline
  recovered 256 of the 261 frames from its first such signal, each byte-identical to the frame sent (the first lost to
  acquisition, the last four at the end of the file), which checks the interleaver against what SatDump receives from
  the satellites. Valid frames of 261 (carrier drifting 0 → +3000 Hz, 30 ppm clock error):

  | Es/N0 | 12 dB | 9 | 7 | 6 | 5 | 4 | 3 | 2 |
  |---|---|---|---|---|---|---|---|---|
  | this receiver | 261 | 261 | 261 | 261 | 261 | 261 | 250 | 0 |
  | SatDump 1.2.2 | 256 | 259 | 256 | 235 | 245 | 257 | 115 | 0 |

  The frames are byte-identical to those sent and the images pixel-identical to the 72k decode of the same frames.
  (SatDump crashed on exit after writing its frames in most runs.)
* **A synthetic scene end to end.** `Tools/lrpt-encode.py` draws a 400-line, three-channel weather scene (fractal land,
  sea and cloud), compresses it the way MSU-MR does (8×8 DCT, JPEG quantisation scaled by a per-packet quality,
  JPEG luminance Huffman tables, 14 blocks a packet) and packs it into 312 frames with reedsolo parity; `lrpt-oracle.py`
  modulates them (OQPSK, −2050 → +450 Hz, Es/N0 11 dB). Demodulated from I/Q: 311 frames valid, each byte-identical to
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
* **Unit tests (80k)**: the deinterleaver against an interleaver written in the test, in all eight rotations with odd
  and even leads; a half-turn jump, an offset-QPSK quarter turn, a lost and a doubled symbol in one stream, followed
  exactly after each; frames through interleaver, deinterleaver and decoder with the demodulator a quarter turn off.
* **Not done:** a pass received with this driver (none recorded yet); Meteor's other virtual channels and telemetry;
  geometric correction, map overlays or pass prediction; anything below Es/N0 3 dB.

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
  frames' XDATA (ozone sondes and the like), the other sonde types radiosonde_auto_rx knows (RS92, iMet, …; DFM and
  M10/M20 are below), uploading to SondeHub, and following one sonde continuously once `--scan` has found it (the scan
  loop revisits every sonde each round, a position every 15 s or so).

### Radiosondes (Graw DFM-06, DFM-09, DFM-17)

DFM sondes send 2500 symbols a second, Manchester coded (so 1250 bit/s), as 2-FSK. A frame is 280 bits: the header
0x45CF and three blocks (one of configuration, two of data), each a run of Hamming(8,4) codewords (four data bits, four
parity bits) interleaved within its block. There is no CRC over a frame: the code, at distance 4, mends one bad bit in
a codeword and notices two. A data block holds 48 bits and its packet number; nine packets (time; latitude and speed;
longitude and heading; height and climb; the geoid height; satellites and the date, among others) make a second and come
two to a frame, and the configuration block carries one channel a frame, round robin: measurement counts as 24-bit
floats, battery, the processor's temperature, the serial number in two halves. The format facts are from rs1729's RS
project (dfm09mod, GPL-3.0, read for them only); the code is this package's:

* **Channel and detection.** The I/Q path is the shared front end (`FMFrontEnd`): an oscillator moves the sonde to
  zero, a boxcar decimates to about 48 kHz and a ±4.5 kHz low-pass keeps the signal, with the same carrier search as
  the RS41's. Two detectors read it. The default is a **non-coherent two-tone detector**: the filtered samples are
  correlated over a symbol with each of the two tones (±2.4 kHz) and the statistic is the difference of the magnitudes,
  which has no threshold; dfm09mod's own I/Q mode does the same. The other (`--discriminator`) is an FM discriminator,
  which runs below its threshold several dB sooner: on the same signals it gets 10 of 42 seconds at Es/N0 8 dB and none
  at 6, where the tone detector gets 40 and 10.
* **Frames.** The header is found by a Pearson correlation of its 32 symbols with symbol integrals (offset, level and
  polarity drop out, and the polarity comes out as `inverted`), refined to a quarter sample; a bit is the second
  symbol's integral less the first's, which also cancels a carrier offset. A header is short, so noise passes it now and
  then: a frame counts only if the code finds two of its three blocks intact (one, with a very clean header). After a
  frame the next header is looked for where it should be, at a lower bar, because the sonde never pauses.
* **Reports.** A report needs packets 0, 1, 2, 3, 4 and 8 of one second, in the order sent and within six frames, with
  no codeword beyond repair (a block with more than four repaired codewords is not trusted either). One lost packet
  must not be made up with the same one from the second before, which a six-frame limit alone lets through when the
  frames' timing puts the old packet just inside it (dfm09mod's rule is that limit; it printed a wrong height at 7 dB in one
  comparison run of a 60 s signal, and so did this decoder before it had the rule). Two things stand in for the CRC: the frame counter minus the time's seconds
  (mod 256) must stay what it was (two reports in a row that disagree move the reference), and the numbers must be
  plausible. The serial number comes from the channel that carries it once its two halves have come round twice alike;
  its channel number says the model (6 DFM-06, A DFM-09, B and C DFM-17 or DFM-09P, D DFM-17P). The temperature comes
  from the thermistor's count and two reference counts (the references give the gain) through a Steinhart-Hart curve fitted
  to the datasheet's table; DFM-17s are told from DFM-09s of the same channel number by their serial (23000000 and up),
  where dfm09mod also uses the signal's polarity.
* **Soft decisions** (`--repair`, off by default): a codeword with two bad bits has four equally near codewords; this
  takes the one the soft decisions favour. It is right about half the time: at Es/N0 8 dB it gains nothing and loses
  nothing, and below 6 dB it gets many more reports and some wrong ones (a speed of 33.7 m/s for 8.1), so it is an option.

How it was checked:

* **No real recording.** None could be found for the DFM (rs1729's repository has RS41 recordings only), so nothing
  here has met a real DFM signal. The tone detector's ±2.4 kHz is an assumption (dfm09mod's I/Q mode assumes about
  ±2.25 kHz; `--deviation` changes it), and the packet layouts rest on dfm09mod's reading of them. What is checked is
  that dfm09mod reads the signals `Tools/dfm-oracle.py` makes exactly as sent (it decodes all of them, so that is an
  independent reading of the format) and that this decoder agrees with both.
* **Synthetic I/Q.** `Tools/dfm-oracle.py` builds a flight from the format alone (nine packets a second, Hamming codewords,
  interleaving, the header, Manchester symbols, a Gaussian-filtered ±2.4 kHz modulator, a carrier offset, noise for the
  Es/N0 asked for, 240 kS/s) and writes what it sent; the thermistor channels come from the datasheet's table.
  `Tools/dfm-oracle-compare.py` gives dfm09mod (`--IQ FQ --lpIQ --ecc --ptu --json`, told the exact carrier) and this
  receiver (starting blind at 0 Hz) the same signal and checks both against what was sent. Seconds out of the 42 (or
  whatever was sent) that came out, three seeds each; "wrong" is a report with a field that differs from what was sent:

  | Es/N0 (dB) | 16 | 12 | 10 | 9 | 8 | 7 | 6 |
  |---|---|---|---|---|---|---|---|
  | this receiver | 41, 41, 41 | 41, 41, 41 | 41, 41, 41 | 41, 41, 41 | 40, 40, 38 | 36, 25, 28 | 12, 5, 4 |
  | dfm09mod | 41, 41, 41 | 41, 41, 41 | 41, 40, 41 | 40, 40, 40 | 39, 37, 39 | 34, 25, 28 | 10, 5, 5 |

  Both decoders give 41 of the 42 seconds when the signal is good: dfm09mod holds back its first report by design, and
  this receiver's first second goes while the carrier search finds the carrier (it starts blind, 3 kHz away). The few
  "wrong" reports in these runs (one or two at 6 and 7 dB, from either decoder) are all temperatures from a measurement
  channel that was several seconds old when the report was made, not positions or times; no position, time or serial was
  wrong at 7 dB or better. Other conditions, seconds out of 42 at 12 dB and at 10 dB (dfm09mod in brackets): the DFM-06,
  -17, -09P and -17P generated the same way, 41 and 41 at 12 dB (41); inverted polarity 41, 41 (41, 41); the carrier at
  −9 kHz and at +8 kHz, 41, 41 (41, 41); the carrier drifting 5 kHz over the recording, **42, 42 (24, 17)**, where
  dfm09mod, told one exact carrier frequency, is off the signal for part of it. Every report equals what was sent (and,
  where both decoded it, dfm09mod's) in every field to the precision the JSON prints.

* **Unit tests**: every single-bit error of every codeword mended and every double-bit error noticed; the interleaver
  round trip; packets built field by field (a known position, speed, time and date, with the GPS-time conversion
  checked against a calendar); serial and model for DFM-06, -09, -09P, -17 and -17P; the temperature against the
  datasheet table across −50 to +35 °C; the other position modes (sea-level heights, a second position, 26 bytes of
  extra data); a wrong time withheld because the counter disagrees; a lost packet not made up
  from the second before (the frame timing set so that the old rule would have let it through); the receiver on FM audio
  of either polarity and on I/Q 4 kHz off, with the discriminator and the tone detector, a gap in the signal, and noise
  alone.
* **Not done:** the instruments behind the extra-data mode (the bytes are passed on as hex), humidity and pressure (the
  P models carry a pressure sensor: its counts are not converted), the second position of mode 3 (read past), and
  dfm09mod's polarity-dependent rule for DFM-17s. The DFM-06's serial and the PS-15 layout have only been tried on
  synthetic frames.

### Radiosondes (Meteomodem M10 and M20)

The M10 and M20 send 9600 symbols a second (some M10s 9616) of 2-FSK, Manchester coded and then differentially coded: a
frame follows a 32-symbol header, its bits are the second symbol of each pair less the first, and a data bit is 1
where two such bits in a row are alike, so polarity does not matter. A frame starts with its length byte and a type
byte (0x9F M10 with a Trimble GPS receiver, 0xAF M10+ with a Gtop one, 0x20 M20), has the time, position, velocity,
serial number, sensor readings and a counter at fixed places, and ends with a 16-bit checksum (a linear map over GF(2)
that the frame's every byte goes through), once a second; every tenth second the M10 sends a second kind of frame
(signal levels) as well. The format facts are from rs1729's RS project (m10m20mod, GPL-3.0, read for them only):

* **Channel and detection.** As for the DFM, at about 96 kHz with a ±9 kHz low-pass, the tone detector at ±4.32 kHz
  (m10m20mod's own I/Q figure) by default, `--discriminator` for the other, `--deviation` to move the tones.
* **Frames.** The header correlation and the Manchester and differential decoding are as above. The length byte is read at
  once (sixteen symbols cannot drift); the frame is then read at a grid of symbol rates (9600 ± 0.36 % in 0.012 % steps,
  the last good rate first, either polarity) until the checksum holds, because a quarter of a symbol over a
  1700-symbol frame is 150 parts per million and the two rates differ by about 1700. The checksum is what accepts a frame,
  together with a known type byte.
* **Reports.** Positions, speeds and times as sent (the M10's latitude and longitude are 32-bit fractions of a turn,
  the M20's millionths of a degree, the M10+'s decimal); the M10 sends GPS time and the offset to UTC, the JSON gives UTC
  as m10m20mod does (the M20's time stays GPS, the M10+ sends UTC); serial numbers in the notation radiosonde_auto_rx
  uses; the thermistor through its three-range divider and a Steinhart-Hart curve fitted to the datasheet's table;
  battery.
* **A carrier far off.** A frame heard with the listening frequency 8 kHz from the carrier gives a biased mean from the
  discriminator (the filter clips one tone), so the frame-based fine tuning of all three sonde receivers now acts only
  within about a kilohertz or two of the carrier, and leaves the rest to the carrier search. Two bugs in the search
  that this exposed are fixed for all of them: its correction was applied to a listening frequency that had already moved
  and its averaged spectrum mixed two oscillator settings (both in the regression tests).

How it was checked:

* **No real recording**, as for the DFM: `Tools/m10-oracle.py` builds M10, M10+ and M20 frames from the layout
  (checksum, serial, a thermistor circuit with the datasheet's table) and a signal from them, and m10m20mod decodes
  them all as sent, which is the independent reading of the format; this decoder agrees with both.
  `Tools/m10-oracle-compare.py` runs both on I/Q (m10m20mod `--IQ FQ --lpIQ --json --ptu`), 288 kS/s, starting blind.
  Frames out of 30, three seeds each, one frame a second:

  | Es/N0 (dB) | 14 | 12 | 10 | 9 | 8 | 7 | 6 |
  |---|---|---|---|---|---|---|---|
  | this receiver | 29, 30, 30 | 29, 29, 29 | 29, 29, 29 | 29, 29, 29 | 23, 21, 21 | 6, 4, 6 | 0, 0, 0 |
  | m10m20mod | 30, 30, 30 | 30, 30, 30 | 30, 29, 30 | 28, 24, 28 | 13, 19, 14 | 0, 1, 3 | 0, 0, 0 |

  The one frame this receiver does not give at 10 dB and better is the first, while the carrier search finds the carrier.
  Below that it hears more than m10m20mod: at 8 dB about 21 frames against 15, at 7 dB a handful against almost none.
  No frame had a wrong field at any level, from either decoder. Other conditions, frames out of 30 at 14 dB and at 10 dB
  (m10m20mod in brackets): M20 30, 29 (30, 30); M10+ 30, 29 (m10m20mod gives these no frame number, so they are not
  compared); inverted 30, 29 (30, 30); the carrier at −8 kHz 29, 29 (30, 29) and at +6 kHz 29, 29 (30, 29); drifting
  5 kHz 30, 29 (29, 22); **9616 symbols a second 30, 29 (16, 0)** and 9590 30, 29 (0, 0); the signal's deviation 3.6 kHz
  29, 29 (30, 30) and 5.2 kHz 30, 29 (30, 29), against the tone detector's assumed 4.32. m10m20mod's own symbol-rate
  switching copes badly with a sonde that is not at 9600 in this test; this receiver finds the rate per frame.

* **Unit tests**: three frames from the generator (an M10, an M10+ and an M20) that m10m20mod reads with a good
  checksum, against this package's checksum; the checksum's linearity; every field of each (including the day before for a
  UTC time just past midnight GPS, western longitudes and negative heights); serial numbers and JSON text as m10m20mod
  prints them; the thermistor in each of the divider's ranges against the datasheet table; frames with extra bytes; the
  receiver on FM audio of either polarity and on I/Q 5 kHz off, at 9590, 9600, 9616 and 9625 symbols a second with the
  discriminator and the tone detector, a damaged frame lost and the next one found, and noise alone.
* **Not done:** humidity and pressure (m10m20mod's formulas for them are partly empirical), the M10's second kind of
  frame (the signal levels: it is recognised and skipped), the M2K2's own differences (it is read as an M10 with its time
  left in GPS), and the M10+'s time and date are checked on synthetic frames only.

### Pagers (POCSAG)

POCSAG sends 2-FSK (±4.5 kHz, a 1 the lower frequency) at 512, 1200 or 2400 bit/s on 25 kHz channels. A transmission is a
preamble of 576 alternating bits and then batches: a synchronisation codeword (0x7CD215D8) and eight frames of two 32-bit
codewords. A codeword is a flag (0 address, 1 message), 20 bits, ten check bits of a (31,21) BCH code (generator
x^10 + x^9 + x^8 + x^6 + x^5 + x^3 + 1) and an even-parity bit; 0x7A89C197 fills the frames nobody uses. An address
codeword carries the high 18 bits of the pager's 21-bit address and its two function bits, the low three bits being the
frame it sits in; the message codewords that follow carry 20 bits each of text until the next address or idle codeword:
four-bit digits ("0123456789.U -][") or seven-bit characters, both least significant bit first. Which one a page is
depends on the network; function 0 is numeric and the others alphanumeric by the book, and `--mode auto` guesses from
the content. The format is ITU-R M.584 as documented by the paging community; multimon-ng is the oracle.

* **Channel.** The FM front end at 48 kHz with a ±8.5 kHz low-pass (±4.5 kHz deviation plus the data's sidebands; the
  receiver follows a carrier up to about ±3.5 kHz off where it listens, `--cutoff` moves the limit) and the carrier search
  off: a paging channel is silent most of the time, so the search would move on noise or on a neighbour. Each page found
  re-tunes the receiver by the audio's average.
* **Bits.** A second-order low-pass at 0.8 of the bit rate takes off what a discriminator's noise adds at high
  frequencies (it made the difference between losing a quarter of the pages at 2400 bit/s and none), a slow average takes
  off the carrier offset, a timing loop is pulled by zero crossings and each bit is the sign of the integral over its period.
  The three rates run side by side, each a separate decoder.
* **Codewords.** The synchronisation codeword is found with up to two wrong bits in either polarity; sixteen codewords
  follow, then the next synchronisation codeword (three wrong bits allowed) or the end. Each codeword is repaired by
  the nearest valid codeword within two bits (the code, with parity, has distance 6, so that is unique); a page with a
  codeword beyond repair is dropped (`--partial` keeps it).

How it was checked:

* **Synthetic signals only.** `Tools/pocsag-oracle.py` builds pages (random addresses, numeric and alphanumeric text, a
  few bursts) from the format, FM-modulates them with noise, and writes the I/Q and, from the same noisy samples through a
  discriminator, 22.05 kHz FM audio. multimon-ng decodes all of the audio's pages as sent at every rate.
  `Tools/pocsag-oracle-compare.py` runs it and this decoder (on the I/Q, starting blind) and checks each against what was
  sent. Pages out of 24, three seeds, by carrier-to-noise ratio in 25 kHz:

  | CNR (dB) | 12 | 9 | 7 | 6 |
  |---|---|---|---|---|
  | 512 bit/s, this receiver | 24, 24, 24 | 24, 24, 24 | 24, 24, 24 | 24, 24, 24 |
  | 1200 bit/s | 24, 24, 24 | 24, 24, 24 | 24, 24, 24 | 24, 24, 24 |
  | 2400 bit/s | 24, 24, 24 | 24, 24, 23 | 20, 24, 23 | 18, 24, 23 |
  | multimon-ng, all rates | 24, 24, 24 | 24, 24, 24 | 24, 24, 24 | 23, 24, 24 |

  multimon-ng reads discriminator audio from a numpy chain (a sharper filter before and after the discriminator, 22.05
  kHz), this decoder the I/Q through its own front end, so the comparison favours multimon-ng a little. No page from
  either had a wrong word at 9 dB and above; at 7 dB and below the 2400 bit/s decoder gives a few pages in which a
  codeword with four or more wrong bits was mended into another codeword (a few of 24 at 7 dB, none at 9). Other
  conditions at 1200 bit/s, 15 and 10 dB: polarity inverted and the carrier at −2.5 kHz, all pages. Without the
  trailing idle batch a transmitter sends, the last page can be lost where the carrier drops.
* **Unit tests**: the synchronisation and idle codewords being valid codewords of the code, one and two wrong bits
  mended and three refused over random words, the address split, pages in the frames their addresses name, a page running
  into the next batch, polarity, repaired and unrepairable codewords (with and without `--partial`), text with no address,
  noise and garbage bits, the JSON and line text; and the receiver on FM audio at each rate and at 22.05 and 48 kHz, a bit
  rate 0.33 % off either way, a carrier offset and inverted audio, on I/Q at an offset carrier, from a mistuned listening
  frequency that the first page brings in, and on noise alone.
* **Not done:** FLEX and the other pager systems; character sets other than ASCII (multimon-ng has national ones); the
  Skyper format; message continuation across transmissions; real traffic.

### Ships (AIS)

AIS sends GMSK (BT 0.4) at 9600 bit/s, ±2.4 kHz, in 26.7 ms slots on 161.975 MHz (channel A) and 162.025 MHz (channel B),
25 kHz wide. A burst is a clock of 24 bits (0101…), a flag (0x7E), the message and a 16-bit frame check sequence (the X.25
CRC that AVLC uses, sent low byte first and each byte least significant bit first), a flag, all in HDLC (a 0 stuffed after
five 1s) and NRZI (a 0 is a change of frequency, a 1 none, so polarity does not matter). A message's fields are read most
significant bit first from the bits in the order they were sent; the NMEA sentence `!AIVDM,…` carries those bits six at
a time as characters. The tables are ITU-R M.1371 as gpsd's AIVDM documentation lays them out; pyais is the oracle.

* **Channels** (`AISReceiver`). Each channel is its own `FMFrontEnd` at about 120 kHz (twelve and a half samples a symbol)
  with a ±8 kHz low-pass, 25 kHz either side of a capture tuned to 162.000 MHz (clear of the DC spike); the carrier search is
  off and each frame found re-tunes by the offset it measured.
* **Frames** (`AISFrameSync`). The header (clock and flag, 32 symbols as the line carries them) is found by a Pearson
  correlation of the symbol integrals; its mean is the carrier offset the symbols are read against. Each bit is whether a
  symbol repeats the one before; the stuffing is dropped, a flag ends the frame and the frame check sequence accepts it. One
  grid for the whole frame (a clock 50 parts per million off drifts a twentieth of a symbol in a thousand bits).
* **Messages** (`AISMessage`). Position reports (1, 2, 3), base station time (4, 11), static and voyage data (5), class B
  position (18, 19), aids to navigation (21), class B static data (24 parts A and B); the other types give their number and
  MMSI. Output is a line, the NMEA sentences (`--nmea`: sentences of 60 payload characters at most, a multipart message
  numbered) or a JSON object with pyais's field names.

How it was checked:

* **Synthetic signals only.** `Tools/ais-oracle.py` builds messages of the types above field by field from the tables and
  sends them as bursts (clock, flags, stuffing, check sequence, NRZI, Gaussian-filtered GMSK) on A and on B in a 240 kS/s
  capture, with noise. pyais decodes all of the sentences it makes with every field as built (the generator's
  layout agrees with pyais's); two sentences from gpsd's documentation (a type 1 and the two-part type 5 of "MT.MITCHELL") are
  in the unit tests with the values pyais reads from them, and the type 1 sentence comes back from this package's NMEA
  output character for character. `Tools/ais-oracle-compare.py` runs this decoder starting blind (no other AIS demodulator
  was available to compare with) and checks the bits against what was sent and the JSON against pyais's reading of the
  sentences. Messages out of 36, three seeds, by carrier-to-noise ratio in 25 kHz:

  | CNR (dB) | 30 | 20 | 18 | 16 | 14 | 12 |
  |---|---|---|---|---|---|---|
  | this receiver | 36, 36, 36 | 36, 36, 36 | 36, 36, 36 | 35, 34, 33 | 25, 26, 29 | 9, 7, 15 |

  No frame was ever wrong (the check sequence accepted nothing that was not sent), and every JSON field agrees with pyais (it
  maps a reserved ship type to another of its class, and gives the rate of turn converted). A real receiver is specified for
  20 % loss at about 15-17 dB over thermal noise in this bandwidth; this one loses about 5 % at 16 dB and 20-30 % at 14 dB. A carrier 4
  kHz off, an inverted signal and both together all decode at 25 dB; at 16 dB an offset of 3.5 kHz costs about half the
  frames (the ±8 kHz channel clips the signal), because the first frame is what re-tunes the receiver. On noise alone the header
  correlation fires about once a second (the "headers without a frame" count) and nothing is ever decoded.
* **Unit tests**: bits read as unsigned and signed fields, the six-bit armour and its fill bits, text with `@` padding;
  the two published sentences; class B static (both parts) and an aid to navigation; unavailable values as nil; short and
  unknown messages; the JSON; frames with a good and a damaged check sequence; stuffing across runs of ones; bursts on both
  channels in the order they were heard, a mistuned carrier, inverted polarity, a neighbour channel not heard twice, noise
  alone, FM audio at 48 and 96 kHz and the refusal of the wrong input.
* **Not done:** the other message types (binary messages 6, 8 and 25-26 with their application data, safety messages,
  type 9 aircraft, 14, 27 long-range), a timing loop (a very long frame at a poor clock would drift), a proper
  maximum-likelihood detector for the GMSK (worth a few dB), a real signal.

### Radiosondes (InterMet iMet-1 and iMet-4)

The iMet is different from the other three: it sends no serial number and no bit-level coding of its own. Its carrier is
frequency-modulated by audio that is Bell 202 frequency shift keying (1200 Hz for a 1, 2200 Hz for a 0, 1200 baud), and
the audio carries asynchronous 8N1 characters (a start bit, eight data bits least significant first, a stop bit), idle
at 1200 Hz between frames. A frame is a second of telemetry: packets one after the other, each starting with the byte
0x01 and an identifier: GPS (0x02, 18 bytes) or extended GPS (0x05, 30, with velocity), PTU (0x01, 14) or extended PTU
(0x04, 20, with the sonde's internal, pressure-sensor and humidity-sensor temperatures), and XDATA (0x03, `N + 5`) for
attached instruments. Every packet ends with a CRC-16 (polynomial 0x1021, started from 0x1D0F, sent most significant
byte first) over its bytes from the 0x01 on. The layouts are from NOAA's "iMet-1-RSB Radiosonde Protocol" (Wendell and
Jordan, version 1.11, 2009); the CRC's seed and byte order and the float format are from rs1729's imet1rs_dft, which
decodes real flights (GPL-3.0, read for these facts only).

* **Channel and detection.** The FM front end at 48 kHz with a ±5 kHz low-pass (`--cutoff 7000` for a sonde that
  deviates more than about ±3.5 kHz), the carrier search and the fine tuning from each frame as for the others. The
  discriminator's audio goes through a two-tone detector: running correlations with the 1200 and 2200 Hz tones over one
  bit, their magnitudes' difference, after a slow average is taken off the audio (a carrier that is off frequency puts a
  constant into the discriminator, which leaks into the 2200 Hz tone's correlation).
* **Frames.** The header is 20 idle bits and the first character, found by a correlation over its 30 bits. Each later
  character is aligned afresh, at the offset within half a bit of where the last ended that puts its start bit at the
  space tone and its stop bit at the mark tone with the most energy between: the sonde's clock and the receiver's differ
  and a frame is up to a thousand bits long. The frame ends where the line goes idle. A packet is accepted by its CRC; a
  packet that fails ends the frame and keeps the ones before it.
* **Reports.** A report needs the GPS packet (position, altitude, satellites, time of day: the packet has no date); the
  JSON line imet1rs_dft prints is given when the PTU packet (the frame number, pressure, temperature, humidity, battery)
  came through too, otherwise only the readable line. XDATA is kept as hexadecimal in `aux`, an ozonesonde's packet is
  also read (cell current, pump temperature, pump current, battery). The humidity and pressure scale factors and the
  hygrometer's packets are not interpreted.

How it was checked:

* **No real recording**, as for the DFM and M10: `Tools/imet-oracle.py` builds frames from the protocol (its own CRC and
  framing), sends them as AFSK on an FM carrier with noise, and writes the I/Q and, from the same noisy samples through
  a discriminator, 48 kHz FM audio. imet1rs_dft decodes the audio and every field it reports (position, altitude,
  satellites, time, packet number, pressure, temperature, humidity, battery, the ozonesonde's readings) is as sent;
  `Tools/imet-oracle-compare.py` runs it and this decoder (on the I/Q, starting blind) and checks each against what was
  sent. Frames out of 60 at 240 kS/s, two seeds, one frame a second, by carrier-to-noise ratio in 10 kHz:

  | CNR (dB) | 25 | 14 | 11 | 10 | 9 | 8 | 7 |
  |---|---|---|---|---|---|---|---|
  | this receiver | 60, 60 | 60, 60 | 60, 59 | 58, 57 | 52, 49 | 30, 29 | 1, 6 |
  | imet1rs_dft | 60, 60 | 60, 60 | 59, 59 | 57, 57 | 49, 47 | 28, 26 | 4, 5 |

  No report from either had a wrong field at any level. On the same 48 kHz audio this decoder's bit decisions give as
  many frames as imet1rs_dft's (29 against 28 at 8 dB); the I/Q front end's cutoff was chosen on these signals (5 kHz:
  at 6 kHz it gave 12 and 15 frames at 8 dB, at 8 kHz none). Other conditions, frames out of 20 or 30 at 20 and 12 dB:
  carrier at −4.5 kHz and +5.5 kHz all of them (imet1rs_dft too); deviation 2 and 4 kHz all of them (imet1rs_dft 27 of
  30 at 2 kHz and 12 dB); **a baud rate 0.4 % off (1195 or 1206) all of them (imet1rs_dft none: its bit clock is fixed
  from the first edge)**; extended GPS and PTU packets and an XDATA packet all of them (imet1rs_dft reads the extended
  GPS packet's fields but checks its CRC at the short packet's place, so it never accepts one); deviation 5 kHz needs
  `--cutoff 7000`.
* **Unit tests**: the CRC's check value; every field of each packet type, in extended form too, with negative
  temperatures, southern and western positions and an altitude below sea level; a frame that imet1rs_dft accepts with all
  three checksums good, read as it reads it; a damaged packet ending its frame; cut-off frames; instrument data and an
  ozonesonde; the JSON text; a position off the globe; the receiver on FM audio at 22.05, 44.1, 48 and 96 kHz with and
  without a discriminator offset, with the baud rate 0.5 % off either way, on I/Q at an offset and far off centre, a
  damaged frame lost and the next found, and noise alone.
* **Not done:** a real flight. The deviation (about ±3 kHz, from a published "6 kHz peak to peak" for the iMet-4 that was not
  checked against its data sheet here) and the 1200 / 2200 Hz tones (rs1729's decoder) are what the sources give; the time zone of the GPS time of day (GPS or UTC) is not
  stated by them.

### Meshtastic (LoRa)

Meshtastic nodes talk LoRa: chirps that sweep the bandwidth, each starting at one of 2^SF offsets, behind a preamble of
16 up-chirps, a two-symbol sync word (0x2B) and 2.25 down-chirps. Two layers, both written for this package:

* **LoRa coding** (`LoRaCoding`), from the format as gr-lora_sdr (EPFL TCL, GPL-3.0) implements it, read for facts only:
  whitening, the explicit header with its checksum, the payload CRC, Hamming codes 4/5 to 4/8, the diagonal
  interleaver, Gray mapping, and the low data rate rules (the header block always at SF−2 bits a symbol, the payload
  too when a symbol lasts 16 ms or more). The decoder takes the nearest codeword, so 4/7 and 4/8 correct a bit.
* **Receiver** (`LoRaReceiver`, new). A low-pass with its edges at ±0.7 bandwidths; every `oversampling`-th sample
  then makes a chirp, at a phase chosen to the sample. A preamble is four or more windows in a row peaking at the same
  bin after dechirping. The fractional carrier offset is the peak's phase advance from one chirp to the next (corrected
  by π(N−1)/N where the clock drift moves the peak a bin); up-chirps peak at offset + timing and the delimiter's
  down-chirps at offset − timing, which separates the two (with the drift between the two measurements taken out), and
  the timing is refined to the sample. The sync word must then be where it belongs. Told the RF frequency, the receiver
  spaces the symbols by the clock error the carrier offset implies (a transmitter's crystal is off by the same ppm in
  both), so a 20 ppm crystal costs nothing over a 230-byte frame. Offsets up to a quarter of the bandwidth are found
  (LongFast frames 30, 45, −50 and +58 kHz off all decoded at −10 dB).
* **Meshtastic** (`Meshtastic`, `MeshtasticDecoder`), from the firmware and protobuf definitions (GPL-3.0, facts only):
  the 16-byte header (destination, sender, packet id, hop limit and start, want-ack, MQTT, channel hash, next hop,
  relay), channel keys (the one-byte shorthand, the well-known default key, AES-128 or AES-256), the hash that names
  the channel (XOR of name and key), AES in counter mode with the nonce built from packet id and sender, the `Data`
  message and the applications' messages (text, position, user, device and environment telemetry, routing,
  traceroute, neighbour info, waypoint). A packet whose hash matches no known channel, or whose key gives no valid
  message, is reported as unreadable; so is a direct message encrypted to its recipient's public key, which no
  listener can read. AES (FIPS-197) and the protobuf wire format are this package's own.
* **Where to listen.** The presets (ShortTurbo … LongSlow, the Lite and Narrow ones) and the regional band plans (US,
  EU_433, EU_868, ANZ, … 26 sub-GHz regions), and the slot rule: the band is cut into slots one bandwidth wide and the
  primary channel's name, hashed with djb2, picks one (US LongFast: slot 20 of 104, 906.875 MHz; EU_868: 869.525 MHz).
  `--slot`, `--freq` and `--primary NAME:KEY` override it. Live, the dongle runs at 1 MS/s (2 MS/s for 500 kHz
  presets, 250 kS/s for 62.5 kHz) with the channel one bandwidth above the tuned frequency, clear of the DC spike.

How it was checked:

* **Coding against gr-lora_sdr's transmitter**: 36 random payloads over SF7-12, every coding rate, low data rate on and
  off, lengths 2 to 255 (`Tools/generate-lora-vectors.py`); every symbol matches, and every frame decodes back with
  its CRC.
* **Receiver against gr-lora_sdr's receiver** on signals from gr-lora_sdr's transmitter (`Tools/lora-oracle.py`), a
  transmitter crystal off by the ppm shown (GNU Radio's channel model moves carrier and clock together), noise for the
  SNR in the LoRa bandwidth, 1 MS/s. This receiver reads the u8 file a dongle would give and is told the frequency;
  gr-lora_sdr reads the complex floats and is told the same frequency, with hard and with soft decisions
  (`Tools/lora-oracle-compare.py`). Frames with a valid CRC and the payload sent:

  | LongFast (SF11, 250 kHz, 4/5), +10 ppm, 20 frames | −8 dB | −10 | −12 | −14 | −16 | −18 | −20 | −21 |
  |---|---|---|---|---|---|---|---|---|
  | this receiver | 20 | 20 | 20 | 20 | 20 | 18 | 3 | 0 |
  | gr-lora_sdr, hard / soft | 20 / 20 | 20 / 20 | 19 / 19 | 3 / 5 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |

  | ShortFast (SF7, 250 kHz, 4/5), +10 ppm, 20 frames | −2 dB | −4 | −6 | −8 | −10 |
  |---|---|---|---|---|---|
  | this receiver | 20 | 20 | 19 | 7 | 0 |
  | gr-lora_sdr, hard / soft | 14 / 15 | 2 / 3 | 0 / 0 | 0 / 0 | 0 / 0 |

  | LongSlow (SF12, 125 kHz, 4/8, low data rate), +20 ppm, 10 frames | −14 dB | −17 | −20 | −22 |
  |---|---|---|---|---|
  | this receiver | 10 | 10 | 10 | 8 |
  | gr-lora_sdr, hard / soft | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |

  Without clock error (LongFast, 0 ppm) the picture is the same: 20, 20, 20 at −12, −14, −16 dB against gr-lora_sdr's
  16, 0, 0. gr-lora_sdr decodes all of these signals at higher SNR (the LongSlow ones at 0 dB), so its losses are in
  its synchronisation, not in the signals. This receiver stops close to the demodulation limits Semtech gives for its
  own chips (−7.5 dB at SF7, −17.5 dB at SF11, −20 dB at SF12). No frame decoded with a wrong payload.
  Before the comparison found it, frames were lost at ±20 ppm: a preamble window measured twice (once before waiting
  for more samples, once after) put a zero phase step into the carrier estimate.
* **Meshtastic packets** built by `Tools/meshtastic-vectors.py` (the protobuf written out by hand, OpenSSL's AES):
  text, position, node info, device and environment telemetry, traceroute, neighbour info, an acknowledgement, a
  private channel with an AES-256 key, a public-key direct message and a channel without a key here; every field
  decodes as built. Sent as LongFast frames by gr-lora_sdr at −12 dB and +20 ppm, all 11 come out of
  `rtlsdr-tool mesh --ifile` the same way.
* **Unit tests**: AES against FIPS-197's examples, counter mode against SP 800-38A's; the protobuf reader on every wire
  type and on broken messages; the default channel's hash (8), key expansion, the US, EU_868 and EU_433 LongFast
  frequencies; the packets above; and the receiver on frames from an ideal chirp modulator written in the test
  (ShortFast, 15 ppm fast, 0 dB, fed in odd-sized blocks), and on noise alone.
* **Several presets or slots at once** (`MeshtasticMultiReceiver`, `rtlsdr-tool mesh --presets A,B,...`): one capture of
  1 or 2 MS/s (a whole multiple of every LoRa bandwidth) feeds a channelizer per listener, which mixes the channel to
  zero, low-passes it (a windowed sinc that keeps ±0.75 bandwidths and stops what would fold into that) and decimates it
  to two samples a chip for a `LoRaReceiver`; listeners run on separate cores. `MeshtasticPlan` picks the smallest rate
  whose usable 80 % holds every channel clear of the dongle's DC spike, or refuses ("those channels span 14 MHz"), and
  `--all-slots --center HZ` listens to every slot of the region that fits around a frequency. A transmission heard by
  neighbouring listeners (a strong one leaks into the next slot) comes out once, from the listener whose centre the carrier
  is nearest, and the CRC-failed fragments it leaves in a neighbour of the same preset are dropped. Checked in the unit tests:
  the planner (EU_868 puts every default preset in one capture; channels 4 MHz apart are refused; and on the command line
  the US defaults of three presets, 14 MHz apart, are); ShortFast, MediumFast and ShortTurbo (250 and 500 kHz) in one
  2 MS/s capture, each frame out on its own listener at its carrier frequency to within 800 Hz; a duplicate listener reported once, by the nearer; a signal at −4 dB SNR through the channelizer; a
  strong neighbour on the next slots leaving nothing; noise alone. On the command line, a capture of six frames on three
  presets in four US slots each (12 listeners) printed exactly the six.
* **Not done:** implicit-header LoRa (Meshtastic doesn't use it), AES-CCM channels (an opt-in in development
  firmware), decoding the payloads of the less common applications (they are shown as bytes), and a capture wider than
  1.6 MHz (a dongle's limit: every US preset at once needs 20 MHz, as the RTL-SDR.com article says).

### ACARS

ACARS is AM on VHF channels 25 kHz apart; the audio is 2400 bit/s MSK (1200 and 2400 Hz tones). A block is 7-bit
ASCII with odd parity, sent least significant bit first: pre-key, `+*`, two SYNs, SOH, mode, the seven-character
registration, acknowledgement, a two-character label, block ID, STX, the text (downlinks begin it with a message
number and a flight number), ETX or ETB (more blocks follow), a CRC-16 (CCITT, reflected) and DEL. The format and the
demodulator's method follow acarsdec by Thierry Leconte (LGPL-2.0, commit `339f63e`), read and written again in Swift:

* **Channels** (`ACARSReceiver`). Each channel of the capture has its own oscillator, a second-order CIC in integers
  (decimating by up to 16: to 150 kHz from 2.4 MS/s), a windowed-sinc low-pass (flat to 4.5 kHz, down by 8.5 kHz) to about 12.5 kHz, and the envelope, so
  five US channels at 2.4 MS/s cost five such paths and nothing else. The tool tunes the dongle 12.5 kHz above the
  middle of the channels when one would otherwise sit on the DC spike; channels must lie within ±(rate/2 − 15 kHz).
* **Demodulation** (`ACARSDemodulator`). MSK is offset QPSK with half-sine pulses two bits long: against an 1800 Hz
  reference the bits fall alternately on the in-phase and the quadrature arm. One loop follows the reference's phase
  and the bit clock is tied to it (a bit is three quarters of a cycle of 1800 Hz), the matched filter is evaluated at
  the bit's exact end, and the decision on one arm times the other arm is the phase error. The polarity is resolved
  by the SYN (or its inverse). It follows a modem clock up to about 0.25% off; the AM envelope carries none of the
  dongle's tuning error.
* **Repair** (`ACARSFrameDecoder`). Parity marks the damaged characters. The CRC's syndrome for every bit of the block
  is computed once, and the decoder looks for the bits whose syndromes add up to the received one: one bit in each of
  up to three characters with bad parity, plus one bit of the CRC when there are two or fewer; with no parity errors,
  one CRC bit or two bits of one character. A fix is taken only when exactly one combination fits, and blocks with
  more than four bad characters are not tried. acarsdec also accepts three characters plus a CRC bit, which gains a
  few blocks below 4 dB at a risk of a wrong fix this decoder does not take.

How it was checked:

* **A real recording**: acarsdec's `test.wav` (four channels of 12.5 kHz audio from a receiver; not included). All 7
  messages decode and every JSON field equals acarsdec's (`-o 4`): channel, mode, label, block, acknowledgement,
  registration, flight, message number, text, end and error count.
* **Synthetic signals.** `Tools/acars-oracle.py` writes random uplinks and downlinks (labels, registrations, flights
  and printable text of up to 199 characters) as MSK written from the modulation's definition, for three channels;
  acarsdec decodes all of its clean audio. `Tools/acars-oracle-compare.py` gives both decoders the same 12.5 kHz WAV
  at each audio SNR (MSK power over the noise in 0-6.25 kHz), and this receiver alone the AM I/Q at each carrier-to-noise
  ratio in 12.5 kHz (acarsdec reads no I/Q files). Messages, of 60, with every field as sent:

  | audio SNR | 8 dB | 6 | 5 | 4 | 3 | 2 |
  |---|---|---|---|---|---|---|
  | this decoder | 60 | 60 | 60 | 51 | 38 | 20 |
  | acarsdec | 60 | 60 | 59 | 54 | 43 | 21 |

  | I/Q, carrier to noise in 12.5 kHz (AM depth 0.6) | 15 dB | 12 | 10 | 9 | 8 | 7 |
  |---|---|---|---|---|---|---|
  | this receiver | 60 | 60 | 60 | 58 | 51 | 30 |

  Neither decoder printed a message with a wrong field.
* **Unit tests**: frames built field by field (an uplink, a downlink with its message number and flight, a general
  response with label `_` DEL, a 200-character block with ETB), the inverted bit stream, repairs of one to three
  characters, the CRC and combinations, a refusal of four damaged characters, the CRC's check value (0x2189 as
  CRC-16/KERMIT); the demodulator on MSK from a modulator written in the test with a 0.2% clock error at about 13 dB,
  fed in odd-sized blocks; and two channels 425 kHz apart from one 2 MS/s capture.
* **Not done:** reassembling multi-block messages (each block is printed, with "(more)" when another follows), and
  decoding the labels' contents (ARINC 620 message formats, such as positions in H1 or Q0 reports). VDL Mode 2, which
  carries the same messages, follows below.

### VDL Mode 2

VDL Mode 2 sends bursts of D8PSK at 10 500 symbols/s (31.5 kbit/s) on 25 kHz channels, the pulses shaped by a raised
cosine (α 0.6) in the transmitter only, as ETSI EN 301 841-1 has it. A burst is five ramp-up symbols, a 16-symbol
synchronisation sequence, a header (three reserved bits, the length in bits, five check bits of a (25, 20) code), then
the data in Reed-Solomon (255, 249) blocks over GF(256), the last block's check octets cut to 0, 2 or 4 when it is
short, interleaved by column; everything after the synchronisation is scrambled (x^15 + x + 1). The data are AVLC
frames: HDLC (flags, bit stuffing, the X.25 FCS) with 4-octet addresses. The format follows dumpvdl2 by Tomasz Lemiech
(GPL-3.0, read for these facts only); the Reed-Solomon code is UAT's, already in this package. The receiver is new:

* **Channels** (`VDL2Receiver`). Each channel has its own oscillator, a second-order CIC and a windowed-sinc low-pass to
  42 kS/s (four samples a symbol), flat to ±13 kHz so that a carrier several kilohertz off still passes whole.
* **Finding bursts** (`VDL2Demodulator`). Each sample times the conjugate of the sample a symbol earlier keeps the phase
  steps and turns the carrier offset into a constant angle, so the correlation of those products with the sequence's
  steps finds a burst and measures its offset at once, for offsets up to half the symbol rate. It is normalised by its
  largest possible value for products of that energy, so a window that a few strong samples dominate (a burst's ramp)
  does not score; the noise floor follows the quietest stretches. Every candidate starts its own decoder, so a false
  start does not hide a real burst behind it.
* **Demodulation.** Each burst is moved by its offset and filtered by (raised cosine α 0.35) / (raised cosine α 0.6):
  the result is α 0.35 pulses, still free of intersymbol interference, with 0.3 dB less signal-to-noise than a matched
  filter could give (a flat filter wide enough for the pulses loses 1.3 dB; a filter matched to the raised cosine
  leaves interference at −13 dB, too much for eight phases). The synchronisation symbols' known phases set the carrier
  phase and the remaining frequency error; a decision-directed loop then follows the carrier, a Gardner detector the
  timing (cubic interpolation between samples), and the symbols are the phase steps between decisions, so a slip of
  the loop costs one symbol rather than the rest of the burst.
* **Soft decisions.** Each decision's distance from the boundary (π/8 less the phase error) says how sure it is. The
  header is repaired by the cheapest pattern of one or two bits that fits; a Reed-Solomon block the code cannot repair
  as received is tried again with its least reliable octets erased (erasures cost half what errors do), keeping two
  syndromes in hand so that a wrong repair stays unlikely; if a frame still fails its FCS, a second pass uses the code
  to its limit and is taken only if every frame's FCS then holds. Frames are read from every bit of the data octets,
  so a length wrong in its lowest bits (which the header code cannot see) costs nothing.
* **Frames** (`AVLCFrame`, `VDL2XID`). Addresses (aircraft, ground station, all stations), the A/G and C/R bits,
  information, supervisory and unnumbered frames; ACARS in information frames (FF FF 01 and the ACARS block with its
  own CRC, parsed by the ACARS decoder above); XID frames named as ICAO 9776 tabulates them (GSIF, link establishment,
  handoff, …) with the aircraft's position and altitude, destination airport, airport coverage, nearest airport,
  frequencies and alternate ground stations decoded. Output is a line a frame, dumpvdl2's JSON, or raw frames.

How it was checked:

* **Synthetic I/Q.** `Tools/vdl2-oracle.py` builds bursts from the format alone: random ACARS uplinks and downlinks, a
  ground station's GSIF, an aircraft's link establishment with its position, receive-ready frames, one to three a
  burst; dumpvdl2 decodes all of its clean output, every field as built. `Tools/vdl2-oracle-compare.py` gives both
  decoders the same u8 file at 1.05 MS/s (three channels, 60 bursts) at each Eb/N0; a frame counts when every octet,
  FCS included, is one that was sent:

  | Eb/N0 | 20 dB | 16 | 14 | 13 | 12 | 11 | 10 | 9 |
  |---|---|---|---|---|---|---|---|---|
  | this receiver | 121 | 121 | 121 | 120 | 113 | 94 | 39 | 7 |
  | dumpvdl2 2.7.0 | 121 | 120 | 46 | 10 | 3 | 1 | 0 | 0 |

  | carrier offset, transmitter clock | +1 kHz, 0 | 0, +50 ppm | +3 kHz, +50 ppm | −5 kHz, −50 ppm |
  |---|---|---|---|---|
  | this receiver at 20 / 14 dB | 121 / 120 | 121 / 120 | 121 / 121 | 121 / 115 (12 dB) |
  | dumpvdl2 at 20 / 14 dB | 119 / 37 | 121 / 53 | 2 / 1 | 0 / 0 (12 dB) |

  Neither printed a frame that was not sent. dumpvdl2's filter (two poles at 8 kHz) and its differential detection
  sampled once a symbol are what it loses on: this receiver gets the same share of frames 3.5 to 4 dB lower, and a
  dongle's crystal error of a few
  kilohertz at 137 MHz costs it nothing (dumpvdl2 needs `--correction` for that).
* **dumpvdl2's own test recording** (`test/vdl2_model_16b_1050kHz.wav`, GPL-3.0, not included; converted to u8): both
  frames decode, octet for octet as dumpvdl2 prints them, although its pulses are narrower than the raised cosine.
* **Unit tests**: the header code (every single bit repaired, two with reliabilities, the length limits), the
  scrambler's period, the block layout rules, bursts built from frames and decoded back for six sizes up to three
  blocks, Reed-Solomon repairs with and without erasures (and that four errors are beyond the code alone), erasure
  and error decoding against the code's limits; AVLC addresses (against an address from dumpvdl2's recording), ACARS
  in an information frame, a GSIF, a link establishment with position, supervisory and unnumbered frames; the
  demodulator on bursts from a modulator written in the test (2.5 kHz off, the clock 40 ppm fast, about 14 dB,
  odd-sized blocks); two channels from one capture; noise alone.
* **Not done:** the ATN's ADS-C (below), IDRP, reassembling ACARS messages sent in several blocks, a database of ground
  stations and aircraft, and VDL Mode 2's own MAC timing (only reception is needed).

#### ATN: CPDLC and context management

In Europe (and in Link 2000+ airspace elsewhere) aircraft talk to ATC over VDL2 with the Aeronautical Telecommunication
Network instead of ACARS: the AVLC information field is an X.25 packet (ISO 8208, modulo 8) carrying ISO 8473 CLNP, usually
with the compressed header of ICAO Doc 9705, over ISO 8073 class 4 transport, and above that the ULCS: short-form session
PDUs, the presentation layer's "fully encoded data" or nothing at all, ACSE, and the applications CPDLC (controller-pilot
messages: the 238 uplink and 114 downlink message elements, "CLIMB TO [level]", "REQUEST DIRECT TO [position]", free text)
and context management (CM: logon, contact and forward requests). Everything above X.25 is ASN.1 in unaligned PER. What is
read, in `ATNDecoder` (the layers) and `ASN1Schema` (the ASN.1):

* **X.25** (`X25Packet`): call requests and accepts (addresses, facilities, the SNDCF compression identifier), data packets with their
  sequence numbers and the more bit (joined before the next layer reads them), clear, reset and restart packets with their
  causes, receive ready and reject, diagnostics.
* **CLNP** (`CLNPHeader`): full headers (addresses, segmentation part) and the compressed data PDU (priority, flags, local
  reference, PDU id, segment offset and length), segments joined by offset; error reports and ES-IS (hold time) are named, IDRP is
  recognised and left as bytes.
* **Transport** (`COTPTPDU`): connect request and confirm, disconnect request and confirm, data (normal and extended
  formats, the end-of-TSDU bit, joined when it is clear), acknowledgements, rejects and errors, several TPDUs in one NSDU.
  A connect request's AE-qualifier (ACSE, 22 for CPDLC, 1 for context management) is remembered with its transport
  references and the two stations, so that the data that follows is read as that application. Without that, a context
  management message on the data path has no marker of its own and reads as CPDLC if the bits allow (dumpvdl2 does the same);
  the connection is forgotten at its disconnect.
* **ULCS**: short-form session PDUs (connect, accept, refuse), presentation fully encoded data (contexts 1 and 3), ACSE
  association requests, responses, releases and aborts, and the user information they carry.
* **Applications**: CPDLC as the ATN carries it, the protected-mode PDUs (`ProtectedGroundPDUs`, `ProtectedAircraftPDUs`)
  whose messages are PER encodings inside bit strings, and the aborts; CM. The wording of each message element comes from the
  schema's own comments, its parameters are shown with the units the schema's comments give ("43180 Feet").

The ASN.1 is Wireshark's copies (GPL-2.0-or-later) of ICAO Doc 9705's modules in `Tools/asn1`, parsed at run time by a small
ASN.1 parser (`ASN1Schema`) and read and written by a PER codec (`ASN1PER`): sequences with their extension bit and optional
bitmap, choices ordered by tag as PER indexes them (declaration order under automatic tags), extension additions as open types,
enumerations, constrained and unconstrained integers, size-constrained strings, bit and octet strings, object identifiers,
open types, named integers with their constraint after the braces, repeated extension markers.

```
rtlsdr-tool vdl2 --region eu                         # ATN traffic is decoded below each frame; --json adds an "atn" object to "avlc"
rtlsdr-tool atn --frames frames.txt [--json]         # AVLC frames in hexadecimal, a line each (what `vdl2 --raw` prints, frequency first)
```

How it was checked:

* **dumpvdl2 on random traffic** (`Tools/atn-oracle-compare.py`). `rtlsdr-tool atn-sample` makes random messages of every
  CPDLC and CM type as values of the ASN.1 types (so every message element and nested type is exercised, with and without
  extension alternatives and additions), PER-encodes them with this package's encoder, and wraps them in every layer: X.25 data
  packets (a third split in two), compressed and full CLNP headers, data, connect, confirm and disconnect TPDUs, the short
  session form, fully encoded data, association requests and aborts. dumpvdl2, whose decoders asn1c generated from the standard,
  and this package decode the same frames. Over 4 200 messages (seeds 21 to 25 at 600, 31 to 34 at 300, and more), every message
  that both read has the same alternatives at every level (modulo naming: dumpvdl2 calls `levelFeet` `feet`, and prints no
  alternative for latitudes and longitudes), the same strings and the same message numbers; the only ones not compared are
  context management messages sent as plain data after a connection that only this package remembers. The comparison found three
  differences between Wireshark's text and what dumpvdl2 (which decodes live traffic) has, all now patched
  (`ATNSchema.make()`): `TrafficType` has no `noneSpecified (0)`; `LevelSpeed` has one `speed`, not `SpeedSpeed`'s two; and
  the two modules' `VersionNumber` are different types (a global namespace here let the CPDLC one replace the CM one; every
  module has its own scope now).
* **Constraint tables** (`Tools/atn-schema-compare.py`): the PER-visible constraint of every named integer, enumeration, string and
  SEQUENCE OF type (155 types) is the same as asn1c's, except dumpvdl2's `TrafficType`. Member types of sequences differ in
  name only (aliases such as `AirportDeparture`) except `LevelSpeed`.
* **Through the radio path**: `Tools/vdl2-oracle.py --frames` sends such frames as D8PSK bursts and `rtlsdr-tool vdl2` reads them back
  with the ATN layers decoded.
* **Unit tests**: PER encodings worked by hand from X.691 (constrained and unconstrained integers, strings, choices ordered
  by tag or declaration, extensions, enumerations, object identifiers), 1 500 random values of the ATN and ACSE types
  round-tripped, every X.25 packet type, compressed and full CLNP headers, every TPDU kind, a CPDLC downlink and uplink and
  CM messages through all the layers, an abort, packets and segments and fragments joined, the connection's application
  remembered and forgotten, text with units, random bytes never trapping the decoder.
* **Not done:** ADS-C (ATN B2's ASN.1, `ADSGroundPDUs`, and the FANS-1/A ADS-C and CPDLC that ACARS carries as ARINC 622
  messages are not in the packaged modules, and the only copies of the schema seen are dumpvdl2's generated code, GPL-3.0),
  IDRP, CLNP and COTP options (skipped, their length used), the unprotected `GroundPDUs` and `AircraftPDUs` (dumpvdl2 reads only the
  protected ones either), CPDLC's own integrity checks, and any real traffic. The two schema deviations are what dumpvdl2
  has, not something confirmed on air.

## Speed

Decoding the oracle recordings on one core of the Linux build machine: ADS-B 2.4 s of signal in 0.29 s (release build)
or 4.5 s (debug build); UAT 1.17 s of signal in 0.04 s (release) or 0.84 s (debug); ISM 122 s of signal in 0.74 s
(release; rtl_433 takes 0.44 s); Meteor-M LRPT 36 s of I/Q in 1.8 s (the 80k mode 48 s in 3.2 s) (release, to images; meteor_demod's
demodulation alone takes 0.74 s) or 35 s of soft symbols in 0.5 s; RS41 120 s of I/Q at 240 kS/s in 1.2 s, or of FM audio in 0.4 s; DFM 40 s of I/Q at 240 kS/s in 0.65 s (60× real time); M10 30 s at 288 kS/s in 1.4 s (21×); twelve Meshtastic listeners on a 2 MS/s capture 3.3 s in 0.95 s (3.5× real time, on four cores). LoRa LongFast 7 s of I/Q at 1 MS/s in 0.85 s (8× real time; SF7 9×). ACARS five channels from 6.4 s of I/Q at 2.4 MS/s in 1.0 s (6× real time); VDL Mode 2 four channels from 4.1 s at 1.05 MS/s in 0.6 s (7×; dumpvdl2 0.22 s of CPU over its threads). Live, a decoder
that falls behind
drops whole blocks and reports it rather than queueing without limit, so use a release build for ADS-B.

## Rerunning the comparisons

The oracles need dump1090-mutability, dump978, rtl_433, meteor_demod, SatDump, rs41mod, dfm09mod, m10m20mod, GNU Radio 3.10 with gr-lora_sdr,
acarsdec, dumpvdl2 and a few Python packages; none of
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

Tools/lrpt-oracle.py frames.cadu i80.u8 --interleave --esn0 4                               # the 80k mode
rtlsdr-tool meteor --ifile i80.u8 --symbol-rate 80000; satdump meteor_m2-x_lrpt_80k baseband i80.u8 sd80 --samplerate 288000 --baseband_format cu8
Tools/lrpt-encode.py scene.cadu --scene-out scene/                                          # numpy, reedsolo
Tools/lrpt-oracle.py scene.cadu scene.u8 --mode oqpsk --offset -800 --doppler 2500 --esn0 11   # numpy
rtlsdr-tool meteor --ifile scene.u8 --mode oqpsk --out ours --cadu ours.cadu                  # compare with scene.cadu, scene/
meteor_demod -B -s 288000 --bps 8 -m oqpsk -o md.s scene.u8 && rtlsdr-tool meteor --soft md.s --mode oqpsk
satdump meteor_m2-x_lrpt baseband scene.u8 sd --samplerate 288000 --baseband_format cu8

git clone https://github.com/EliasOenal/multimon-ng && cmake -S multimon-ng -B multimon-ng/build && make -C multimon-ng/build
Tools/pocsag-oracle-compare.py multimon-ng/build/multimon-ng rtlsdr-tool /tmp/pocsag --baud 1200 --cnr=20,12,9,7 --seeds 1,2,3    # numpy, scipy
Tools/pocsag-oracle-compare.py multimon-ng/build/multimon-ng rtlsdr-tool /tmp/pocsag --baud 2400 --invert --offset -2500

git clone https://github.com/rs1729/RS && (cd RS/imet && gcc imet1rs_dft.c -lm -o imet1rs_dft)
Tools/imet-oracle-compare.py RS/imet/imet1rs_dft rtlsdr-tool /tmp/imet --cnr=25,14,11,10,9,8 --seeds 1,2 --seconds 60   # numpy, scipy
Tools/imet-oracle-compare.py RS/imet/imet1rs_dft rtlsdr-tool /tmp/imet --cnr 20,12 --baud 1195 --offset -4500   # a baud rate imet1rs_dft cannot follow
(cd RS/demod/mod && gcc -c demod_mod.c bch_ecc_mod.c && gcc rs41mod.c demod_mod.o bch_ecc_mod.o -lm -o rs41mod)
Tools/sonde-oracle-compare.py RS/demod/mod/rs41mod rtlsdr-tool RS/rs41/wav/*.wav --invert
RS/demod/mod/rs41mod -i --ecc2 -r RS/rs41/wav/20140717_402MHz.wav > frames.txt              # dewhitened frames
Tools/rs41-oracle.py frames.txt sonde --ebn0 9 --offset 3000                              # numpy
rtlsdr-tool sonde --ifile sonde.u8 --json; RS/demod/mod/rs41mod --IQ 0.0125 --lpIQ --ecc2 --json sonde.wav

(cd RS/demod/mod && gcc dfm09mod.c demod_mod.o -lm -o dfm09mod && gcc m10m20mod.c demod_mod.o -lm -o m10m20mod)
Tools/dfm-oracle-compare.py RS/demod/mod/dfm09mod rtlsdr-tool /tmp/dfm --esn0=16,12,10,9,8,7,6 --seeds 1,2,3 --seconds 40    # numpy
Tools/dfm-oracle-compare.py RS/demod/mod/dfm09mod rtlsdr-tool /tmp/dfm --model dfm17p --esn0 12 --invert --offset -9000 --drift 5000
Tools/m10-oracle-compare.py RS/demod/mod/m10m20mod rtlsdr-tool /tmp/m10 --esn0=14,12,10,9,8,7,6 --seeds 1,2,3 --seconds 30    # numpy
Tools/m10-oracle-compare.py RS/demod/mod/m10m20mod rtlsdr-tool /tmp/m10 --model m20 --baud 9616 --deviation 5200 --offset -8000
Tools/dfm-oracle.py dfm --model dfm09 --esn0 12 && rtlsdr-tool sonde --type dfm --ifile dfm.u8 --json; RS/demod/mod/dfm09mod --IQ 0.0125 --lpIQ --ecc --ptu --json dfm.wav
MESH_GRID_DUMP=grid.u8 swift test --filter aGridAlignedCapture                              # a capture of three presets on the US slot grid
rtlsdr-tool mesh --presets ShortFast,ShortSlow,MediumFast --all-slots --region US --ifile grid.u8 --rate 2000000 --center 906500000

git clone https://github.com/tapparelj/gr-lora_sdr                                        # GNU Radio 3.10 module (862746d)
Tools/generate-lora-vectors.py Tests/RTLSDRDecodersTests/Resources/lora-symbol-vectors.txt
Tools/lora-oracle-compare.py rtlsdr-tool payloads.txt /tmp/lora --snr=-8,-10,-12,-14,-16,-18,-20,-21 --ppm 10
Tools/lora-oracle-compare.py rtlsdr-tool payloads.txt /tmp/ls --sf 12 --bw 125000 --cr 4 --ppm 20 --snr=-14,-17,-20,-22
Tools/meshtastic-vectors.py Tests/RTLSDRDecodersTests/Resources/meshtastic-packets.txt     # openssl
awk '!/^#/{print $4}' Tests/RTLSDRDecodersTests/Resources/meshtastic-packets.txt > mesh.txt
Tools/lora-oracle.py tx mesh.txt mesh --ppm 20 --snr -12 && rtlsdr-tool mesh --ifile mesh.u8 --channel Secret:AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dw=

git clone https://github.com/TLeconte/acarsdec && cmake -S acarsdec -B acarsdec/build -Drtl=ON && make -C acarsdec/build   # 339f63e; librtlsdr, libsndfile
rtlsdr-tool acars --wav acarsdec/test.wav --json; acarsdec/build/acarsdec -o 4 -f acarsdec/test.wav
Tools/acars-oracle-compare.py rtlsdr-tool acarsdec/build/acarsdec /tmp/acars --audio-snr=8,6,5,4,3,2 --snr=15,12,10,9,8,7   # numpy

git clone https://github.com/szpajder/libacars && git clone https://github.com/szpajder/dumpvdl2   # 9af09a0, 686e87f
(cd libacars && cmake -B build && make -C build install) && (cd dumpvdl2 && cmake -B build && make -C build)   # glib 2
Tools/vdl2-oracle-compare.py rtlsdr-tool dumpvdl2/build/src/dumpvdl2 /tmp/vdl2 --ebn0=20,16,14,13,12,11,10,9   # numpy
Tools/vdl2-oracle-compare.py rtlsdr-tool dumpvdl2/build/src/dumpvdl2 /tmp/vdl2 --ebn0=20,14,12 --offset 3000 --ppm 50
Tools/atn-oracle-compare.py rtlsdr-tool dumpvdl2/build/src/dumpvdl2 /tmp/atn --count 600 --seeds 21,22,23 --tally            # CPDLC and CM through every ATN layer, python only
Tools/atn-oracle-compare.py rtlsdr-tool dumpvdl2/build/src/dumpvdl2 /tmp/atn --count 300 --seeds 31,32 --extensions
Tools/atn-schema-compare.py rtlsdr-tool dumpvdl2/src/asn1                                                                    # constraints and member types against asn1c's
rtlsdr-tool atn-sample --count 12 --seed 7 --kinds 0,1,5,2 > frames.jsonl   # then: Tools/vdl2-oracle.py out --frames frames.hex --channels 136.975e6 --center 137e6
```
