# SwiftRTLSDR

A native Swift driver for RTL-SDR dongles on macOS: the Realtek **RTL2832U** USB bridge and the Rafael Micro
**R820T** tuner, talking to the hardware through Apple's `IOUSBHost` framework. No `libusb`, no `librtlsdr`, no C.

It exists because a sandboxed macOS app cannot `dlopen` a Homebrew `librtlsdr`, and because a Swift package is
easier to ship than a C library plus its dependencies. It is small (about 2,100 lines of driver code, plus two
optional libraries for scanning and network serving) and it is young. **Read "What is and isn't verified" before you
rely on it.**

## Status, honestly

* **Works on the one dongle it was developed against** (RTL2838UHIDIR, R820T, macOS 27). See [HARDWARE.md](HARDWARE.md).
* **Only the R820T tuner is supported.** RTL-SDR Blog V4 (R828D), R820T2-specific behaviour, E4000, FC0012/13, FC2580:
  not supported; opening such a dongle throws `unsupportedTuner`.
* **Not a clean-room implementation.** It is a Swift port of the R820T and RTL2832U logic in
  [librtlsdr](https://github.com/osmocom/rtl-sdr) (GPL-2.0-or-later), whose register sequences it reproduces and is
  tested against. See [PROVENANCE.md](PROVENANCE.md) and [NOTICE](NOTICE).
* **Not affiliated** with Realtek, Rafael Micro, Osmocom or the RTL-SDR Blog.
* **Received levels differ from librtlsdr by about 1.7 dB** on the tested dongle, for a reason that is understood
  only partly. Do not use it for calibrated power measurement. See [docs/LEVEL-DIFFERENCES.md](docs/LEVEL-DIFFERENCES.md).
* **No frequency-accuracy or sensitivity measurements** were made (no antenna or reference signal was available).
* **New, and not yet tried on any dongle:** the retune shortcuts, the overload guard / host AGC, band scanning, EEPROM
  writing (serial provisioning) and the `rtl_tcp` server. They are tested against a fake dongle, synthetic signals and
  a loopback socket only. `rtlsdr-tool` has a command to check each on hardware (see [HARDWARE.md](HARDWARE.md)).

## Using it

```swift
import RTLSDRKit

let device = try RTLSDRDevice.openFirst()             // or open(_:) with one of connectedDevices()
try device.setSampleRate(2_048_000)                   // 225-300 kS/s or 900 kS/s-3.2 MS/s
try device.setCenterFrequency(100_000_000)            // 24 MHz-1.766 GHz
try device.setAutomaticGain()                         // or setTunerGain(tenthsDB: 297)
try device.startStreaming { block in
    // interleaved unsigned 8-bit I, Q, I, Q ... ; runs on a USB completion queue: return quickly
}
// ...
device.stopStreaming()
device.close()
```

`readSamples(byteCount:)` is a blocking convenience for short captures. Settings can be changed from any thread (calls
are serialised); the streaming handler runs on its own queue and must not call back into the device. Only one program
can hold a dongle at a time.

A sandboxed app needs the `com.apple.security.device.usb` entitlement.

### Faster retuning (opt-in)

A retune within a band costs 11 USB control transfers. `try device.setRetuneShortcuts(.all)` cuts that to 5 by keeping
the tuner's I2C bus open between accesses and reusing the oscillator status from the previous lock check. Both depart
from the reference driver's sequence and are off by default; `rtlsdr-tool retunebench` measures what they gain.

### Overload guard and host AGC

With 8-bit samples a strong signal clips the ADC. `HostGainControl` watches the stream and steps the tuner gain: down
at least 6 dB at once when too many samples sit on the rails, back up slowly after a run of clean blocks.

```swift
let control = try HostGainControl(device: device, configuration: .overloadGuard(ceilingTenthsDB: 372))  // or .automatic(targetDBFS: -25)
try device.startStreaming { block in
    control.observe(block)            // statistics here; gain changes happen on the control's own queue
}
```

`SampleStatistics` (level, share of samples on the rails, DC offset) is usable on its own.

### Scanning (`RTLSDRScan`)

`BandScanner` sweeps a range in overlapping hops (each hop's DC spike is covered by a neighbour), stitches an averaged
spectrum and finds the signals above a local noise floor. `ScanLoop` goes on to dwell on the strongest ones with a
pluggable `SignalDecoder`, tuned a quarter of the sample rate away so the signal avoids DC, and skips frequencies that
decoded nothing for a few rounds. No decoders ship yet.

```swift
import RTLSDRScan
let scanner = try BandScanner(receiver: device, configuration: .init(range: 400_000_000...406_000_000))
let detections = scanner.detect(in: try scanner.sweep())
```

### Unique serial numbers

Generic dongles all report serial `00000001`, so `openFirst(serial:)` cannot tell two apart.
`device.setSerialNumber("ROOF-01")` rewrites only the serial string in the dongle's EEPROM, never the USB IDs and flags,
and verifies it by reading back; it returns the old contents as a backup. Replug the dongle afterwards. Untested on
hardware: try it first on a dongle you can afford to lose.

### Calibration kept on the dongle

`CarrierCalibrator` (in `RTLSDRScan`) measures the crystal's error on a carrier of known frequency: long transforms,
the line placed to a fraction of a bin, p = f/(c + m) − 1 since the tuner and the sample clock share the crystal. A
signal generator or a GPS-disciplined beacon will do, a US television station's ATSC pilot (`--atsc CHANNEL`) to a
couple of ppm (stations may sit up to about a kilohertz off the nominal pilot: measure two); a modulated signal will
not. `rtlsdr-tool calibrate` reports the ppm and with `--write` keeps it in the EEPROM's unused
second half (offsets 0x80-0xff) as a small checksummed record (`CalibrationRecord`: ppb, when, against what, a label),
written only where the area is unused or already holds such a record, after a backup. Every command that tunes then
takes `--ppm eeprom`. Untested on hardware, like the serial: try it first on a dongle you can afford to lose.

```swift
let record = try device.readCalibration()                   // nil if none
try device.setFrequencyCorrection(ppm: Int(record!.ppm.rounded()))
```

### The hydrogen line

`SwitchedSpectrometer` integrates power spectra in two tunings, on the 21 cm line and off it (frequency switching),
and their ratio divides out the dongle's bandpass, leaving the line; `LSRCorrection` turns velocities into ones about
the local standard of rest (agreeing with astropy to 0.3 km/s), from RA/Dec or from where the antenna points.
`rtlsdr-tool hline` runs it for as long as asked and writes a CSV (frequency, radio velocity, LSR velocity, both
spectra, the ratio). It needs a dish or horn and a low-noise amplifier at 1420 MHz; the bare dongle does not see the
line.

### Network server (`RTLSDRServer`)

`RTLTCPServer` serves the dongle with the `rtl_tcp` protocol that SDR#, GQRX, SDR++ and others speak. It handles one
client at a time and drops the oldest samples if a client falls behind. Bias-tee commands are refused unless allowed.
It listens on 127.0.0.1 by default, because the protocol has no authentication.

### Decoders (`RTLSDRDecoders`)

ADS-B / Mode S on 1090 MHz; UAT on 978 MHz (US general aviation) including FIS-B weather: NEXRAD radar mosaics
rendered to PNG, METAR/TAF/winds-aloft text; 433/868/915 MHz sensors the way rtl_433 decodes them (weather
stations, thermometers, remotes: AcuRite, Oregon Scientific, LaCrosse, Fine Offset/Ecowitt, Bresser and others); and
Meteor-M weather-satellite images on 137 MHz (LRPT, QPSK and offset QPSK), with a live dashboard in the browser; and
radiosondes on 400-406 MHz (Vaisala RS41, Graw DFM-06/09/17, Meteomodem M10/M20 and InterMet iMet-1/iMet-4: position, altitude, velocity,
temperature, serial number), found by scanning or on a given frequency; and AIS ships on 161.975 and 162.025 MHz (position, name, destination: the NMEA sentences or JSON); and POCSAG pager traffic on VHF/UHF (any bit rate: address, function, numeric or alphanumeric text); and Meshtastic mesh traffic on LoRa (text
messages, positions, node info, telemetry; the default channel and any channel whose key you have), on the frequency
Meshtastic picks for the preset and region, or several presets and slots at once from one capture. Meteor-M also in its
80 ksym/s interleaved mode. ACARS on VHF (airline messages), and VDL Mode 2 (its digital successor: ACARS over AVLC,
ground station announcements, aircraft logging on with their positions), every channel of a region from one capture.
`rtlsdr-tool adsb`, `uat`, `ism`, `meteor`, `sonde`, `mesh`, `acars` and `vdl2` run them live or on recorded I/Q, with
output compatible with dump1090, dump978, rtl_433, meteor_decode, rs41mod, dfm09mod, m10m20mod, acarsdec and dumpvdl2. How they were checked, and against what: [docs/DECODERS.md](docs/DECODERS.md).

```swift
import RTLSDRDecoders
let modeS = ModeSDemodulator()          // u8 I/Q at 2 MS/s
let tracker = AircraftTracker()
for frame in modeS.process(block) { tracker.update(frame.message, at: now) }

let uat = UATDemodulator()              // u8 I/Q at 2.083334 MS/s
for frame in uat.process(block) where frame.kind == .uplink {
    for product in (UATUplinkMessage(payload: frame.payload).informationFrames ?? []).compactMap(\.fisb) {
        let radar = NEXRADBlock.blocks(in: product)          // weather radar
        let text = product.reports                           // METAR, TAF, ...
    }
}

let sensors = ISMReceiver()             // u8 I/Q at 250 kS/s, tuned to 433.92 MHz
for event in sensors.process(block) { print(event.report.json()) }   // {"model" : "Acurite-Tower", ...}

let meteor = LRPTDemodulator(sampleRate: 288_000, offset: true)       // Meteor-M N2-3/N2-4 on 137.9 MHz
let lrpt = LRPTDecoder(mode: .oqpskNRZM)
lrpt.process(soft: meteor.process(block))
let picture = lrpt.imager.composite()?.png                            // RGB from the MSU-MR channels

let sonde = RS41Receiver(sampleRate: 240_000, offsetHz: 40_000)        // an RS41 40 kHz above the tuned frequency
for event in sonde.process(iq: block) { print(event.report?.json() ?? "") }   // {"type": "RS41", "frame": 3172, ...}
let dfm = DFMReceiver(sampleRate: 240_000, offsetHz: 40_000)           // Graw DFM-06/09/17: same shape, a report about every 4th frame
let m10 = M10Receiver(sampleRate: 480_000)                             // M10, M10+ and M20 (tries 9600 and 9616 symbols/s)
let imet = IMetReceiver(sampleRate: 240_000, offsetHz: 40_000)        // InterMet iMet-1/iMet-4 (1200 baud AFSK on FM), a report every second

let preset = MeshtasticPreset.longFast                                 // US: 906.875 MHz, 1 MS/s, channel at +250 kHz
let lora = LoRaReceiver(parameters: preset.parameters, sampleRate: 1_000_000, offsetHz: 250_000, centerFrequencyHz: 906.875e6)
let mesh = MeshtasticDecoder(channels: [.primary(preset)])
for frame in lora.process(iq: block) { print(mesh.decode(frame.payload)?.line ?? "") }   // !a1b2c3d4 → ^all ... TEXT "hi"
// Several presets or slots from one capture: MeshtasticMultiReceiver (and MeshtasticPlan, which fits the channels around the DC spike)
```

### Command-line tool

```
swift run rtlsdr-tool list
swift run rtlsdr-tool capture --freq 100e6 --gain 29.7 --seconds 2 --out iq.u8
swift run rtlsdr-tool lockscan --from 24e6 --to 1766e6 --step 5e6     # does the oscillator lock across the range?
swift run rtlsdr-tool stream --rate 3200000 --seconds 20              # does the sample stream keep up?
swift run rtlsdr-tool retunebench                                     # retune time with and without the shortcuts
swift run rtlsdr-tool monitor --freq 100e6 --guard --gain 37.2        # level and clipping, with the overload guard
swift run rtlsdr-tool scan --from 400e6 --to 406e6 --csv spectrum.csv # sweep and list signals
swift run rtlsdr-tool eeprom --out backup.bin                         # show (and back up) the EEPROM
swift run rtlsdr-tool set-serial ROOF-01 --device 1                   # dry run; add --write to program it
swift run rtlsdr-tool serve --address 0.0.0.0                         # rtl_tcp server on port 1234
swift run -c release rtlsdr-tool adsb --lat 37.4 --lon -122.1         # aircraft on 1090 MHz
swift run -c release rtlsdr-tool uat --nexrad radar/                  # 978 MHz: aircraft, weather text, radar PNGs
swift run -c release rtlsdr-tool ism --json                           # 433.92 MHz sensors, rtl_433's JSON
swift run -c release rtlsdr-tool meteor --web 8080 --out pass/        # Meteor-M images, live at localhost:8080
swift run -c release rtlsdr-tool sonde --scan --json                  # radiosondes on 400-406 MHz (RS41, DFM, M10/M20, iMet)
swift run -c release rtlsdr-tool sonde --type m10 --freq 404.4e6      # one type on a known frequency (rs41, dfm, m10, imet)
swift run -c release rtlsdr-tool ais                                  # ships' AIS on both channels (--nmea for !AIVDM sentences, --json)
swift run -c release rtlsdr-tool pager --freq 152.84e6                # POCSAG pages at 512, 1200 and 2400 bit/s (address, function, numeric or text)
swift run -c release rtlsdr-tool mesh --region EU_868                 # Meshtastic LongFast on 869.525 MHz
swift run -c release rtlsdr-tool mesh --region EU_868 --presets LongFast,MediumFast,ShortFast   # three presets at once
swift run -c release rtlsdr-tool acars --region us                    # ACARS on the five US channels at once
swift run -c release rtlsdr-tool vdl2 --region eu                     # VDL Mode 2 on four European channels
swift run rtlsdr-tool calibrate --atsc 27 --write --label roof        # measure the crystal on a TV pilot, keep it
swift run -c release rtlsdr-tool adsb --ppm eeprom                    # any tuning command: apply the stored ppm
swift run -c release rtlsdr-tool hline --seconds 1800 --lat 52 --lon 4.6 --az 180 --el 60   # 21 cm line, CSV out
```

Use a release build for the decoders: a debug build decodes ADS-B at about half real speed (it then drops blocks and
says so), a release build at about eight times real speed.

Every command takes `--device <index>` (as `list` numbers them) or `--serial <serial>`.

## How it is tested

`swift test` needs no hardware, and runs on Linux as well as macOS (there the package builds without a USB backend,
so everything but `IOUSBHostTransport` is compiled and tested).

* **Golden traces.** `Tests/RTLSDRKitTests/Resources/golden/` holds every USB control transfer an unmodified
  `rtl_sdr` made on a real dongle for seven sessions (30 MHz to 1.7 GHz, 250 kS/s to 3.2 MS/s, automatic and manual
  gain, a non-zero ppm correction). The tests run the same sessions on a fake dongle and require **every register**
  (all 30 tuner registers, all demodulator registers, USB and system registers) to end up exactly where the real
  `rtl_sdr` left it, both when streaming starts and after close. This is a check of *outcome*, not of transfer
  order: this driver skips writes that change nothing and does not copy librtlsdr's start-up quirks.
* Pure computations (resampler ratio, IF word, ppm word, FIR packing, gain/bandwidth/PLL plans) are checked against values
  read out of those traces. Device behaviour (range checks, streaming rules, close, error paths) is tested on the fake.
* The retune shortcuts are run through the same seven sessions and must leave the same registers. Every test sequence
  is also checked for tuner access while the I2C repeater was off (such a write would silently go nowhere).
* The gain loop is tested as pure logic, including a closed-loop simulation; the scanner against a synthetic receiver
  (carriers, noise, DC offset, 8-bit quantisation); EEPROM writing against an emulated EEPROM; the server over a real
  loopback socket.
* The decoders are checked against published messages, an independent decoder (pyModeS), dump978's real sample frames
  and its own decoder, and dump1090/dump978 on the same synthetic signals: see [docs/DECODERS.md](docs/DECODERS.md).
  For the radiosondes (RS41, DFM, M10/M20, iMet) there is no real recording: `Tools/*-oracle.py` build signals from the
  format alone and the `*-oracle-compare.py` scripts run our decoder and rs1729's (dfm09mod, m10m20mod, rs41mod, imet1rs_dft) on
  the same I/Q, checking each against what was sent.
* `Tools/generate-tables.py <librtlsdr source dir> --check` verifies the two generated tables against the reference.

To trace a real session: `RTLSDR_TRACE=/path/to/file` (or `-` for stderr) makes the driver log every control transfer.
`Tools/trace-librtlsdr.c` does the same for an unmodified `rtl_sdr` (`DYLD_INSERT_LIBRARIES`), and
`Tools/replay-trace.py` compares the register state two sessions leave behind.

## What is and isn't verified

Verified on real hardware (one dongle): opens and identifies the tuner; tunes; the oscillator locks at all 349 tested
5 MHz steps from 24 to 1765 MHz; sample streams at 250 kS/s, 2.4 MS/s and 3.2 MS/s ran 20 s each at 99.8-100.7 % of
the nominal rate with no error and no block gap over 15 ms; tuner gain steps track `rtl_sdr` step for step.

**Not** verified: the frequency actually produced (lock is not proof of accuracy; other projects report a PLL that
claims lock at a slightly wrong frequency near the bottom of the range), sensitivity or noise figure with an
antenna, the bias tee on a dongle that has one, any other dongle model or tuner revision, Intel Macs, macOS versions
other than 27, hot-plug, and using several dongles at once. Retuning takes about 27 ms, which limits scan speed.

Run on the dongle on 2026-10-07 (see [HARDWARE.md](HARDWARE.md)): retune timing and the shortcuts, the EEPROM read, the `rtl_tcp`
server and streaming from the ACARS and VDL Mode 2 receivers without dropped blocks. **Still not verified with a real
signal:** every decoder (ADS-B, UAT, ISM, Meteor-M, RS41, DFM, M10/M20, iMet, Meshtastic, ACARS, VDL Mode 2), calibration and the
hydrogen-line spectrometer; the overload guard's back-off on a strong signal was not exercised.

## Requirements

macOS 13 or later declared (built and run only on macOS 27 / Xcode 27, Swift 6). Apple silicon tested: the package builds and
its 380 tests pass on macOS 27 (Swift 6.4). Talking to a dongle needs macOS (`IOUSBHost`). On Linux the package builds and its tests
pass (Swift 6.3.3), but it finds no dongles.

## License

GPL-2.0-or-later. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
