#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Makes a Meteor-M LRPT baseband recording (u8 I/Q) from transfer frames, independently of this package's code.

usage: lrpt-oracle.py CADUS OUT.u8 [--mode oqpsk|qpsk] [--rate 288000] [--esn0 12] [--offset 1500]
                      [--doppler 3000] [--clock-ppm 30] [--alpha 0.6] [--seed 1] [--repeat 1] [--symbol-rate 72000]
                      [--interleave]

CADUS: 1024-byte frames, marker included, derandomised and corrected (SatDump writes such a file, `*.cadu`). Each is
randomised (the CCSDS sequence), for `--mode oqpsk` (Meteor-M N2-3, N2-4) NRZ-M coded, convolutionally encoded
(K=7, G1 0x79, G2 0x5B, G2 sent first), mapped to QPSK (1 -> -1, even channel bits on I) and shaped with a
root-raised-cosine pulse; OQPSK delays Q by half a symbol. The carrier drifts linearly by --doppler Hz over the
recording around --offset Hz, the symbol clock is off by --clock-ppm, and complex Gaussian noise gives the Es/N0 asked
for. --interleave makes the 80 ksym/s mode Meteor-M N2-3 and N2-4 also use: the channel bits go through a convolutional
interleaver of 36 branches, branch b delaying its bits by b x 2048 x 36 (bit n is on branch n mod 36), and every 72
interleaved bits are preceded by the 8-bit marker 0x27; the bits the interleaver holds at either end are random. The
symbol rate is then 80000 unless given. Needs numpy.
"""
import argparse
import numpy as np


def pseudo_noise():
    noise, state = [], 0xFF
    for _ in range(255):
        byte = 0
        for _ in range(8):
            new = (state >> 7 ^ state >> 5 ^ state >> 3 ^ state) & 1
            byte = (byte << 1) | (state & 1)
            state = (state >> 1) | (new << 7)
        noise.append(byte)
    return np.array(noise, dtype=np.uint8)


def channel_bits(cadus, differential):
    pn = np.tile(pseudo_noise(), 4)[:1020]
    frames = cadus.reshape(-1, 1024).copy()
    frames[:, 4:] ^= pn
    bits = np.unpackbits(frames.reshape(-1))
    if differential:
        bits = np.bitwise_xor.accumulate(bits)                   # NRZ-M: e[n] = d[n] ^ e[n-1]
    padded = np.concatenate([np.zeros(6, dtype=np.uint8), bits])
    def tap(delay):
        return padded[6 - delay: len(padded) - delay]
    g1 = tap(0) ^ tap(1) ^ tap(2) ^ tap(3) ^ tap(6)              # 0x79: the new bit and delays 1, 2, 3, 6
    g2 = tap(0) ^ tap(2) ^ tap(3) ^ tap(5) ^ tap(6)              # 0x5B: the new bit and delays 2, 3, 5, 6
    out = np.empty(2 * len(bits), dtype=np.uint8)
    out[0::2], out[1::2] = g2, g1
    return out


MARKER = np.unpackbits(np.array([0x27], dtype=np.uint8))
BRANCHES, BRANCH_DELAY = 36, 2048


def interleave(bits, rng):
    """Convolutional interleaving with markers: out[n] = bits[n - (n % 36) * 2048 * 36], 72 bits a marker."""
    step = BRANCH_DELAY * BRANCHES
    total = len(bits) + (BRANCHES - 1) * step
    total += -total % 72
    n = np.arange(total)
    source = n - (n % BRANCHES) * step
    out = rng.integers(0, 2, total).astype(np.uint8)            # what the interleaver holds before and after the data
    inside = (source >= 0) & (source < len(bits))
    out[inside] = bits[source[inside]]
    blocks = out.reshape(-1, 72)
    return np.concatenate([np.tile(MARKER, (len(blocks), 1)), blocks], axis=1).reshape(-1)


def rrc(t, alpha):
    """Root-raised-cosine impulse response, t in symbols."""
    t = np.asarray(t, dtype=np.float64)
    out = np.empty_like(t)
    zero = np.abs(t) < 1e-9
    special = np.abs(np.abs(4 * alpha * t) - 1) < 1e-9
    normal = ~(zero | special)
    tn = t[normal]
    out[normal] = (np.sin(np.pi * tn * (1 - alpha)) + 4 * alpha * tn * np.cos(np.pi * tn * (1 + alpha))) / \
                  (np.pi * tn * (1 - (4 * alpha * tn) ** 2))
    out[zero] = 1 - alpha + 4 * alpha / np.pi
    out[special] = alpha / np.sqrt(2) * ((1 + 2 / np.pi) * np.sin(np.pi / (4 * alpha)) + (1 - 2 / np.pi) * np.cos(np.pi / (4 * alpha)))
    return out


def shape(symbols, rate, symbol_rate, clock_ppm, alpha, delay, count, span=8):
    """Σ symbols[k]·p(t/T - k - delay) at t = n/rate, n < count."""
    symbol_time = rate / (symbol_rate * (1 + clock_ppm * 1e-6))    # samples per symbol
    position = np.arange(count) / symbol_time - delay               # in symbols
    base = np.floor(position).astype(np.int64)
    out = np.zeros(count)
    for m in range(-span, span + 1):
        k = base + m
        valid = (k >= 0) & (k < len(symbols))
        out[valid] += symbols[k[valid]] * rrc(position[valid] - k[valid], alpha)
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("cadus")
    parser.add_argument("output")
    parser.add_argument("--mode", default="oqpsk", choices=["oqpsk", "qpsk"])
    parser.add_argument("--rate", type=float, default=288000)
    parser.add_argument("--esn0", type=float, default=12)
    parser.add_argument("--offset", type=float, default=1500)
    parser.add_argument("--doppler", type=float, default=3000)
    parser.add_argument("--clock-ppm", type=float, default=30)
    parser.add_argument("--alpha", type=float, default=0.6)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--lead", type=float, default=0.3, help="seconds of noise before and after")
    parser.add_argument("--symbol-rate", type=float, default=None, help="72000, or 80000 with --interleave")
    parser.add_argument("--interleave", action="store_true", help="the 80k mode: interleaver and markers")
    args = parser.parse_args()
    if args.symbol_rate is None:
        args.symbol_rate = 80000 if args.interleave else 72000

    rng = np.random.default_rng(args.seed)
    cadus = np.fromfile(args.cadus, dtype=np.uint8)
    cadus = np.tile(cadus, args.repeat)
    bits = channel_bits(cadus, args.mode == "oqpsk")
    if args.interleave:
        bits = interleave(bits, rng)
    values = 1.0 - 2.0 * bits
    i_symbols, q_symbols = values[0::2], values[1::2]
    lead = int(args.lead * args.rate)
    symbol_rate = args.symbol_rate
    duration = len(i_symbols) / symbol_rate
    count = int(duration * args.rate) + 2 * lead
    delay = lead * symbol_rate / args.rate + rng.uniform(0, 1)       # start partway into a sample
    i_signal = shape(i_symbols, args.rate, symbol_rate, args.clock_ppm, args.alpha, delay, count)
    q_signal = shape(q_symbols, args.rate, symbol_rate, args.clock_ppm, args.alpha, delay + (0.5 if args.mode == "oqpsk" else 0), count)
    signal = i_signal + 1j * q_signal

    t = np.arange(count) / args.rate
    frequency = args.offset + args.doppler * (t / t[-1] - 0.5)
    phase = 2 * np.pi * np.cumsum(frequency) / args.rate + rng.uniform(0, 2 * np.pi)
    signal *= np.exp(1j * phase)
    active = slice(lead, count - lead)
    power = np.mean(np.abs(signal[active]) ** 2)
    sigma2 = power * args.rate / (symbol_rate * 10 ** (args.esn0 / 10))
    noise = rng.normal(0, np.sqrt(sigma2 / 2), count) + 1j * rng.normal(0, np.sqrt(sigma2 / 2), count)
    received = signal + noise
    scale = 40 / np.sqrt(np.mean(np.abs(received) ** 2))
    iq = np.empty(2 * count)
    iq[0::2], iq[1::2] = received.real * scale + 127.5, received.imag * scale + 127.5
    np.clip(np.round(iq), 0, 255).astype(np.uint8).tofile(args.output)
    print(f"{args.output}: {count} samples ({count / args.rate:.1f} s), {len(cadus) // 1024} frames, {args.mode}"
          f"{' interleaved' if args.interleave else ''} at {symbol_rate:.0f} sym/s, Es/N0 {args.esn0} dB, "
          f"carrier {args.offset}±{args.doppler / 2} Hz")


if __name__ == "__main__":
    main()
