# What you can build on an RTL2832U + R820T

Research notes (2026-09-29) on software and firmware-level projects this hardware makes possible, what already
exists, and what a native Swift driver could add. Sources are linked; things I could not source are labelled. Nothing
here is a promise: the feasibility tags say how far each idea is from working.

**Tags:** `[exists]` someone ships it. `[buildable]` fits the hardware as-is and only needs software. `[needs mod]`
needs a hardware change or a different dongle. `[unknown]` I found no public information.

## The hardware's limits (they decide what is realistic)

* One receive channel, **8-bit** I/Q samples, about 2.4 MS/s comfortably and 3.2 MS/s at most (this driver held 3.2 MS/s
  for 20 s on the tested dongle, see [HARDWARE.md](../HARDWARE.md)). With the input open at moderate gain only eight ADC codes are in use, so
  dynamic range is small and strong signals can swamp weak ones.
* Tuner range is roughly 24 MHz to 1.766 GHz. **No transmit.** No sample timestamps.
* The clock is a plain crystal (about tens of ppm off) unless the dongle has a TCXO.

## 1. "Firmware": what is actually programmable

* **The EEPROM** (external, 256 bytes) holds the USB IDs, the manufacturer/product/serial strings, and two flags
  (IR endpoint, remote wakeup). `rtl_eeprom` edits these ([man page](https://man.archlinux.org/man/rtl_eeprom.1.en)).
  A read-only dump of the tested dongle shows the header and strings ending at offset 0x4d, zero fill after that, and
  **bytes 0x80-0xff never written (all 0xff, 128 bytes)**. Serial `00000001` is the default that generic dongles share.
  * `[buildable]` **Provision unique serials.** Two dongles both reporting `00000001` cannot be told apart by
    `openFirst(serial:)`; writing a unique serial to each is the prerequisite for any multi-dongle setup.
  * `[buildable, untested]` **Store per-dongle calibration on the dongle** (measured ppm, a TCXO offset, a label
    like "roof antenna") in the never-written area, so the calibration travels with the hardware. Risk: a bad write to
    the header bytes can change the USB IDs and make the dongle unrecognisable, so only the free area may be written,
    read-back-verified, and it should be tried on a sacrificial dongle first. I have not tried it.
  * **Warning:** the RTL-SDR Blog driver forces the bias tee on when the IR-endpoint flag is set
    ([its source](https://github.com/rtlsdrblog/rtl-sdr-blog/blob/master/src/librtlsdr.c), "Hack to force the Bias T"). The
    tested generic dongle has that flag set, so copying the hack would drive GPIO 0 on dongles that have no bias tee.
    This driver does not do it.
* **The chip's internal firmware** is not something I found any public way to modify. `[unknown]`; treat it as closed.
  Everything "firmware-like" people do on RTL-SDR is EEPROM contents, GPIO wiring and host software.

## 2. GPIO: a handful of pins you can drive

The RTL2832U exposes GPIO pins through the system registers (this driver implements GPIO 0 as `setBiasTee`).

* `[exists]` **Bias tee** on the RTL-SDR Blog V3 uses GPIO 0 to power an antenna amplifier through the coax
  ([Blog driver source](https://github.com/rtlsdrblog/rtl-sdr-blog/blob/master/src/librtlsdr.c), `rtlsdr_set_bias_tee_gpio`). Only exercised against the fake dongle here.
* `[exists]` **Switching and calibration hardware.** KrakenSDR is five RTL-SDRs on one clock with "internal calibration
  hardware" and a noise source that lets software measure and correct the phase between channels
  ([RTL-SDR.com](https://www.rtl-sdr.com/unleash-the-krakensdr-5-channel-coherent-capable-rtl-sdr-coming-soon-direction-finding-passive-radar/)).
  `[buildable, needs mod]` The same trick in miniature: any GPIO-switched filter, LNA, antenna selector or noise source is
  a few lines of driver code once someone has soldered it.

## 3. The clock

* `[exists]` **ppm calibration** against GSM base stations with `kalibrate-rtl`
  ([tutorial](https://www.rtl-sdr.com/how-to-calibrate-rtl-sdr-using-kalibrate-rtl-on-linux/)); the offset is linear across the
  band, so one ppm number corrects everywhere. This driver's `setFrequencyCorrection(ppm:)` corrects both the resampler and the
  tuner's PLL, matching `rtl_sdr`'s register output.
* `[buildable]` **Automatic calibration from carriers you already receive** (a strong known broadcast or pilot tone instead of GSM,
  which is being phased out in some countries): estimate the offset, apply it, remember it (see the EEPROM idea above).
* `[exists, needs mod]` **Shared clock across several dongles** is what makes coherent arrays (KrakenSDR, KerberosSDR) possible.
  Several ordinary dongles on separate crystals are not coherent.

## 4. Driver-level ideas that would make a scanner good

These are specific to what the measurements in this repo showed.

* `[buildable]` **Fast retune.** A retune costs about 27 ms because it is many single USB control transfers. Batching the I2C
  writes, skipping the mux and filter registers when the band did not change, and rewriting only the PLL fraction for small
  steps could plausibly cut that several-fold. This decides how fast a channel scanner can hop. Unmeasured estimate.
* `[buildable]` **Overload guard / software AGC.** With 8-bit samples, counting samples at the rails per block tells you when the
  front end is clipping. The tuner's own AGC is left off, so the gain loop is the host's job.
* `[buildable]` **Move the signal off the DC spike.** The RTL2832U's IF word is programmable, so the wanted signal can be placed
  away from DC instead of tuning around the spike ("offset tuning" or IF shifting is a feature of the community
  [`librtlsdr` fork](https://github.com/librtlsdr/librtlsdr/blob/master/README_improvements.md)).
* `[needs mod]` **HF via direct sampling.** The demodulator can sample the ADC input directly (below about 14 MHz, folded around
  14.4 MHz), but only on dongles wired for it. The RTL-SDR Blog V3 had a direct-sampling circuit; the V4 replaced it with an upconverter
  and a triplexer ([review summary](https://www.eenewseurope.com/en/new-software-defined-radio-adventures-with-the-rtl-sdr-v4/)).
  Not implemented here.
* `[buildable]` **Support more tuners.** The V4's R828D has three triplexed inputs and open-drain pins used for notch filters
  ([datasheet](https://www.rtl-sdr.com/wp-content/uploads/2024/12/RTLSDR_V4_Datasheet_V_1_0.pdf)); it needs its own handling and
  this driver refuses it today rather than guess.
* `[buildable]` **Serve the dongle over the network** (the `rtl_tcp` protocol, SoapyRemote, or SpyServer) so an app on a Mac can use a
  dongle plugged into a Raspberry Pi at the antenna.

## 5. What people already do with it (prior art to test against)

| Use | What exists | Note |
|---|---|---|
| ISM sensors, TPMS, doorbells (315/345/433/868/915 MHz) | [`rtl_433`](https://github.com/merbanan/rtl_433): a generic receiver, GPLv2, [234 device protocols listed at the time of the source](https://lwn.net/Articles/921497/) | `[exists]` Receive chain and 11 of its protocols ported into `RTLSDRDecoders`, output byte-identical on its test recordings (see [DECODERS.md](DECODERS.md)) |
| ADS-B aircraft (1090 MHz) | `dump1090`, which uses 2.4 MS/s ([RTL-SDR.com](https://www.rtl-sdr.com/tag/dump1090/)) | `[exists]` A native decoder is in `RTLSDRDecoders` (see [DECODERS.md](DECODERS.md)) |
| UAT aircraft and FIS-B weather (978 MHz, US only) | `dump978` ([original](https://github.com/mutability/dump978), GPL-2.0-or-later; [FlightAware's](https://github.com/flightaware/dump978), BSD-2-Clause): ADS-B from general aviation, and from ground stations NEXRAD radar mosaics, METAR/TAF text, NOTAMs | `[exists]` Ported into `RTLSDRDecoders` with radar-to-PNG rendering (see [DECODERS.md](DECODERS.md)) |
| ACARS / VDL2 aircraft data links | `acarsdec`, `dumpvdl2` (main VDL2 channel 136.975 MHz) ([RTL-SDR.com](https://www.rtl-sdr.com/feeding-the-dump1090-aircraft-database-with-vdlm2dec/)) | `[exists]` |
| Weather satellites | SatDump: Meteor-M LRPT (~137.9 MHz), NOAA HRPT, GOES etc.; automation of passes ([RTL-SDR.com](https://www.rtl-sdr.com/automating-noaa-apt-and-meteor-m2-lrpt-reception-with-satdump-1-1-2/)). The source says APT was not supported in SatDump at that version | `[exists]` Meteor-M LRPT (72k, QPSK and offset QPSK) ported into `RTLSDRDecoders` from meteor_demod/meteor_decode, checked against them and SatDump, with a live dashboard (see [DECODERS.md](DECODERS.md)). GOES/HRPT need more bandwidth and a dish than a whip antenna |
| Radiosondes (weather balloons) | `radiosonde_auto_rx`: scans for peaks, decodes, uploads to SondeHub ([RTL-SDR.com](https://www.rtl-sdr.com/tracking-radiosondes-with-an-rtl-sdr-and-radiosonde_auto_rx/)) | `[exists]` A scan-then-decode loop is exactly a scanner's job. The Vaisala RS41 is decoded in `RTLSDRDecoders` (checked field for field against rs1729's rs41mod), with `rtlsdr-tool sonde --scan` on the scan loop (see [DECODERS.md](DECODERS.md)) |
| LoRa / Meshtastic | RTL-SDR can decode most Meshtastic presets at once; a US-wide capture of all presets needs 20 MHz ([RTL-SDR.com](https://www.rtl-sdr.com/decoding-meshtastic-in-realtime-with-an-rtl-sdr-and-gnu-radio/), [related](https://github.com/alphafox02/meshtastic-sniffer)) | `[exists]` Receive only. Decoded in `RTLSDRDecoders` (LoRa PHY checked against gr-lora_sdr, Meshtastic packets with the default and given channel keys), one preset and slot at a time: `rtlsdr-tool mesh` (see [DECODERS.md](DECODERS.md)) |
| Radio astronomy (21 cm hydrogen line, 1420.4058 MHz) | A WiFi dish + LNA + RTL-SDR drift scan shows the line and its Doppler shift ([RTL-SDR.com](https://www.rtl-sdr.com/cheap-and-easy-hydrogen-line-radio-astronomy-with-a-rtl-sdr-wifi-parabolic-grid-dish-lna-and-sdrsharp/)) | `[exists]` Needs an LNA and a dish; the bare dongle is not enough |
| Direction finding, passive radar | KrakenSDR/KerberosSDR (coherent, shared clock); passive radar uses FM/DAB/DVB-T broadcasts as illuminators ([RTL-SDR.com](https://www.rtl-sdr.com/measuring-traffic-in-a-neighborhood-with-kerberossdr-and-passive-radar/)) | `[needs mod]` Impossible with one ordinary dongle |

Also commonly done but **not researched here**: pagers (POCSAG/FLEX), AIS ships, DAB+, GNSS.

## 6. Where to start

In order of value for effort: (1) the fast-retune and overload-guard work in section 4, because they make a scanner real;
(2) a scan-then-decode loop in the style of `radiosonde_auto_rx`; (3) decoders written from public protocol specifications,
using `rtl_433`, `dump1090`, `acarsdec`, `dumpvdl2` and SatDump as **test oracles and comparison points** (their licenses
differ; check before copying anything); (4) unique-serial provisioning once there is more than one dongle; (5) a network
server for a dongle at the antenna. Coherent arrays, direct sampling and the V4 depend on hardware this driver has not been
tested with and should wait for someone who owns it.

### Status (2026-09-30)

What exists now for each item above. Everything listed is tested without hardware only; [HARDWARE.md](../HARDWARE.md)
lists the check to run for each.

1. **Fast retune:** opt-in `RTLSDRDevice.RetuneShortcuts` cut a same-band retune from 11 control transfers to 5 (keep
   the tuner's I2C bus open; reuse the VCO status from the last lock check). The mux and filter registers were already
   skipped when the band did not change. The time saved is unmeasured (`rtlsdr-tool retunebench`). Not done:
   pipelining control transfers asynchronously in the USB layer, which could save more but needs a macOS build to
   write against. **Overload guard / software AGC:** `SampleStatistics`, `GainLoop` and `HostGainControl`
   (`rtlsdr-tool monitor --guard`, `--agc`). The thresholds are unmeasured starting points.
2. **Scan-then-decode loop:** the `RTLSDRScan` library (`BandScanner`, `ScanLoop`, `rtlsdr-tool scan`). At 2.4 MS/s each
   hop covers about 1.8 MHz (hops overlap by half), so channels are found by FFT instead of by retuning channel by
   channel.
3. **Decoders:** started, in the `RTLSDRDecoders` library. ADS-B / Mode S (1090 MHz), written from the public description;
   UAT (978 MHz) with FIS-B weather radar and text, ported from dump978; ISM sensors (433/868/915 MHz), rtl_433's
   receive chain and 11 of its protocols (AcuRite, Oregon Scientific, LaCrosse, Fine Offset/Ecowitt, Bresser, Nexus,
   Rubicson, Ambient Weather, EV1527 remotes); Meteor-M LRPT weather-satellite images (137 MHz), ported from
   meteor_demod and meteor_decode with a faster carrier acquisition, and a browser dashboard (`rtlsdr-tool meteor
   --web`); Vaisala RS41 radiosondes (400-406 MHz), with a scan mode on the scan loop (`rtlsdr-tool sonde --scan`);
   Meshtastic over LoRa (`rtlsdr-tool mesh`), with a LoRa receiver of its own (`rtlsdr-tool lora`). All
   are checked against oracles ([DECODERS.md](DECODERS.md)); none has received a live signal. Not started:
   ACARS/VDL2, other radiosonde types (DFM, M10/M20, RS92, iMet), several Meshtastic presets at once, Meteor's 80k interleaved mode, NOAA APT (the NOAA satellites have
   been retired). The fixed-frequency decoders do not need the scan loop; `SignalDecoder` is still the slot for decoders
   that do.
4. **Unique-serial provisioning:** `RTLSDRDevice.setSerialNumber` and `rtlsdr-tool set-serial` (dry run by default, backup
   first, never writes the header, verified by read-back). Calibration storage in the free area 0x80-0xff is possible
   with `writeEEPROM`, but no record format has been defined yet.
5. **Network server:** the `RTLSDRServer` library (`rtl_tcp` protocol, `rtlsdr-tool serve`).
