#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Makes an AIS signal from random vessel messages, independently of this package's code.

usage: ais-oracle.py OUT [--messages 20] [--rate 240000] [--cnr 25] [--offset 0] [--both] [--invert] [--seed 1]

Builds messages of types 1, 3, 4, 5, 18, 19, 21 and 24 (both parts) field by field from ITU-R M.1371's tables, sends each as
a burst the way the recommendation has it (24 bits of 0101, a flag, the bits with a zero stuffed after five ones, the frame
check sequence (X.25 CRC, low byte first, bytes least significant bit first), a flag), NRZI coded (a 0 is a change) and
GMSK modulated (BT 0.4, 9600 bit/s, deviation 2.4 kHz), on 161.975 MHz (channel A, 25 kHz below the middle of a 240 kS/s
capture) or, with --both, alternately on that and on 162.025 MHz (B), with an offset, a random phase and noise for the
carrier-to-noise ratio asked for in 25 kHz. Writes OUT.u8 (for `rtlsdr-tool ais --ifile`), OUT-fm.wav (48 kHz FM audio from
a discriminator on channel A's noisy samples, 12 kHz wide) and OUT.truth.json (what was sent: the NMEA sentences, and the
fields). Needs numpy and scipy.
"""
import argparse
import json
import wave
import numpy as np
from scipy import signal


def crc16(data):
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc ^ 0xFFFF


class Bits:
    def __init__(self):
        self.b = []

    def put(self, value, width):
        value &= (1 << width) - 1
        self.b += [(value >> (width - 1 - k)) & 1 for k in range(width)]
        return self

    def text(self, s, chars):
        s = s.upper().ljust(chars, "@")[:chars]
        for c in s:
            v = ord(c)
            self.put(v - 64 if v >= 64 else v, 6)
        return self

    def pad(self, n):
        self.b += [0] * (n - len(self.b))
        return self


def armour(bits):
    fill = (-len(bits)) % 6
    padded = bits + [0] * fill
    out = ""
    for k in range(0, len(padded), 6):
        v = 0
        for bit in padded[k:k + 6]:
            v = v << 1 | bit
        out += chr(v + 48 if v < 40 else v + 56)
    return out, fill


def sentences(bits, channel, seq):
    payload, fill = armour(bits)
    chunks = [payload[k:k + 60] for k in range(0, len(payload), 60)]
    out = []
    for i, chunk in enumerate(chunks):
        body = "AIVDM,%d,%d,%s,%s,%s,%d" % (len(chunks), i + 1, str(seq % 10) if len(chunks) > 1 else "", channel, chunk, fill if i == len(chunks) - 1 else 0)
        c = 0
        for ch in body:
            c ^= ord(ch)
        out.append("!%s*%02X" % (body, c))
    return out


def pos(rng):
    return round(float(rng.uniform(-179, 179)), 5), round(float(rng.uniform(-80, 80)), 5)


def make_message(rng, kind):
    mmsi = int(rng.integers(200_000_000, 780_000_000))
    b = Bits()
    truth = {"mmsi": mmsi}
    words = ["OCEAN", "STAR", "MAERSK", "HARBOR", "QUEEN", "NORTH", "SEA", "PILOT", "FERRY", "TRADER"]
    name = (" ".join(rng.choice(words, size=2))).upper()[:20]
    call = "".join(rng.choice(list("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789"), size=7))
    lon, lat = pos(rng)
    if kind in (1, 3):
        status, rot, sog, cog, hdg, sec = int(rng.integers(0, 9)), int(rng.integers(-100, 100)), round(float(rng.uniform(0, 30)), 1), \
            round(float(rng.uniform(0, 359.9)), 1), int(rng.integers(0, 359)), int(rng.integers(0, 60))
        b.put(kind, 6).put(0, 2).put(mmsi, 30).put(status, 4).put(rot, 8).put(round(sog * 10), 10).put(1, 1)
        b.put(round(lon * 600000), 28).put(round(lat * 600000), 27).put(round(cog * 10), 12).put(hdg, 9).put(sec, 6).put(0, 2).put(0, 3)
        b.put(0, 1).put(int(rng.integers(0, 1 << 19)), 19)
        truth.update(type=kind, status=status, turn=rot, speed=sog, lon=lon, lat=lat, course=cog, heading=hdg, second=sec)
    elif kind == 4:
        y, mo, d, h, mi, s = 2025, int(rng.integers(1, 13)), int(rng.integers(1, 29)), int(rng.integers(0, 24)), int(rng.integers(0, 60)), int(rng.integers(0, 60))
        b.put(4, 6).put(0, 2).put(mmsi, 30).put(y, 14).put(mo, 4).put(d, 5).put(h, 5).put(mi, 6).put(s, 6).put(1, 1)
        b.put(round(lon * 600000), 28).put(round(lat * 600000), 27).put(1, 4).pad(168)
        truth.update(type=4, year=y, month=mo, day=d, hour=h, minute=mi, second=s, lon=lon, lat=lat)
    elif kind == 5:
        imo = int(rng.integers(1_000_000, 9_999_999))
        dest = "".join(rng.choice(list("ABCDEFGHIJKLMNOPQRSTUVWXYZ "), size=12)).strip()
        shiptype, bow, stern, port, stbd = int(rng.integers(20, 99)), int(rng.integers(5, 300)), int(rng.integers(5, 100)), int(rng.integers(1, 30)), int(rng.integers(1, 30))
        mo, d, h, mi, dr = int(rng.integers(1, 13)), int(rng.integers(1, 29)), int(rng.integers(0, 24)), int(rng.integers(0, 60)), round(float(rng.uniform(1, 20)), 1)
        b.put(5, 6).put(0, 2).put(mmsi, 30).put(0, 2).put(imo, 30).text(call, 7).text(name, 20).put(shiptype, 8)
        b.put(bow, 9).put(stern, 9).put(port, 6).put(stbd, 6).put(1, 4).put(mo, 4).put(d, 5).put(h, 5).put(mi, 6).put(round(dr * 10), 8)
        b.text(dest, 20).put(0, 1).put(0, 1).pad(424)
        truth.update(type=5, imo=imo, callsign=call, shipname=name, ship_type=shiptype, to_bow=bow, to_stern=stern, to_port=port, to_starboard=stbd,
                     month=mo, day=d, hour=h, minute=mi, draught=dr, destination=dest)
    elif kind == 18:
        sog, cog, hdg, sec = round(float(rng.uniform(0, 30)), 1), round(float(rng.uniform(0, 359.9)), 1), int(rng.integers(0, 359)), int(rng.integers(0, 60))
        b.put(18, 6).put(0, 2).put(mmsi, 30).put(0, 8).put(round(sog * 10), 10).put(1, 1).put(round(lon * 600000), 28).put(round(lat * 600000), 27)
        b.put(round(cog * 10), 12).put(hdg, 9).put(sec, 6).put(0, 2).put(1, 1).put(1, 1).put(0, 1).put(1, 1).put(0, 1).put(0, 1).put(0, 1).put(0, 20)
        b.pad(168)
        truth.update(type=18, speed=sog, lon=lon, lat=lat, course=cog, heading=hdg, second=sec)
    elif kind == 19:
        sog, cog, hdg, sec = round(float(rng.uniform(0, 30)), 1), round(float(rng.uniform(0, 359.9)), 1), int(rng.integers(0, 359)), int(rng.integers(0, 60))
        shiptype, bow, stern, port, stbd = int(rng.integers(20, 99)), int(rng.integers(5, 300)), int(rng.integers(5, 100)), int(rng.integers(1, 30)), int(rng.integers(1, 30))
        b.put(19, 6).put(0, 2).put(mmsi, 30).put(0, 8).put(round(sog * 10), 10).put(1, 1).put(round(lon * 600000), 28).put(round(lat * 600000), 27)
        b.put(round(cog * 10), 12).put(hdg, 9).put(sec, 6).put(0, 4).text(name, 20).put(shiptype, 8).put(bow, 9).put(stern, 9).put(port, 6).put(stbd, 6)
        b.put(1, 4).put(0, 1).put(0, 1).put(0, 1).put(0, 4)
        truth.update(type=19, speed=sog, lon=lon, lat=lat, course=cog, heading=hdg, second=sec, shipname=name, ship_type=shiptype,
                     to_bow=bow, to_stern=stern, to_port=port, to_starboard=stbd)
    elif kind == 21:
        atype = int(rng.integers(1, 31))
        b.put(21, 6).put(0, 2).put(mmsi, 30).put(atype, 5).text(name, 20).put(1, 1).put(round(lon * 600000), 28).put(round(lat * 600000), 27)
        bow, stern, port, stbd = int(rng.integers(0, 50)), int(rng.integers(0, 50)), int(rng.integers(0, 20)), int(rng.integers(0, 20))
        b.put(bow, 9).put(stern, 9).put(port, 6).put(stbd, 6).put(1, 4).put(int(rng.integers(0, 60)), 6).put(0, 1).put(0, 8).put(0, 1).put(0, 1).put(0, 1).put(0, 1)
        truth.update(type=21, aid_type=atype, shipname=name, lon=lon, lat=lat, to_bow=bow, to_stern=stern, to_port=port, to_starboard=stbd)
    elif kind == 240:
        b.put(24, 6).put(0, 2).put(mmsi, 30).put(0, 2).text(name, 20).pad(168)
        truth.update(type=24, partno=0, shipname=name)
    else:
        shiptype, bow, stern, port, stbd = int(rng.integers(20, 99)), int(rng.integers(5, 30), ), int(rng.integers(5, 20)), int(rng.integers(1, 5)), int(rng.integers(1, 5))
        b.put(24, 6).put(0, 2).put(mmsi, 30).put(1, 2).put(shiptype, 8).text("VEN", 3).put(5, 4).put(12345, 20).text(call, 7)
        b.put(bow, 9).put(stern, 9).put(port, 6).put(stbd, 6).put(0, 6)
        truth.update(type=24, partno=1, ship_type=shiptype, vendorid="VEN", callsign=call, to_bow=bow, to_stern=stern, to_port=port, to_starboard=stbd)
    return b.b, truth


def frame_bits(message):
    bits = list(message)
    assert len(bits) % 8 == 0, len(bits)
    data = bytes(sum(bit << k for k, bit in enumerate(bits[i:i + 8])) for i in range(0, len(bits), 8))
    crc = crc16(data)
    bits += [(crc >> k) & 1 for k in range(16)]                   # low byte first, each least significant bit first
    stuffed, ones = [], 0
    for bit in bits:
        stuffed.append(bit)
        ones = ones + 1 if bit else 0
        if ones == 5:
            stuffed.append(0)
            ones = 0
    flag = [0, 1, 1, 1, 1, 1, 1, 0]
    return [0, 1] * 12 + flag + stuffed + flag + [0] * 8


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--messages", type=int, default=20)
    parser.add_argument("--rate", type=int, default=240000)
    parser.add_argument("--cnr", type=float, default=25)
    parser.add_argument("--offset", type=float, default=0)
    parser.add_argument("--both", action="store_true")
    parser.add_argument("--invert", action="store_true")
    parser.add_argument("--seed", type=int, default=1)
    a = parser.parse_args()
    rng = np.random.default_rng(a.seed)
    kinds = [1, 3, 4, 5, 18, 19, 21, 240, 241]
    spb = a.rate / 9600
    gap = int(0.05 * a.rate)
    segments, truths, parts = [], [], []
    for n in range(a.messages):
        kind = kinds[n % len(kinds)] if n < len(kinds) else int(rng.choice(kinds))
        message, truth = make_message(rng, kind)
        channel = "B" if a.both and n % 2 else "A"
        truth["channel"] = channel
        truth["nmea"] = sentences(message, channel, n)
        truth["bits"] = "".join(map(str, message))
        truths.append(truth)
        line, level = [], 1
        for bit in frame_bits(message):
            if bit == 0:
                level = -level
            line.append(level)
        parts.append((channel, np.array(line, dtype=float)))
    total = gap
    for _, line in parts:
        total += int(len(line) * spb) + gap
    freq = np.zeros(total)
    on_a, on_b = np.zeros(total, bool), np.zeros(total, bool)
    cursor = gap
    for channel, line in parts:
        count = int(len(line) * spb)
        nrz = line[(np.arange(count) / spb).astype(int)] * (-1 if a.invert else 1)
        # Gaussian filter, BT 0.4: sigma = sqrt(ln 2) / (2 pi BT) bit periods.
        sigma = np.sqrt(np.log(2)) / (2 * np.pi * 0.4) * spb
        half = int(4 * sigma)
        k = np.exp(-0.5 * (np.arange(-half, half + 1) / sigma) ** 2)
        k /= k.sum()
        shaped = np.convolve(np.concatenate([np.full(half, nrz[0]), nrz, np.full(half, nrz[-1])]), k, mode="same")[half:half + count]
        freq[cursor:cursor + count] = 2400 * shaped
        (on_a if channel == "A" else on_b)[cursor:cursor + count] = True
        cursor += count + gap
    center_a, center_b = -25000.0 + a.offset, 25000.0 + a.offset
    phase_a = rng.uniform(0, 2 * np.pi) + 2 * np.pi * np.cumsum(center_a + freq) / a.rate
    phase_b = rng.uniform(0, 2 * np.pi) + 2 * np.pi * np.cumsum(center_b + freq) / a.rate
    z = np.exp(1j * phase_a) * on_a + np.exp(1j * phase_b) * on_b
    sigma = np.sqrt(10 ** (-a.cnr / 10) * a.rate / 25000 / 2)
    z = z + sigma * (rng.standard_normal(total) + 1j * rng.standard_normal(total))
    scale = 50.0
    u8 = np.empty(2 * total, dtype=np.uint8)
    u8[0::2] = np.clip(np.round(127.5 + scale * z.real), 0, 255)
    u8[1::2] = np.clip(np.round(127.5 + scale * z.imag), 0, 255)
    u8.tofile(a.out + ".u8")

    q = (u8[0::2].astype(float) - 127.5) + 1j * (u8[1::2].astype(float) - 127.5)
    q *= np.exp(-2j * np.pi * center_a * np.arange(total) / a.rate)
    q = signal.lfilter(signal.firwin(129, 8000, fs=a.rate), 1, q)
    disc = np.angle(q[1:] * np.conj(q[:-1])) * a.rate / (2 * np.pi)
    audio = signal.resample_poly(disc, 1, a.rate // 48000)
    pcm = np.clip(audio / 2400 * 8000, -32768, 32767).astype("<i2")
    with wave.open(a.out + "-fm.wav", "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(48000)
        w.writeframes(pcm.tobytes())
    json.dump(truths, open(a.out + ".truth.json", "w"))


if __name__ == "__main__":
    main()
