# SwiftRTLSDR

A native Swift driver for RTL-SDR dongles on macOS: the Realtek **RTL2832U** USB bridge and the Rafael Micro
**R820T** tuner, talking to the hardware through Apple's `IOUSBHost` framework. No `libusb`, no `librtlsdr`, no C.

It exists because a sandboxed macOS app cannot `dlopen` a Homebrew `librtlsdr`, and because a Swift package is
easier to ship than a C library plus its dependencies. It is small (about 1,500 lines of library code) and it is
young. **Read "What is and isn't verified" before you rely on it.**

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

`readSamples(byteCount:)` is a blocking convenience for short captures. Configuration calls must come from one
thread at a time; the streaming handler runs on its own queue. Only one program can hold a dongle at a time.

A sandboxed app needs the `com.apple.security.device.usb` entitlement.

### Command-line tool

```
swift run rtlsdr-tool list
swift run rtlsdr-tool capture --freq 100e6 --gain 29.7 --seconds 2 --out iq.u8
swift run rtlsdr-tool lockscan --from 24e6 --to 1766e6 --step 5e6     # does the oscillator lock across the range?
swift run rtlsdr-tool stream --rate 3200000 --seconds 20              # does the sample stream keep up?
```

## How it is tested

`swift test` needs no hardware.

* **Golden traces.** `Tests/RTLSDRKitTests/Resources/golden/` holds every USB control transfer an unmodified
  `rtl_sdr` made on a real dongle for seven sessions (30 MHz to 1.7 GHz, 250 kS/s to 3.2 MS/s, automatic and manual
  gain, a non-zero ppm correction). The tests run the same sessions on a fake dongle and require **every register**
  (all 30 tuner registers, all demodulator registers, USB and system registers) to end up exactly where the real
  `rtl_sdr` left it, both when streaming starts and after close. This is a check of *outcome*, not of transfer
  order: this driver skips writes that change nothing and does not copy librtlsdr's start-up quirks.
* Pure computations (resampler ratio, IF word, ppm word, FIR packing, gain/bandwidth/PLL plans) are checked against values
  read out of those traces. Device behaviour (range checks, streaming rules, close, error paths) is tested on the fake.
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

## Requirements

macOS 13 or later declared (built and run only on macOS 27 / Xcode 27, Swift 6). Apple silicon tested. macOS only as far as
this project is concerned: it uses `IOUSBHost` and has not been tried on any other platform.

## License

GPL-2.0-or-later. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
