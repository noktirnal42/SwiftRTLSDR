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

### Network server (`RTLSDRServer`)

`RTLTCPServer` serves the dongle with the `rtl_tcp` protocol that SDR#, GQRX, SDR++ and others speak. It handles one
client at a time and drops the oldest samples if a client falls behind. Bias-tee commands are refused unless allowed.
It listens on 127.0.0.1 by default, because the protocol has no authentication.

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
```

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

Also not verified on hardware: everything added on 2026-09-30 (retune shortcuts, overload guard / host AGC, scanning,
EEPROM writing and serial provisioning, the `rtl_tcp` server). It was built and tested on Linux only; the macOS build
of those parts has not been compiled yet.

## Requirements

macOS 13 or later declared (built and run only on macOS 27 / Xcode 27, Swift 6). Apple silicon tested. Talking to a
dongle needs macOS (`IOUSBHost`). On Linux the package builds and its tests pass (Swift 6.0.3), but it finds no dongles.

## License

GPL-2.0-or-later. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
