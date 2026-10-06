#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Makes an M10, M10+ or M20 radiosonde signal from a simulated flight, independently of this package's code.

usage: m10-oracle.py OUT [--model m10|m10plus|m20] [--seconds 20] [--rate 288000] [--esn0 14] [--offset 3000]
                     [--drift 0] [--deviation 4320] [--bt 1.5] [--baud 9600] [--invert] [--seed 1]

Builds one frame a second from the format alone (position, velocity, time, serial number, battery, thermistor and a
checksum), sends it as a 32-symbol header and then its bits most significant first: differentially coded (a data bit
1 where two bits in a row are alike), Manchester coded (a bit 1 as low then high), at 9600 symbols a second unless
--baud says otherwise, Gaussian-filtered and frequency-modulated (+-4.3 kHz) around an unmodulated carrier that the
sonde keeps up between frames, with a carrier offset (drifting by --drift Hz), a random phase and complex Gaussian
noise for the symbol energy over noise density asked for. Writes OUT.u8 (for `rtlsdr-tool sonde --type m10 --ifile`),
OUT.wav (16-bit stereo I/Q, for m10m20mod --IQ), OUT-fm.wav (96 kHz FM audio) and OUT.truth.json (what was sent, one
object per frame). Needs numpy.
"""
import argparse
import json
import math
import struct
import wave
import numpy as np

HEADER = "10011001100110010100110010011001"

# Shibaura PB5-41E NTC: temperature in C and resistance in kOhm (datasheet values).
NTC = [(-50, 204.0), (-45, 150.7), (-40, 112.6), (-35, 84.90), (-30, 64.65), (-25, 49.66), (-20, 38.48), (-15, 30.06),
       (-10, 23.67), (-5, 18.78), (0, 15.00), (5, 12.06), (10, 9.765), (15, 7.955), (20, 6.515), (25, 5.370), (30, 4.448),
       (35, 3.704), (40, 3.100)]
SERIES = [12.1e3, 36.5e3, 475.0e3]
PARALLEL = [None, 330.0e3, 2000.0e3]


def ntc_ohms(celsius):
    temps = [t for t, _ in NTC]
    logs = [math.log(r * 1e3) for _, r in NTC]
    return math.exp(float(np.interp(celsius, temps, logs)))


def adc_for(ohms):
    """Range (0..2) and 12-bit reading of the divider for a thermistor resistance."""
    best = None
    for scale in range(3):
        x = SERIES[scale] / ohms + (SERIES[scale] / PARALLEL[scale] if PARALLEL[scale] else 0.0)
        reading = 4095.0 / (1.0 + x)
        if 600 < reading < 3500:
            best = (scale, int(round(reading)))
            break
    return best or (2, 3000)


def update_checksum(c, byte):
    """One byte into the 16-bit checksum (a linear map, so it is written here as the matrix over GF(2) it is)."""
    b = ((byte >> 1) | ((byte & 1) << 7)) & 0xFF
    b ^= (b >> 2) & 0xFF
    t6 = (c & 1) ^ ((c >> 2) & 1) ^ ((c >> 4) & 1)
    t7 = ((c >> 1) & 1) ^ ((c >> 3) & 1) ^ ((c >> 5) & 1)
    t = (c & 0x3F) | (t6 << 6) | (t7 << 7)
    s = (c >> 7) & 0xFF
    s ^= (s >> 2) & 0xFF
    return (((c & 0xFF) << 8) | (b ^ t ^ s)) & 0xFFFF


def with_checksum(body):
    """body = every byte but the last two; returns the frame with them appended."""
    c = 0
    for byte in body:
        c = update_checksum(c, byte)
    return bytes(body) + bytes([c >> 8, c & 0xFF])


def put(frame, offset, value, count, little=False):
    value &= (1 << (8 * count)) - 1
    raw = value.to_bytes(count, "little" if little else "big")
    frame[offset:offset + count] = raw


def make_frame(model, second, rng, serial_raw):
    """One frame of the flight at `second` s; returns (bytes, truth)."""
    gps_start = 2371 * 604800 + 37218                  # GPS seconds of 2025-06-15 10:20:18 GPS = 10:20:00 UTC
    gps = gps_start + second
    week, tow = divmod(gps, 604800)
    lat = 47.5 + 0.00011 * second
    lon = -8.25 + 0.00021 * second               # western longitude: the sign handling matters
    alt = 1204.37 + 5.1 * second
    east, north, up = 6.5, -2.25, 5.1
    celsius = 12.0 - 0.0065 * (alt - 1204.37)
    scale, reading = adc_for(ntc_ohms(celsius))
    volts = 3.0 - 0.001 * second
    counter = (second + 40) & 0xFF
    truth = {"gps_seconds": gps, "lat": round(lat, 5), "lon": round(lon, 5), "alt": round(alt, 5),
             "vel_h": round(math.hypot(east, north), 5), "vel_v": up, "temp": round(celsius, 2), "counter": counter,
             "heading": round(math.degrees(math.atan2(east, north)) % 360, 5), "model": model}
    if model == "m20":
        frame = bytearray(0x46)
        frame[0], frame[1] = 0x45, 0x20
        put(frame, 0x02, 2000, 2, True)
        put(frame, 0x04, reading + 4096 * scale, 2, True)
        put(frame, 0x06, 2400, 2, True)
        put(frame, 0x08, int(round(alt * 100)), 3)
        put(frame, 0x0B, int(round(east * 100)), 2)
        put(frame, 0x0D, int(round(north * 100)), 2)
        put(frame, 0x0F, tow, 3)
        frame[0x12:0x15] = serial_raw[:3]
        frame[0x15] = counter
        put(frame, 0x18, int(round(up * 100)), 2)
        put(frame, 0x1A, week, 2)
        put(frame, 0x1C, int(round(lat * 1e6)), 4)
        put(frame, 0x20, int(round(lon * 1e6)), 4)
        frame[0x26] = int(round(volts / (3.3 / 255)))
        frame[0x43] = 0x07
        truth["batt"] = round(frame[0x26] * 3.3 / 255, 2)
        truth["datetime_gps"] = tow
        return with_checksum(frame[:0x44]), truth
    frame = bytearray(0x65)
    if model == "m10":
        frame[0], frame[1], frame[2] = 0x64, 0x9F, 0x20
        put(frame, 0x04, int(round(east * 200)), 2)
        put(frame, 0x06, int(round(north * 200)), 2)
        put(frame, 0x08, int(round(up * 200)), 2)
        put(frame, 0x0A, tow * 1000 + 250, 4)
        put(frame, 0x0E, int(round(lat * (2 ** 32) / 360)), 4)
        put(frame, 0x12, int(round(lon * (2 ** 32) / 360)), 4)
        put(frame, 0x16, int(round(alt * 1000)), 4)
        frame[0x1E] = 9
        frame[0x1F] = 18
        put(frame, 0x20, week, 2)
        truth["utc_seconds"] = tow - 18
    else:                                                  # m10plus: Gtop receiver, UTC date and time as decimal numbers
        frame[0], frame[1] = 0x64, 0xAF
        put(frame, 0x04, int(round(lat * 1e6)), 4)
        put(frame, 0x08, int(round(lon * 1e6)), 4)
        put(frame, 0x0C, int(round(alt * 100)), 3)
        put(frame, 0x0F, int(round(east * 100)), 2)
        put(frame, 0x11, int(round(north * 100)), 2)
        put(frame, 0x13, int(round(up * 100)), 2)
        utc = tow - 18
        h, m, s = (utc % 86400) // 3600, utc % 3600 // 60, utc % 60
        put(frame, 0x15, h * 10000 + m * 100 + s, 3)
        put(frame, 0x18, 15 * 10000 + 6 * 100 + 25, 3)
    frame[0x3E] = scale
    put(frame, 0x3F, reading + 0xA000, 2, True)
    adc = int(round(volts * 1023 / (2.709 * 2.5)))
    put(frame, 0x45, adc, 2, True)
    truth["batt"] = round(2.709 * adc * 2.5 / 1023, 2)
    frame[0x5D:0x62] = serial_raw
    frame[0x62] = counter
    return with_checksum(frame[:0x63]), truth


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    parser.add_argument("--model", default="m10", choices=["m10", "m10plus", "m20"])
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--rate", type=float, default=288000)
    parser.add_argument("--esn0", type=float, default=14)
    parser.add_argument("--offset", type=float, default=3000)
    parser.add_argument("--drift", type=float, default=0)
    parser.add_argument("--deviation", type=float, default=4320)
    parser.add_argument("--bt", type=float, default=1.5)
    parser.add_argument("--baud", type=float, default=9600)
    parser.add_argument("--invert", action="store_true")
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    rng = np.random.default_rng(args.seed)
    serial_raw = bytes([0x23, 0x00, 0xB7, 0x39, 0x5A]) if args.model != "m20" else bytes([0x5A, 0x11, 0x84])

    frames, truth = [], []
    for second in range(args.seconds):
        frame, record = make_frame(args.model, second, rng, serial_raw)
        frames.append(frame)
        truth.append(record)

    # Symbols a second apart: header, then the frame's bits (differential, then Manchester), then the idle carrier.
    one_second = args.baud
    symbols = []
    lead = rng.integers(0, 2, int(0.31 * args.baud))
    symbols.extend([0.0] * len(lead))
    for index, frame in enumerate(frames):
        frame_symbols = [1.0 if c == "1" else -1.0 for c in HEADER]
        previous = 0
        for byte in frame:
            for k in range(8):
                d = (byte >> (7 - k)) & 1
                bit = previous ^ d ^ 1
                frame_symbols += [-1.0, 1.0] if bit else [1.0, -1.0]
                previous = bit
        padding = int(round(one_second)) - len(frame_symbols)
        symbols.extend(frame_symbols + [0.0] * padding)
    symbols = np.array(symbols, dtype=np.float64)
    if args.invert:
        symbols = -symbols

    sps = args.rate / args.baud
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
    n0 = 1.0 / args.baud / 10 ** (args.esn0 / 10)                     # Es = P/baud with P = 1
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

    # FM audio at 96 kHz: the carrier moved to zero, low-passed, discriminated, decimated.
    decimation = int(round(args.rate / 96000))
    centred = received * np.exp(-2j * np.pi * args.offset * t)
    taps = np.sinc(2 * 9000 / args.rate * (np.arange(-60, 61))) * np.hamming(121)
    taps /= taps.sum()
    filtered = np.convolve(centred, taps, mode="same")
    step = np.angle(filtered[1:] * np.conj(filtered[:-1]))
    audio = np.concatenate([[0.0], step]) * args.rate / (2 * np.pi)
    audio = audio[: len(audio) // decimation * decimation].reshape(-1, decimation).mean(axis=1)
    fm = np.clip(audio / 12000 * 32767, -32767, 32767).astype(np.int16)
    with wave.open(args.output + "-fm.wav", "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(int(args.rate / decimation))
        out.writeframes(fm.tobytes())

    with open(args.output + ".truth.json", "w") as handle:
        json.dump(truth, handle)
    with open(args.output + ".frames.txt", "w") as handle:
        for frame in frames:
            handle.write(frame.hex() + "\n")
    print(f"{args.output}: {len(frames)} frames of {args.model} at {args.baud:.0f} symbols/s, {count / args.rate:.1f} s at "
          f"{args.rate:.0f} S/s, Es/N0 {args.esn0} dB, carrier {args.offset:+.0f} Hz{', inverted' if args.invert else ''}")


if __name__ == "__main__":
    main()
