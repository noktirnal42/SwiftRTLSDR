#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Makes VDL Mode 2 test signals: bursts of AVLC frames as ground stations and aircraft send them, independently of this
package's code.

usage: vdl2-oracle.py OUT [--bursts 40] [--channels 136.975e6,136.875e6,136.775e6] [--center auto] [--rate 1050000]
                          [--ebn0 20] [--offset 0] [--ppm 0] [--seed 1]

Frames: ACARS uplinks and downlinks in I frames (FF FF 01 and an ACARS block with its CRC), a ground station's
information frame (XID, GSIF: modulation, airport coverage, frequency), an aircraft's link establishment (XID: its
position and destination airport), receive-ready S frames; one to three a burst. Each burst is built as the format has
it: frames with the X.25 FCS, flags and bit stuffing; a header of three reserved bits, the 17-bit length and five check
bits; Reed-Solomon (255,249) over GF(256) (0x187, roots alpha^120...125), the last block's check octets cut to 0, 2 or 4
when it is short, interleaved by column; all of that scrambled (x^15 + x + 1 from 0x6959); five ramp-up symbols, the
16-symbol synchronisation sequence, then Gray-coded D8PSK at 10500 symbols/s with raised-cosine pulses (alpha 0.6).

Writes OUT.u8 (u8 I/Q at --rate, each channel's bursts at their frequency, a carrier --offset Hz off, the transmitter's
clock --ppm fast, noise for --ebn0 dB per bit) and OUT.txt (one line a frame: channel, burst number, the frame in hex
with its FCS). Needs numpy.
"""
import argparse

import numpy as np

SYMBOL_RATE = 10500
GRAY = [0, 1, 3, 2, 6, 7, 5, 4]                 # phase step k*pi/4 -> bits, first bit the most significant
STEP = {g: k for k, g in enumerate(GRAY)}
SYNC = [0, 2, 3, 6, 0, 1, 5, 6, 1, 4, 3, 7, 5, 7, 4, 2]
H = [0b0000000011111111111110000, 0b0011111100001111111101000, 0b1100011100110000111100100,
     0b1101101101010011001100010, 0b0110100111100101010100001]

# GF(256), polynomial 0x187, for the Reed-Solomon code.
EXP = [0] * 512
LOG = [0] * 256
x = 1
for i in range(255):
    EXP[i] = x
    LOG[x] = i
    x <<= 1
    if x & 0x100:
        x ^= 0x187
for i in range(255, 512):
    EXP[i] = EXP[i - 255]


def gmul(a, b):
    return 0 if a == 0 or b == 0 else EXP[LOG[a] + LOG[b]]


GENERATOR = [1]
for i in range(6):
    root = EXP[120 + i]
    nxt = GENERATOR + [0]
    for j, c in enumerate(GENERATOR):
        nxt[j + 1] ^= gmul(c, root)
    GENERATOR = nxt


def rs_parity(data):
    """The six check octets of data (249 octets, the first the highest power)."""
    rem = [0] * 6
    for d in data:
        f = d ^ rem[0]
        rem = rem[1:] + [0]
        for i in range(6):
            rem[i] ^= gmul(GENERATOR[i + 1], f)
    return rem


def fcs(data):
    """The X.25 frame check sequence: CRC-16/CCITT reflected from 0xffff, complemented, low octet first."""
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    crc ^= 0xFFFF
    return [crc & 0xFF, crc >> 8]


def acars_crc(data):
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc


def address(addr, kind, status, last=False):
    """A 4-octet AVLC address: 24-bit address, 3-bit type, status bit; seven bits an octet, the lowest bit the
    extension bit (set in an address field's last octet)."""
    value = status << 27 | kind << 24 | addr
    r = int(format(value, "028b")[::-1], 2)
    out = [((r >> (7 * i)) & 0x7F) << 1 for i in range(4)]
    if last:
        out[3] |= 1
    return out


def parity7(c):
    c &= 0x7F
    return c | (0x80 if bin(c).count("1") % 2 == 0 else 0)


def acars_block(mode, reg, ack, label, block, text):
    header = [ord(mode)] + list(reg.rjust(7, ".").encode()) + [ack] + list(label.encode()) + [ord(block)]
    chars = [parity7(c) for c in header]
    if text:
        chars += [parity7(2)] + [parity7(c) for c in text.encode()]
    chars.append(0x83)                                              # ETX with its parity bit
    crc = acars_crc(chars)
    return chars + [crc & 0xFF, crc >> 8, 0x7F]


def location(lat, lon):
    la, lo = int(round(lat * 10)) & 0xFFF, int(round(lon * 10)) & 0xFFF
    return [la >> 4, (la & 0xF) << 4 | lo >> 8, lo & 0xFF]


def tlv(kind, value):
    return [kind, len(value)] + list(value)


def xid(private, public=b""):
    out = [0x82]
    if public:
        out += [0x80, len(public) >> 8, len(public) & 0xFF] + list(public)
    out += [0xF0, len(private) >> 8, len(private) & 0xFF] + list(private)
    return out


def frame(rng, gs, aircraft, kind):
    reg = "N%d%s" % (rng.integers(100, 999), "".join(rng.choice(list("ABCDEFGHJKLMNPRSTUVWXYZ"), 2)))
    airborne = int(rng.integers(0, 2))
    if kind == "uplink":
        text = "".join(chr(int(c)) for c in rng.integers(0x20, 0x7F, int(rng.integers(0, 150))))
        body = address(aircraft, 1, airborne) + address(gs, 4, 0, True)
        control = int(rng.integers(0, 8)) << 1 | int(rng.integers(0, 2)) << 4 | int(rng.integers(0, 8)) << 5
        info = [0xFF, 0xFF, 0x01] + acars_block("2", reg, 0x15, str(rng.choice(["H1", "SA", "_\x7f", "5Z"])),
                                                chr(ord("A") + int(rng.integers(0, 26))), text)
    elif kind == "downlink":
        text = "M%02dA%s%04d" % (rng.integers(0, 100), rng.choice(["BA", "UA", "DL"]), rng.integers(0, 10000))
        text += "".join(chr(int(c)) for c in rng.integers(0x20, 0x7F, int(rng.integers(0, 150))))
        body = address(gs, 4, 0) + address(aircraft, 1, 0, True)
        control = int(rng.integers(0, 8)) << 1 | int(rng.integers(0, 8)) << 5
        info = [0xFF, 0xFF, 0x01] + acars_block("2", reg, 0x15, str(rng.choice(["H1", "Q0", "5V", "B6"])),
                                                str(int(rng.integers(0, 10))), text)
    elif kind == "gsif":
        body = address(0xFFFFFF, 7, 1) + address(gs, 4, 0, True)  # to all stations, on ground; command
        control = 0x2B << 2 | 0x03                                    # XID, P/F 0
        private = tlv(0x81, [2]) + tlv(0xC1, b"KSFOKOAK") + tlv(0xC3, b"KSFO") + tlv(0xC0, [0x2E, 0x71] + address(gs, 4, 0))
        info = xid(bytes(private))
    elif kind == "establish":
        lat, lon = rng.uniform(-80, 80), rng.uniform(-179, 179)
        body = address(gs, 4, airborne) + address(aircraft, 1, 0, True)
        control = 0x2B << 2 | 0x03 | 0x10                             # XID, P/F 1
        private = tlv(0x01, [0x00]) + tlv(0x83, b"EGLL") + tlv(0x84, location(lat, lon) + [int(rng.integers(0, 45))])
        info = xid(bytes(private), bytes(tlv(0x01, b"\x82")))
    else:                                                             # receive ready
        body = address(gs, 4, airborne) + address(aircraft, 1, 1, True)
        control = 0x01 | int(rng.integers(0, 8)) << 5
        info = []
    data = body + [control] + info
    return data + fcs(data)


def stuffed_bits(frames):
    bits = [0, 1, 1, 1, 1, 1, 1, 0]
    for f in frames:
        ones = 0
        for b in f:
            for j in range(8):
                bit = (b >> j) & 1
                bits.append(bit)
                ones = ones + 1 if bit else 0
                if ones == 5:
                    bits.append(0)
                    ones = 0
        bits += [0, 1, 1, 1, 1, 1, 1, 0]
    return bits


def burst_bits(frames):
    data_bits = stuffed_bits(frames)
    length = len(data_bits)
    octets = []
    for i in range(0, length, 8):
        chunk = data_bits[i:i + 8]
        octets.append(sum(b << j for j, b in enumerate(chunk)))
    blocks = [octets[i:i + 249] for i in range(0, len(octets), 249)]
    last = len(blocks[-1])
    counts = [6] * (len(blocks) - 1) + [0 if last < 3 else 2 if last < 31 else 4 if last < 68 else 6]
    parity = [rs_parity(b + [0] * (249 - len(b)))[:n] for b, n in zip(blocks, counts)]
    sent = []
    for col in range(249):
        for row, b in enumerate(blocks):
            if col < len(b):
                sent.append(b[col])
    for col in range(6):
        for row, p in enumerate(parity):
            if col < len(p):
                sent.append(p[col])
    # Header: reserved (3 bits), length (17 bits, least significant first), check bits.
    word = int(format(length, "017b")[::-1], 2) << 5
    for i in range(5):
        if bin(word & H[i]).count("1") % 2:
            word |= 1 << (4 - i)
    bits = [(word >> (24 - i)) & 1 for i in range(25)]
    for o in sent:
        bits += [(o >> j) & 1 for j in range(8)]
    lfsr = 0x6959
    for i in range(len(bits)):
        out = (lfsr ^ (lfsr >> 14)) & 1
        lfsr = (lfsr >> 1) | (out << 14)
        bits[i] ^= out
    bits += [0] * (-len(bits) % 3)
    return bits


def symbols(bits):
    steps = [0] * 5 + [STEP[g] for g in SYNC]
    steps += [STEP[bits[i] << 2 | bits[i + 1] << 1 | bits[i + 2]] for i in range(0, len(bits), 3)]
    return np.exp(1j * np.pi / 4 * np.cumsum(steps))


def raised_cosine(t, alpha=0.6):
    t = np.asarray(t, dtype=float)
    out = np.sinc(t) * np.cos(np.pi * alpha * t)
    denom = 1 - (2 * alpha * t) ** 2
    singular = np.abs(denom) < 1e-9
    out = np.where(singular, np.pi / 4 * np.sinc(1 / (2 * alpha)), out / np.where(singular, 1, denom))
    return out


def modulate(sym, rate, ppm):
    """Raised-cosine pulses at the symbol times (clock ppm fast), ramped up over the five ramp-up symbols and down
    after the last."""
    t_sym = 1 / (SYMBOL_RATE * (1 + ppm * 1e-6))
    n = int((len(sym) + 8) * t_sym * rate)
    t = np.arange(n) / rate
    out = np.zeros(n, complex)
    centres = (np.arange(len(sym)) + 4) * t_sym
    for k, s in enumerate(sym):
        lo, hi = int((centres[k] - 8 * t_sym) * rate), int((centres[k] + 8 * t_sym) * rate) + 1
        lo, hi = max(lo, 0), min(hi, n)
        out[lo:hi] += s * raised_cosine((t[lo:hi] - centres[k]) / t_sym)
    ramp = np.clip((t - 3.5 * t_sym) / (2.5 * t_sym), 0, 1)
    ramp *= np.clip((centres[-1] + 2 * t_sym - t) / (2 * t_sym), 0, 1)
    return out * (0.5 - 0.5 * np.cos(np.pi * ramp))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("out")
    p.add_argument("--bursts", type=int, default=40)
    p.add_argument("--channels", default="136.975e6,136.875e6,136.775e6")
    p.add_argument("--center", default="auto")
    p.add_argument("--rate", type=float, default=1_050_000)
    p.add_argument("--ebn0", type=float, default=20)
    p.add_argument("--offset", type=float, default=0)
    p.add_argument("--ppm", type=float, default=0)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--frames", help="send these AVLC frames (a hexadecimal frame with its FCS on each line), one a burst on the first channel, instead of random ones")
    a = p.parse_args()
    rng = np.random.default_rng(a.seed)
    channels = [float(c) for c in a.channels.split(",")]
    center = (min(channels) + max(channels)) / 2 + 12_500 if a.center == "auto" else float(a.center)
    rate = a.rate

    kinds = ["uplink", "downlink", "gsif", "establish", "rr"]
    plan, times, lines = [], [0.02] * len(channels), []
    supplied = [list(bytes.fromhex(line.strip())) for line in open(a.frames) if line.strip()] if a.frames else None
    if supplied:
        a.bursts = len(supplied)
    for b in range(a.bursts):
        c = 0 if supplied else b % len(channels)
        gs, aircraft = int(rng.integers(0x100000, 0xFFFFFF)), int(rng.integers(0x100000, 0xFFFFFF))
        frames = [supplied[b]] if supplied else [frame(rng, gs, aircraft, str(rng.choice(kinds, p=[0.35, 0.35, 0.1, 0.1, 0.1])))
                                                  for _ in range(int(rng.integers(1, 4)))]
        sig = modulate(symbols(burst_bits(frames)), rate, a.ppm)
        plan.append((c, times[c], sig))
        times[c] += len(sig) / rate + rng.uniform(0.005, 0.05)
        lines += [f"{c}\t{b}\t{bytes(f).hex()}" for f in frames]
    n = int((max(times) + 0.02) * rate)
    iq = np.zeros(n, complex)
    powers = []
    for c, start, sig in plan:
        i0 = int(start * rate)
        tt = (np.arange(len(sig)) + i0) / rate
        iq[i0:i0 + len(sig)] += sig * np.exp(2j * np.pi * (channels[c] - center + a.offset) * tt + 1j * rng.uniform(0, 2 * np.pi))
        powers.append(np.mean(np.abs(sig[int(9 * rate / SYMBOL_RATE):-int(4 * rate / SYMBOL_RATE)]) ** 2))
    power = float(np.mean(powers))
    # Eb/N0: Es = power / symbol rate, Eb = Es / 3; complex noise of N0 per hertz over the sample rate.
    n0 = power / SYMBOL_RATE / 3 / 10 ** (a.ebn0 / 10)
    iq += rng.normal(0, np.sqrt(n0 * rate / 2), n) + 1j * rng.normal(0, np.sqrt(n0 * rate / 2), n)
    scale = 40 / np.sqrt(power)
    out = np.empty(2 * n)
    out[0::2], out[1::2] = iq.real * scale + 127.5, iq.imag * scale + 127.5
    np.clip(np.round(out), 0, 255).astype(np.uint8).tofile(a.out + ".u8")
    with open(a.out + ".txt", "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{a.out}: {a.bursts} bursts, {len(lines)} frames on {len(channels)} channels, {n / rate:.1f} s; tuned {center:.0f} Hz "
          f"at {rate:.0f} S/s, Eb/N0 {a.ebn0} dB, offset {a.offset} Hz, clock {a.ppm} ppm")


if __name__ == "__main__":
    main()
