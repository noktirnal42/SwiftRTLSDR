# Hardware verification matrix

What was actually tested, on what. If a row says "not tested", it is not known to work. Please add rows (with the
trace or capture that supports them) if you test something else.

## Tested setup (2026-09-29)

| | |
|---|---|
| Dongle | "Generic RTL2832U OEM": Realtek **RTL2838UHIDIR**, USB `0bda:2838`, serial `00000001` |
| Tuner | Rafael Micro **R820T** (chip ID 0x69), identified by the driver |
| Antenna | **None attached** (input open) |
| Host | Apple silicon Mac, macOS 27, Xcode 27 / Swift 6 |
| Reference | Homebrew `librtlsdr` 2.0.2 (`rtl_sdr`, `rtl_test`) on the same dongle |

## Results

| Check | Result |
|---|---|
| Open, identify tuner, initialise | Works |
| Tuner status readback | Works (PLL lock flag, VCO sub-band) |
| Oscillator lock, 24-1765 MHz in 5 MHz steps (349 points) | **Locked at every point**, no failures. 20 MHz and 1770 MHz upward are refused by the range check |
| Frequency actually produced | **Not measured** (no reference signal). Lock is not proof of accuracy |
| Retune time | Mean 27 ms, slowest 43 ms (many small USB transfers per retune) |
| Streaming 250 kS/s, 20 s | 100.7 % of nominal (measurement window edge effect), longest gap 132 ms (block = 65536 B at this rate) |
| Streaming 2.4 MS/s, 20 s | 100.07 % of nominal, longest gap 15 ms |
| Streaming 3.2 MS/s, 20 s | 99.85 % of nominal, longest gap 15 ms, no stream error |
| Sample continuity / dropped samples | Throughput matches nominal, which is consistent with no FIFO overflow; a known test signal was not available to prove it |
| Gain steps 0-49.6 dB | Track `rtl_sdr` step for step (including a non-monotonic step near 48-49.6 dB that both show) |
| Register state vs real `rtl_sdr`, 7 sessions | Identical at stream start and after close (golden-trace tests) |
| Received level vs `rtl_sdr` | **About 1.7 dB lower**, constant across gains and band; see [docs/LEVEL-DIFFERENCES.md](docs/LEVEL-DIFFERENCES.md) |
| Spur-over-noise-floor vs `rtl_sdr` | Same within ~0.8 dB (native equal or slightly better) |
| ppm correction | Register state identical to `rtl_sdr` at 5 ppm; the effect on a real signal was not measured |
| Sandboxed app use | Not yet tested at the time of writing (needs the USB entitlement) |

## Added 2026-09-30, not yet run on any dongle

Each of these passes its tests against the fake dongle, synthetic signals or a loopback socket. None has touched
hardware. The command in the right-hand column is the check to run. Please add the result here.

