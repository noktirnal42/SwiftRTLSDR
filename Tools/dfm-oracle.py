#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Makes a DFM-06/09/17 radiosonde signal from a simulated flight, independently of this package's code.

usage: dfm-oracle.py OUT [--model dfm09] [--seconds 40] [--serial 21071356] [--rate 240000] [--esn0 14]
                     [--offset 3000] [--drift 0] [--deviation 2400] [--bt 0.7] [--invert] [--seed 1]

Builds the frames from the format alone: nine data packets a second (time, position, speed, satellites) sent two to
a frame, the configuration channels (six to nine measurement channels as 24-bit floats and the serial number) round
robin one to a frame, Hamming(8,4) codewords, block interleaving, the 0x45CF header, Manchester symbols at 2500 a
second, Gaussian-filtered frequency modulation with a carrier offset (drifting by --drift Hz) and complex Gaussian
noise for the symbol energy over noise density asked for. The thermistor channels come from a temperature that falls
with height through the NTC's datasheet table. Writes OUT.u8 (for `rtlsdr-tool sonde --type dfm --ifile`), OUT.wav
(16-bit stereo I/Q, for dfm09mod --IQ), OUT-fm.wav (48 kHz FM audio, for `--wav` and dfm09mod) and OUT.truth.json (what
was sent, one object per second). Needs numpy.
"""
import argparse
import json
import math
import wave
import numpy as np

SYMBOL_RATE = 2500
HEADER = 0x45CF

# EPCOS B57540G0502 R/T characteristic 8402 (5 kOhm at 25 C), temperature in C and R/R25: public datasheet values.
NTC = [(-55, 51.991), (-50, 37.989), (-45, 28.07), (-40, 20.96), (-35, 15.809), (-30, 12.037), (-25, 9.2484),
       (-20, 7.1668), (-15, 5.5993), (-10, 4.4087), (-5, 3.4971), (0, 2.7936), (5, 2.2468), (10, 1.8187),
       (15, 1.4813), (20, 1.2136), (25, 1.0), (30, 0.82845), (35, 0.68991), (40, 0.57742)]

# model: (serial channel, sensor type, reference resistor Rs, Rf, pressure-sensor layout)
MODELS = {
    "dfm06": (6, "T", 10e3, 220e3, False),
    "dfm09": (0xA, "T", 20e3, 220e3, False),
    "dfm17": (0xB, "T", 20e3, 332e3, False),
    "dfm09p": (0xC, "P", 20e3, 220e3, True),
    "dfm17p": (0xD, "P", 20e3, 332e3, True),
}


def ntc_ohms(celsius):
    """Thermistor resistance at a temperature: log-linear interpolation of the datasheet table."""
    temps = [t for t, _ in NTC]
    logs = [math.log(r * 5000) for _, r in NTC]
    return math.exp(float(np.interp(celsius, temps, logs)))


def hamming(nibble):
    d0, d1, d2, d3 = (nibble >> 3) & 1, (nibble >> 2) & 1, (nibble >> 1) & 1, nibble & 1
    return [d0, d1, d2, d3, d1 ^ d2 ^ d3, d0 ^ d2 ^ d3, d0 ^ d1 ^ d3, d0 ^ d1 ^ d2]


def block_bits(value, nibbles):
    """A block of `nibbles` data nibbles, from the integer `value`, as the interleaved codeword bits."""
    words = [hamming((value >> (4 * (nibbles - 1 - i))) & 0xF) for i in range(nibbles)]
    return [words[i][j] for j in range(8) for i in range(nibbles)]       # bit j of codeword i is sent L*j+i-th


def float24(value):
    """24 bits (4-bit exponent p, 20-bit mantissa m) for a value, m / 2^p, with the most fractional bits that fit."""
    p = 0
    while p < 15 and value * (1 << (p + 1)) < (1 << 20) - 1:
        p += 1
    return (p << 20) | int(round(value * (1 << p)))


def days_since_1980(y, m, d):
    import datetime
    return (datetime.date(y, m, d) - datetime.date(1980, 1, 6)).days


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    parser.add_argument("--model", default="dfm09", choices=sorted(MODELS))
    parser.add_argument("--seconds", type=int, default=40)
    parser.add_argument("--serial", type=int, default=21071356)
    parser.add_argument("--rate", type=float, default=240000)
    parser.add_argument("--esn0", type=float, default=14)
    parser.add_argument("--offset", type=float, default=3000)
    parser.add_argument("--drift", type=float, default=0)
    parser.add_argument("--deviation", type=float, default=2400)
    parser.add_argument("--bt", type=float, default=0.7)
    parser.add_argument("--invert", action="store_true")
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    rng = np.random.default_rng(args.seed)
    sn_channel, sensor, rs, rf, pressure_layout = MODELS[args.model]
    serial = args.serial if args.model != "dfm06" else args.serial & 0xFFFFFF

    # The flight: one position a second, climbing and drifting.
    start = (2025, 6, 15, 10, 20, 0)
    base_days = days_since_1980(*start[:3])
    base_seconds = base_days * 86400 + start[3] * 3600 + start[4] * 60 + start[5]
    lat, lon, alt = 48.1234567, 11.5678901, 512.34
    east, north, up = 7.5, 3.0, 5.2
    truth = []
    seconds_data = []
    for s in range(args.seconds + 2):
        t = base_seconds + s
        day, rem = divmod(t, 86400)
        date = (np.datetime64("1980-01-06") + np.timedelta64(int(day), "D")).astype(object)
        hour, minute, second = rem // 3600, rem // 60 % 60, rem % 60
        temperature = 18.0 - alt * 0.0065
        ohms = ntc_ohms(temperature)
        gain = 3.0 if sensor == "T" else 0.5
        counts = {"f": gain * (ohms + rs), "f1": gain * rs, "f2": gain * rf}
        speed = math.hypot(east, north)
        heading = (math.degrees(math.atan2(east, north))) % 360
        record = {"gps_seconds": int(t), "year": date.year, "month": date.month, "day": date.day, "hour": int(hour),
                  "minute": int(minute), "second": float(second), "lat": round(lat, 5), "lon": round(lon, 5),
                  "alt": round(alt, 2), "vel_h": round(speed, 2), "heading": round(heading, 2), "vel_v": round(up, 2),
                  "sats": 9, "temp": round(temperature, 2), "serial": str(serial) if args.model != "dfm06" else "%06X" % serial,
                  "counter": int((t - 77) & 0xFF), "model": args.model}
        seconds_data.append((record, counts))
        truth.append(record)
        lat += north / 111_132.0
        lon += east / (111_320.0 * math.cos(math.radians(lat)))
        alt += up

    # Configuration channels: 24-bit values by channel id.
    def config_cycle(record, counts, volts=2.9, internal=303.1):
        channels = []
        f, f1, f2 = counts["f"], counts["f1"], counts["f2"]
        if pressure_layout:
            values = {0: 250000.0, 1: f, 2: 1000.0, 3: 2000.0, 4: 3000.0, 5: f1, 6: f2}
            channels = [(i, float24(values[i])) for i in range(7)]
            channels += [(7, int(volts * 1000) << 4), (8, int(internal * 100) << 4)]
        elif args.model == "dfm06":
            values = {0: f, 1: 1000.0, 2: 2000.0, 3: f1, 4: f2}
            channels = [(i, float24(values[i])) for i in range(5)]
            channels += [(5, 0xA00000)]                                       # the all-zero channel, 0x5A00000
        else:
            values = {0: f, 1: 1000.0, 2: 2000.0, 3: f1, 4: f2}
            channels = [(i, float24(values[i])) for i in range(5)]
            channels += [(5, int(volts * 1000) << 4), (6, int(internal * 100) << 4), (7, 12345 << 4), (8, float24(777.0))]
        if args.model == "dfm06":
            channels.append((6, serial))
        else:
            channels.append((sn_channel, (0xC << 20) | (((serial >> 16) & 0xFFFF) << 4) | 0))
            channels.append((sn_channel, (0xC << 20) | ((serial & 0xFFFF) << 4) | 1))
        return channels

    # Data packets of each second, as 48-bit payloads plus the id (mode 2: positions are ellipsoid heights).
    def packets(record):
        prn = 0
        for sv in (1, 3, 8, 11, 14, 17, 22, 28, 31):
            prn |= 1 << (sv - 1)
        ms = int(round(record["second"] * 1000))
        lat_i, lon_i, alt_i = int(round(record["lat"] * 1e7)), int(round(record["lon"] * 1e7)), int(round(record["alt"] * 100))
        vh, dr, vv = int(round(record["vel_h"] * 100)), int(round(record["heading"] * 100)), int(round(record["vel_v"] * 100))
        u32 = lambda v: v & 0xFFFFFFFF
        u16 = lambda v: v & 0xFFFF
        return [
            (0, (0x1234 << 32) | (2 << 24) | (record["counter"] << 16) | 0x0101),
            (1, (u32(prn) << 16) | u16(ms)),
            (2, (u32(lat_i) << 16) | u16(vh)),
            (3, (u32(lon_i) << 16) | u16(dr)),
            (4, (u32(alt_i) << 16) | u16(vv)),
            (5, (u16(4800) << 32) | 0x23456789),
            (6, 0x0123456789AB),
            (7, 0xBA9876543210),
            (8, (record["year"] << 36) | (record["month"] << 32) | (record["day"] << 27) | (record["hour"] << 22)
             | (record["minute"] << 16) | (record["sats"] << 8)),
        ]

    # Frames: two data packets and one configuration channel each, nine packets a second.
    stream_packets = []
    for record, counts in seconds_data:
        for packet in packets(record):
            stream_packets.append(packet)
    configs = []
    cycle = []
    frames = []
    for number in range(len(stream_packets) // 2):
        second_index = min(len(seconds_data) - 1, (2 * number) // 9)
        if not cycle:
            cycle = list(config_cycle(*seconds_data[second_index]))
        channel, value = cycle.pop(0)
        (id1, payload1), (id2, payload2) = stream_packets[2 * number], stream_packets[2 * number + 1]
        bits = [(HEADER >> (15 - k)) & 1 for k in range(16)]
        bits += block_bits((channel << 24) | value, 7)
        bits += block_bits((payload1 << 4) | id1, 13)
        bits += block_bits((payload2 << 4) | id2, 13)
        assert len(bits) == 280
        frames.append(bits)

    # Symbols: a 1 is sent low then high, a 0 high then low (inverted with --invert).
    symbols = []
    lead = rng.integers(0, 2, int(0.37 * SYMBOL_RATE / 2))
    for b in lead:
        symbols += [-1, 1] if b else [1, -1]
    for bits in frames:
        for b in bits:
            symbols += [-1, 1] if b else [1, -1]
    tail = rng.integers(0, 2, SYMBOL_RATE // 2)
    for b in tail:
        symbols += [-1, 1] if b else [1, -1]
    symbols = np.array(symbols, dtype=np.float64)
    if args.invert:
        symbols = -symbols

    sps = args.rate / SYMBOL_RATE
    count = int(len(symbols) * sps)
    t = np.arange(count) / args.rate
    nrz = symbols[np.minimum((np.arange(count) / sps).astype(np.int64), len(symbols) - 1)]
    sigma = np.sqrt(np.log(2)) / (2 * np.pi * args.bt) * sps
    half = int(4 * sigma)
    kernel = np.exp(-0.5 * (np.arange(-half, half + 1) / sigma) ** 2)
    kernel /= kernel.sum()
    shaped = np.convolve(nrz, kernel, mode="same")
    frequency = args.offset + args.drift * (t / t[-1] - 0.5) + args.deviation * shaped
    phase = 2 * np.pi * np.cumsum(frequency) / args.rate + rng.uniform(0, 2 * np.pi)
    signal = np.exp(1j * phase)
    n0 = 1.0 / SYMBOL_RATE / 10 ** (args.esn0 / 10)                 # Es = P/rate with P = 1
    sigma2 = n0 * args.rate
    received = signal + rng.normal(0, np.sqrt(sigma2 / 2), count) + 1j * rng.normal(0, np.sqrt(sigma2 / 2), count)
    scale = 40 / np.sqrt(np.mean(np.abs(received) ** 2))
    iq = np.empty(2 * count)
    iq[0::2], iq[1::2] = received.real * scale + 127.5, received.imag * scale + 127.5
    np.clip(np.round(iq), 0, 255).astype(np.uint8).tofile(args.output + ".u8")
    pcm = np.empty(2 * count, dtype=np.int16)
    pcm[0::2] = np.clip(received.real * scale * 200, -32767, 32767)
    pcm[1::2] = np.clip(received.imag * scale * 200, -32767, 32767)
    with wave.open(args.output + ".wav", "wb") as out:
        out.setnchannels(2)
        out.setsampwidth(2)
        out.setframerate(int(args.rate))
        out.writeframes(pcm.tobytes())

    # FM audio at 48 kHz: the carrier moved to zero, low-passed (about +-6.5 kHz), discriminated, decimated.
    decimation = int(round(args.rate / 48000))
    centred = received * np.exp(-2j * np.pi * args.offset * t)
    taps = np.sinc(2 * 6500 / args.rate * (np.arange(-60, 61))) * np.hamming(121)
    taps /= taps.sum()
    filtered = np.convolve(centred, taps, mode="same")
    step = np.angle(filtered[1:] * np.conj(filtered[:-1]))
    audio = np.concatenate([[0.0], step]) * args.rate / (2 * np.pi)            # hertz
    audio = audio[: len(audio) // decimation * decimation].reshape(-1, decimation).mean(axis=1)
    fm = np.clip(audio / 8000 * 32767, -32767, 32767).astype(np.int16)
    with wave.open(args.output + "-fm.wav", "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(int(args.rate / decimation))
        out.writeframes(fm.tobytes())

    with open(args.output + ".truth.json", "w") as handle:
        json.dump(truth, handle)
    print(f"{args.output}: {len(frames)} frames ({len(frames) * 280 / 1250:.1f} s) of {args.model} {serial}, "
          f"{count / args.rate:.1f} s at {args.rate:.0f} S/s, Es/N0 {args.esn0} dB, carrier {args.offset:+.0f} Hz"
          f"{', inverted' if args.invert else ''}")


if __name__ == "__main__":
    main()
