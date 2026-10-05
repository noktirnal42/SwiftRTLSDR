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
| Meshtastic decoder | A Meshtastic node on the default channel (or your own, with `--channel NAME:KEY` as the app shares it) within range: its text messages, node info and positions decode as its app shows them; the frequency is the app's; the carrier offset reported is this dongle's crystal error plus the node's; the 1 MS/s rate and the channel 250 kHz off-centre work on this driver (the dongle's own filtering near the band edge is unmeasured). A second node beside the dongle shows the SNR it receives the same packets at, for comparison | `rtlsdr-tool mesh --region US` (or `EU_868`, `ANZ`, …; `--preset` for others), `--json --verbose` to see every LoRa frame |
| ACARS decoder | Near an airport, messages appear on 131.550 MHz (US) or 131.525/131.725 MHz (Europe) with registrations and flights that an online tracker shows nearby; run acarsdec on a second dongle and compare counts; the levels reported track the signal; all five US channels decode from one 2.4 MS/s capture without dropped blocks | `rtlsdr-tool acars --region us` (or `--region eu`, `--freq 131.550,131.725`), `--json` for acarsdec's fields |
| VDL Mode 2 decoder | Near an airport, frames on 136.975 MHz and the regional channels: ground stations' GSIFs every few seconds, ACARS between aircraft and ground with registrations an online tracker shows nearby, aircraft positions in their log-ons; run dumpvdl2 on a second dongle and compare frame counts; the frequency offset reported matches this dongle's crystal error; four channels at 1.05 MS/s without dropped blocks | `rtlsdr-tool vdl2 --region eu` (or `us`, or `--freq 136.975,136.875`), `--verbose` for offsets and repairs, `--json` for dumpvdl2's fields |
| Calibration (`calibrate`) | On a signal generator (or a GPSDO-locked source) at a known frequency, the ppm reported matches what `kalibrate-rtl` or a known-good receiver says, run to run within 0.1 ppm once the dongle is warm; `--write` stores it (**EEPROM write: a dongle you can afford to lose**), `--show` reads it back after replugging, `--ppm eeprom` applies it and the carrier then sits where it should | `rtlsdr-tool calibrate --freq <Hz> --seconds 20`, `--write --label test`, `--show`, `capture --ppm eeprom` |
| Hydrogen line (`hline`) | With a dish or horn and an LNA (and its power), pointing at the Milky Way: the ratio shows the line near 1420.4 MHz, moving with pointing and over the year as the LSR column predicts; pointing away gives a flat ratio. Without them, a flat ratio (no false line from the bandpass or the DC spike) | `rtlsdr-tool hline --seconds 1800 --lat <yours> --lon <yours> --az <A> --el <E>` |
| Meteor-M LRPT decoder | During a pass (predict one with any satellite tracker; Meteor-M N2-3 and N2-4 are on 137.9 or 137.1 MHz) the dashboard locks, frames decode and the image builds; the 288 kS/s rate streams without dropped blocks; compare with SatDump on a `capture` of the same pass. A 137 MHz antenna (V-dipole or QFH) is needed; a whip rarely gets a usable signal | `rtlsdr-tool meteor --web 8080 --out pass/` (`--freq 137.1e6` if needed; `--symbol-rate 80000` for a pass in the 80k mode, whose frames start about 18 s in), or `capture --freq 137.9e6 --rate 288000` then `meteor --ifile` |

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