| Feature | What to check | Command |
|---|---|---|
| Retune shortcuts (`setRetuneShortcuts(.all)`) | Lock at every point as before; retune time against the 27 ms baseline; that received level and spurs are unchanged with the I2C repeater left on | `rtlsdr-tool lockscan --fast`, `rtlsdr-tool retunebench`, `rtlsdr-tool retunebench --streaming`, `capture` with and without `--fast` |
| Overload guard / host AGC | Gain backs off on a strong signal and returns; no hunting; thresholds sensible for real signals | `rtlsdr-tool monitor --freq <strong station> --guard --gain 49.6`, `... --agc -25` |
| Oscillator settling after a retune | The scanner discards 2 ms after each retune; that figure is a guess | `rtlsdr-tool scan` with a known carrier, varying the settle time in code |
| Band scan | Known carriers found at the right frequency; no false detections at hop centres (DC) or hop edges | `rtlsdr-tool scan --from 88e6 --to 108e6` (FM broadcast), `--csv` to inspect |
| EEPROM read | Matches `rtl_eeprom -r` byte for byte | `rtlsdr-tool eeprom --out ours.bin` |
| Serial provisioning (EEPROM write) | Only the serial bytes change; read-back verifies; the dongle enumerates with the new serial after replugging. **Use a dongle you can afford to lose** | `rtlsdr-tool set-serial TEST01` (dry run), then `--write` |
| `rtl_tcp` server | SDR#, GQRX or SDR++ connect, tune and show a live spectrum; a slow network drops data instead of stalling | `rtlsdr-tool serve --address 0.0.0.0` |
| ADS-B decoder | Aircraft appear with sensible positions and callsigns; compare with dump1090 or an online tracker at the same time; count messages per minute against dump1090 on the same antenna | `rtlsdr-tool adsb --lat <yours> --lon <yours>` (a 1090 MHz antenna helps a lot) |
| UAT decoder (US only) | Ground-station uplinks decode; METARs match the published ones; radar PNGs match a radar map for the same time | `rtlsdr-tool uat --nexrad radar/` near a UAT ground station |
| ISM sensor decoder | The neighbourhood's weather stations and thermometers appear, with the readings their displays show; run rtl_433 on a second dongle (or on a `capture` at 250 kS/s) and compare; the 250 kS/s rate works on this driver | `rtlsdr-tool ism --json` (433.92 MHz); `--freq 868.3e6` or `915e6` for FSK sensors |
| RS41 radiosonde decoder | A sonde near a launch site (they rise twice a day at 00 and 12 UTC; SondeHub's map shows where and on what frequency) decodes with the position SondeHub shows; the carrier search finds it with this dongle's crystal error; `--scan` finds it without a frequency. Compare with radiosonde_auto_rx or rs41mod on a `capture` | `rtlsdr-tool sonde --freq 403.5e6`, `rtlsdr-tool sonde --scan --verbose` |
| DFM radiosonde decoder | A DFM-06, -09 or -17 near a launch site (Graw sondes, used in Germany and a few other countries; SondeHub's map shows type and frequency): position, time and serial match SondeHub's; the temperature matches the ground station's within a degree or two. The tone detector assumes ±2.4 kHz deviation (`--deviation` changes it): check the sonde's real figure on a `capture`'s spectrum, and whether the polarity-dependent DFM-06 / DFM-09 split in the serial channels comes out right. Compare with radiosonde_auto_rx or dfm09mod | `rtlsdr-tool sonde --type dfm --freq 403.5e6`, `--verbose` for blocks and tuning |
| M10 / M20 radiosonde decoder | An M10 or M20 near a launch site (Meteomodem sondes, used in France and elsewhere): position, time, serial and temperature as SondeHub shows. The tone detector assumes ±4.32 kHz deviation (`--deviation`); the symbol rate (9600 or about 9616) is found per frame. The M10+ (Gtop GPS) is checked on synthetic frames only | `rtlsdr-tool sonde --type m10 --freq 404.4e6` |
| iMet-1 / iMet-4 radiosonde decoder | An iMet near a launch site (InterMet sondes, used in the US and elsewhere: SondeHub's map shows type and frequency): position, altitude and time of day match SondeHub's; pressure, temperature and humidity are plausible for the altitude. The receiver assumes ±3 kHz deviation and 1200/2200 Hz tones (`--cutoff 7000` widens the channel for a larger deviation): check on a `capture`'s spectrum. Compare with radiosonde_auto_rx or imet1rs_dft on FM audio | `rtlsdr-tool sonde --type imet --freq 403.5e6`, `--verbose` for packets and tuning |
| Meshtastic, several presets at once | Two or more presets on one capture (EU_868 has them all on one slot; elsewhere `--all-slots --center <Hz>` listens to the slots around a centre): each node's packets come out against the preset and frequency it used, once; check against a second dongle on one preset that nothing is missed or doubled, and that the 2 MS/s capture is steady on this dongle | `rtlsdr-tool mesh --region EU_868 --presets LongFast,MediumFast,ShortFast`, `rtlsdr-tool mesh --presets LongFast,MediumFast --all-slots --center 906.4e6` |
| Meshtastic decoder | A Meshtastic node on the default channel (or your own, with `--channel NAME:KEY` as the app shares it) within range: its text messages, node info and positions decode as its app shows them; the frequency is the app's; the carrier offset reported is this dongle's crystal error plus the node's; the 1 MS/s rate and the channel 250 kHz off-centre work on this driver (the dongle's own filtering near the band edge is unmeasured). A second node beside the dongle shows the SNR it receives the same packets at, for comparison | `rtlsdr-tool mesh --region US` (or `EU_868`, `ANZ`, …; `--preset` for others), `--json --verbose` to see every LoRa frame |
| ACARS decoder | Near an airport, messages appear on 131.550 MHz (US) or 131.525/131.725 MHz (Europe) with registrations and flights that an online tracker shows nearby; run acarsdec on a second dongle and compare counts; the levels reported track the signal; all five US channels decode from one 2.4 MS/s capture without dropped blocks | `rtlsdr-tool acars --region us` (or `--region eu`, `--freq 131.550,131.725`), `--json` for acarsdec's fields |
| VDL Mode 2 decoder | Near an airport, frames on 136.975 MHz and the regional channels: ground stations' GSIFs every few seconds, ACARS between aircraft and ground with registrations an online tracker shows nearby, aircraft positions in their log-ons; run dumpvdl2 on a second dongle and compare frame counts; the frequency offset reported matches this dongle's crystal error; four channels at 1.05 MS/s without dropped blocks | `rtlsdr-tool vdl2 --region eu` (or `us`, or `--freq 136.975,136.875`), `--verbose` for offsets and repairs, `--json` for dumpvdl2's fields |
| Calibration (`calibrate`) | On a signal generator (or a GPSDO-locked source) at a known frequency, the ppm reported matches what `kalibrate-rtl` or a known-good receiver says, run to run within 0.1 ppm once the dongle is warm; `--write` stores it (**EEPROM write: a dongle you can afford to lose**), `--show` reads it back after replugging, `--ppm eeprom` applies it and the carrier then sits where it should | `rtlsdr-tool calibrate --freq <Hz> --seconds 20`, `--write --label test`, `--show`, `capture --ppm eeprom` |
| Hydrogen line (`hline`) | With a dish or horn and an LNA (and its power), pointing at the Milky Way: the ratio shows the line near 1420.4 MHz, moving with pointing and over the year as the LSR column predicts; pointing away gives a flat ratio. Without them, a flat ratio (no false line from the bandpass or the DC spike) | `rtlsdr-tool hline --seconds 1800 --lat <yours> --lon <yours> --az <A> --el <E>` |
| Meteor-M LRPT decoder | During a pass (predict one with any satellite tracker; Meteor-M N2-3 and N2-4 are on 137.9 or 137.1 MHz) the dashboard locks, frames decode and the image builds; the 288 kS/s rate streams without dropped blocks; compare with SatDump on a `capture` of the same pass. A 137 MHz antenna (V-dipole or QFH) is needed; a whip rarely gets a usable signal | `rtlsdr-tool meteor --web 8080 --out pass/` (`--freq 137.1e6` if needed; `--symbol-rate 80000` for a pass in the 80k mode, whose frames start about 18 s in), or `capture --freq 137.9e6 --rate 288000` then `meteor --ifile` |

## Run on the dongle 2026-10-07

Same dongle as above (R820T, serial `00000001`), now with a small antenna attached (an FM broadcast scan finds two
carriers, 95.999 and 105.599 MHz, at 17-21 dB SNR; no 1090 MHz, VHF-aviation or 403 MHz antenna). Apple silicon Mac,
macOS 27, Swift 6.4. The package builds on macOS with no warnings or errors and all 196 tests pass there (the first
macOS build of the DFM, M10, ACARS, VDL2 and multi-preset Meshtastic code). Release build (`swift build -c release`)
for everything that streams: the debug build cannot keep up with a five-channel ACARS capture.

| Check | Result |
|---|---|
| `lockscan --fast` | Locked at all 349 points, none failed; mean retune **11.7 ms**, slowest 30 ms |
| `retunebench` (shortcuts off / on) | Small steps 27.2 / **11.8 ms**; band hops 31.4 / **16.0 ms**; never unlocked in 200 retunes. While streaming: 26.0 / 11.4 and 30.2 / 15.5 ms |
| Level and spur with the shortcuts | FM carrier at 96 MHz, 2 s capture each way: -39.7 vs -39.9 dBFS, 43.4 vs 43.7 dB over the median; no change beyond noise |
| `scan --from 88e6 --to 108e6` | Two carriers found, at 95.9992 and 105.5992 MHz (the station frequencies less about 0.8 kHz, within a 2.3 kHz bin; the DC spike at hop centres produced no false detection) |
| `monitor --guard`, `--agc -25` | Idle behaviour only: the level holds and the AGC settles to -25 dBFS in about 5 s without hunting. **The backoff on a strong signal was not exercised** (nothing strong enough) |
| EEPROM read | `rtlsdr-tool eeprom` is **byte for byte identical** to `rtl_eeprom -r` (256 bytes) |
| `rtl_tcp` server | A client speaking the protocol gets the `RTL0` header (tuner type 5, 29 gains), tunes, sets the rate and gain, and receives 4.09 MB/s (nominal 4.10) for 3 s. SDR#, GQRX and SDR++ were not tried |
| ACARS, 5 US channels at 2.4 MS/s | No dropped blocks over 90 s in a release build. **No message was received** (no antenna for 131 MHz) |
| VDL Mode 2, 4 US channels at 1.05 MS/s | No dropped blocks over 60 s; no frame received |
| ADS-B | No aircraft in 60 s (no 1090 MHz antenna) |
| `sonde --scan` 400-406 MHz | Two steady carriers (403.199 and 405.400 MHz) found, tried with RS41, DFM and M10 and rejected; neither is a sonde. **No sonde was in range**, so no decoder has still received a real signal, and the DFM and M10 deviations (±2.4, ±4.32 kHz) remain unconfirmed |

Not run: serial provisioning, calibration (no reference), UAT, ISM, Meshtastic, Meteor, hydrogen line.

## Not tested

* Any other dongle: RTL-SDR Blog V3 (bias tee is driven on GPIO 0 but was only exercised against the fake dongle),
  V4 (R828D tuner, **unsupported**), NooElec, R820T2 units, TCXO models, E4000 / FC0012 / FC0013 / FC2580 dongles
  (**unsupported**).
* Sensitivity, noise figure, image rejection, or any reception of a real signal.
* Direct sampling, offset tuning, and the RTL2832U's other modes (not implemented).
* Multiple dongles at once, hot-plug/unplug during streaming (the stream reports an error), USB hubs, USB 3 ports.
* Intel Macs, macOS versions other than 27, Xcode versions other than 27.

## Known limits

* One process per dongle (the OS gives the device to whoever opens it first).
* Retuning is slow (~27 ms) because every retune is many single control transfers. The opt-in retune shortcuts cut a
  same-band retune from 11 transfers to 5; how much time that saves is unmeasured.
* Only the R820T. `open` on anything else throws `unsupportedTuner` and gives the USB device back.
