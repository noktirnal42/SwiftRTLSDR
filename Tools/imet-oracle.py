#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Makes an iMet-1 / iMet-4 radiosonde signal from a simulated flight, independently of this package's code.

usage: imet-oracle.py OUT [--seconds 20] [--rate 240000] [--cnr 20] [--offset 3000] [--deviation 3000] [--baud 1200]
                      [--extended] [--xdata] [--seed 1]

Builds one frame a second from NOAA's "iMet-1-RSB Radiosonde Protocol" (a GPS packet then a PTU packet, the extended forms
with --extended, an ozonesonde XDATA packet with --xdata), each with its CRC-16 (0x1021, started from 0x1D0F, sent most
significant byte first), sends the bytes as asynchronous 8N1 characters (a start bit, eight data bits least significant
first, a stop bit) at 1200 baud with the line idle between frames, as continuous-phase 1200 Hz (1) and 2200 Hz (0) audio
frequency shift keying, which frequency-modulates the carrier by +-3 kHz. The carrier is offset by --offset hertz, has a
random phase and complex Gaussian noise for the carrier-to-noise ratio asked for in 10 kHz. Writes OUT.u8 (for
`rtlsdr-tool sonde --type imet --ifile`), OUT-fm.wav (48 kHz FM audio, from a discriminator on the same noisy samples, for
rs1729's imet1rs_dft) and OUT.truth.json (what was sent, one object per frame). Needs numpy and scipy.
"""
import argparse
import json
import struct
import wave
import numpy as np
from scipy import signal


def crc16(data):
    rem = 0x1D0F
    for byte in data:
        rem ^= byte << 8
        for _ in range(8):
            rem = ((rem << 1) ^ 0x1021) & 0xFFFF if rem & 0x8000 else (rem << 1) & 0xFFFF
    return rem


def seal(data):
    c = crc16(data)
    return bytes(data) + bytes([c >> 8, c & 0xFF])


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def packets(n, extended, xdata):
    """The bytes of second n of the flight and what they say."""
    lat = f32(47.5512 + 0.00041 * n)
    lon = f32(-122.3046 + 0.00083 * n)
    alt = 1204 + 5 * n
    sats = 9 + n % 3
    hour, minute, second = 10, 20 + (18 + n) // 60, (18 + n) % 60
    number = 5000 + n
    pressure = round(856.43 - 0.55 * n, 2)
    temp = round(-12.34 - 0.03 * n, 2)
    hum = round(47.25 + 0.1 * n, 2)
    batt = 4.7
    gps = [1, 5 if extended else 2] + list(struct.pack("<f", lat)) + list(struct.pack("<f", lon)) + [(alt + 5000) & 255, (alt + 5000) >> 8, sats]
    if extended:
        gps += list(struct.pack("<fff", 6.5, -2.25, 5.125))
    gps += [hour, minute, second]
    ptu = [1, 4 if extended else 1, number & 255, number >> 8]
    p = round(pressure * 100)
    ptu += [p & 255, (p >> 8) & 255, p >> 16]
    ptu += list(struct.pack("<h", round(temp * 100))) + list(struct.pack("<H", round(hum * 100))) + [round(batt * 10)]
    if extended:
        ptu += list(struct.pack("<hhh", 2150, 1925, -350))
    out = seal(gps) + seal(ptu)
    aux = None
    if xdata:
        ic, tp, ip = 2345 + n, 3125, 77
        body = [0x01, 0x00, ic >> 8, ic & 255, (tp >> 8) & 255, tp & 255, ip, 119]
        out += seal([1, 3, len(body)] + body)
        aux = "".join("%02X" % b for b in body)
    truth = {"frame": number, "datetime": "%02d:%02d:%02d" % (hour, minute, second), "lat": lat, "lon": lon, "alt": alt, "sats": sats,
             "temp": temp, "humidity": hum, "pressure": pressure, "batt": batt}
    if aux:
        truth["aux"] = aux
    return out, truth


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--rate", type=int, default=240000)
    parser.add_argument("--cnr", type=float, default=20)
    parser.add_argument("--offset", type=float, default=3000)
    parser.add_argument("--deviation", type=float, default=3000)
    parser.add_argument("--baud", type=float, default=1200)
    parser.add_argument("--extended", action="store_true")
    parser.add_argument("--xdata", action="store_true")
    parser.add_argument("--seed", type=int, default=1)
    a = parser.parse_args()
    rng = np.random.default_rng(a.seed)

    bits = [1] * 600
    truths = []
    for n in range(a.seconds):
        frame, truth = packets(n, a.extended, a.xdata)
        truths.append(truth)
        for byte in frame:
            bits += [0] + [(byte >> k) & 1 for k in range(8)] + [1]
        # one frame a second: the rest of the second is idle
        bits += [1] * (round(a.baud) - 10 * len(frame))
    spb = a.rate / a.baud
    count = int(len(bits) * spb)
    line = np.array(bits)[(np.arange(count) / spb).astype(int)]
    tone = np.where(line == 1, 1200.0, 2200.0)
    audio = np.sin(2 * np.pi * np.cumsum(tone) / a.rate)
    freq = a.offset + a.deviation * audio
    phase = rng.uniform(0, 2 * np.pi) + 2 * np.pi * np.cumsum(freq) / a.rate
    z = np.exp(1j * phase)
    sigma = np.sqrt(10 ** (-a.cnr / 10) * a.rate / 10000 / 2)          # per component, carrier power 1, noise power in 10 kHz
    z = z + sigma * (rng.standard_normal(count) + 1j * rng.standard_normal(count))
    scale = 50.0
    u8 = np.empty(2 * count, dtype=np.uint8)
    u8[0::2] = np.clip(np.round(127.5 + scale * z.real), 0, 255)
    u8[1::2] = np.clip(np.round(127.5 + scale * z.imag), 0, 255)
    u8.tofile(a.out + ".u8")

    # FM audio from the same noisy samples: quantised like the dongle gives them, mixed to the carrier, low-passed to
    # +-6 kHz, discriminated, decimated to 48 kHz.
    q = (u8[0::2].astype(float) - 127.5) + 1j * (u8[1::2].astype(float) - 127.5)
    q *= np.exp(-2j * np.pi * a.offset * np.arange(count) / a.rate)
    taps = signal.firwin(129, 6000, fs=a.rate)
    q = signal.lfilter(taps, 1, q)
    disc = np.angle(q[1:] * np.conj(q[:-1])) * a.rate / (2 * np.pi)
    audio48 = signal.resample_poly(disc, 1, a.rate // 48000)
    pcm = np.clip(audio48 / a.deviation * 12000, -32768, 32767).astype("<i2")
    with wave.open(a.out + "-fm.wav", "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(48000)
        w.writeframes(pcm.tobytes())
    json.dump(truths, open(a.out + ".truth.json", "w"))


if __name__ == "__main__":
    main()
