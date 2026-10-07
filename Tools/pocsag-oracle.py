#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Makes a POCSAG paging signal from a list of random pages, independently of this package's code.

usage: pocsag-oracle.py OUT [--pages 12] [--baud 1200] [--rate 240000] [--cnr 25] [--offset 3000] [--deviation 4500]
                        [--bursts 2] [--invert] [--seed 1]

Builds each page as ITU-R M.584 lays it out (a 576-bit preamble, batches of a synchronisation codeword and eight frames of two
codewords, an address codeword in the frame the address's low three bits name, 20 bits of text in each message codeword,
numeric text as four-bit digits and alphanumeric as seven-bit characters, both least significant bit first, (31,21) BCH
check bits with generator 0x769 and even parity; a last batch of idle codewords before the carrier drops), as 2-FSK (a 1 is the lower frequency) on an FM carrier, with an offset, a
random phase and complex Gaussian noise for the carrier-to-noise ratio asked for in 25 kHz. The pages go out in --bursts
transmissions with silence (noise alone) between them. Writes OUT.u8 (for `rtlsdr-tool pager --ifile`), OUT-fm.wav (22.05 kHz
FM audio from a discriminator on the same noisy samples, for multimon-ng) and OUT.truth.json (what was sent). Needs numpy
and scipy.
"""
import argparse
import json
import wave
import numpy as np
from scipy import signal

SYNC = 0x7CD215D8
IDLE = 0x7A89C197
NUMERIC = "0123456789.U -]["          # index = four-bit value (sent least significant bit first); 10 is a spare shown as '.'


def bch_remainder(data21):
    reg = data21 << 10
    for bit in range(30, 9, -1):
        if reg >> bit & 1:
            reg ^= 0x769 << (bit - 10)
    return reg & 0x3FF


def codeword(data21):
    word = (data21 << 11) | (bch_remainder(data21) << 1)
    return word | (bin(word).count("1") & 1)


def bits_of(values, width):
    return [(v >> k) & 1 for v in values for k in range(width)]       # least significant bit first


def page_codewords(address, function, kind, text):
    words = [codeword(((address >> 3) & 0x3FFFF) << 2 | function)]
    if kind == "numeric":
        data = bits_of([NUMERIC.index(c) for c in text], 4)
        pad = [0, 0, 1, 1]                                              # a space
    else:
        data = bits_of([ord(c) for c in text], 7)
        pad = [0] * 7
    while len(data) % 20:
        data += pad[:min(len(pad), 20 - len(data) % 20)] if kind == "numeric" else [0]
    for k in range(0, len(data), 20):
        value = 0
        for bit in data[k:k + 20]:
            value = value << 1 | bit
        words.append(codeword(1 << 20 | value))
    return words


def stream(pages):
    """Codewords of a transmission: pages placed in the frame their address names, idle where nothing is sent."""
    slots = []
    for page in pages:
        frame = page["address"] & 7
        while (len(slots) // 2) % 8 != frame or len(slots) % 2:
            slots.append(IDLE)
        slots += page_codewords(page["address"], page["function"], page["kind"], page["text"])
    while len(slots) % 16:
        slots.append(IDLE)
    slots += [IDLE] * 16                  # a transmitter ends with an idle batch before it drops the carrier
    words = []
    for k in range(0, len(slots), 16):
        words.append(SYNC)
        words += slots[k:k + 16]
    return words


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--pages", type=int, default=12)
    parser.add_argument("--baud", type=float, default=1200)
    parser.add_argument("--rate", type=int, default=240000)
    parser.add_argument("--cnr", type=float, default=25)
    parser.add_argument("--offset", type=float, default=3000)
    parser.add_argument("--deviation", type=float, default=4500)
    parser.add_argument("--bursts", type=int, default=2)
    parser.add_argument("--invert", action="store_true")
    parser.add_argument("--seed", type=int, default=1)
    a = parser.parse_args()
    rng = np.random.default_rng(a.seed)

    words_pool = ["ALARM", "fire", "unit", "responding", "to", "station", "Main", "St", "HOSPITAL", "call", "back", "ext", "4021",
                  "on", "scene", "stand", "down", "ETA", "10min", "patient", "transport", "Room", "12B", "please", "confirm"]
    pages, used = [], set()
    for n in range(a.pages):
        while True:
            address = int(rng.integers(8, 2_000_000))
            if address not in used:
                used.add(address)
                break
        if rng.random() < 0.35:
            text = "".join(rng.choice(list("0123456789 -[]U"), size=int(rng.integers(4, 22))))
            pages.append({"address": address, "function": 0, "kind": "numeric", "text": text})
        else:
            text = " ".join(rng.choice(words_pool, size=int(rng.integers(2, 9))))
            pages.append({"address": address, "function": int(rng.choice([1, 2, 3])), "kind": "alpha", "text": text})

    bursts = [pages[i::a.bursts] for i in range(a.bursts)]
    bits = []
    gap = int(a.baud * 0.5)
    carrier = []
    for burst in bursts:
        words = stream(burst)
        b = [1, 0] * 288
        for w in words:
            b += [(w >> k) & 1 for k in range(31, -1, -1)]
        bits += [None] * gap + b
    bits += [None] * gap
    spb = a.rate / a.baud
    count = int(len(bits) * spb)
    idx = (np.arange(count) / spb).astype(int)
    on = np.array([b is not None for b in bits])[idx]
    nrz = np.array([0.0 if b is None else (-1.0 if b else 1.0) for b in bits])[idx]
    if a.invert:
        nrz = -nrz
    kernel = np.hanning(int(spb * 0.6) | 1)
    kernel /= kernel.sum()
    nrz = np.convolve(nrz, kernel, mode="same")
    freq = a.offset + a.deviation * nrz
    phase = rng.uniform(0, 2 * np.pi) + 2 * np.pi * np.cumsum(freq) / a.rate
    carrier = np.exp(1j * phase) * on
    sigma = np.sqrt(10 ** (-a.cnr / 10) * a.rate / 25000 / 2)
    z = carrier + sigma * (rng.standard_normal(count) + 1j * rng.standard_normal(count))
    scale = 50.0
    u8 = np.empty(2 * count, dtype=np.uint8)
    u8[0::2] = np.clip(np.round(127.5 + scale * z.real), 0, 255)
    u8[1::2] = np.clip(np.round(127.5 + scale * z.imag), 0, 255)
    u8.tofile(a.out + ".u8")

    q = (u8[0::2].astype(float) - 127.5) + 1j * (u8[1::2].astype(float) - 127.5)
    q *= np.exp(-2j * np.pi * a.offset * np.arange(count) / a.rate)
    q = signal.lfilter(signal.firwin(129, 7000, fs=a.rate), 1, q)
    disc = np.angle(q[1:] * np.conj(q[:-1])) * a.rate / (2 * np.pi)
    audio = signal.resample_poly(disc, 147, 1600)
    pcm = np.clip(audio / a.deviation * 12000, -32768, 32767).astype("<i2")
    with wave.open(a.out + "-fm.wav", "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(22050)
        w.writeframes(pcm.tobytes())
    json.dump(pages, open(a.out + ".truth.json", "w"))


if __name__ == "__main__":
    main()
