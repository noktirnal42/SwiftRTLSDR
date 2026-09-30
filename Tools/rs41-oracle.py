#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Makes an RS41 radiosonde signal from frames, independently of this package's code, as u8 I/Q and as an I/Q WAV.

usage: rs41-oracle.py FRAMES.txt OUT [--rate 240000] [--ebn0 12] [--offset 3000] [--deviation 2400] [--bt 0.5]
                      [--seed 1] [--drift 0]

FRAMES.txt: one dewhitened frame per line in hex, as `rs41mod -r` prints them (anything after the hex is ignored).
Each frame is whitened with the RS41 sequence, sent least significant bit first at 4800 bit/s, one frame a second
(random bits fill the rest of each second), Gaussian-filtered (BT 0.5) and frequency-modulated (±2.4 kHz), with a
carrier offset (drifting by --drift Hz over the recording), a random phase and complex Gaussian noise for the Eb/N0
asked for. Writes OUT.u8 (for `rtlsdr-tool sonde --ifile`) and OUT.wav (16-bit stereo I/Q, for rs41mod --IQ). Needs
numpy.
"""
import argparse
import wave
import numpy as np

WHITENING = bytes.fromhex(
    "96833e51b1490898320559 0ef944c626 2160c2ea795d6da1 5469470cdce85cf1"
    "f776827f0799a22c 937c3063f5102e61 d0bcb4b606aaf423 786e3baebf7b4cc1".replace(" ", ""))
BAUD = 4800


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("frames")
    parser.add_argument("output")
    parser.add_argument("--rate", type=float, default=240000)
    parser.add_argument("--ebn0", type=float, default=12)
    parser.add_argument("--offset", type=float, default=3000)
    parser.add_argument("--drift", type=float, default=0)
    parser.add_argument("--deviation", type=float, default=2400)
    parser.add_argument("--bt", type=float, default=0.5)
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    assert len(WHITENING) == 64
    rng = np.random.default_rng(args.seed)

    frames = []
    for line in open(args.frames):
        word = line.split()[0] if line.split() else ""
        if len(word) >= 640 and all(c in "0123456789abcdefABCDEF" for c in word):
            frames.append(bytes.fromhex(word[:len(word) // 2 * 2]))
    bits = []
    lead = rng.integers(0, 2, int(0.37 * BAUD))                    # the recording starts partway through a second
    bits.extend(lead)
    for frame in frames:
        sent = bytes(b ^ WHITENING[i % 64] for i, b in enumerate(frame))
        frame_bits = np.unpackbits(np.frombuffer(sent, dtype=np.uint8), bitorder="little")
        bits.extend(frame_bits)
        bits.extend(rng.integers(0, 2, BAUD - len(frame_bits)))
    symbols = 2.0 * np.array(bits, dtype=np.float64) - 1

    sps = args.rate / BAUD
    count = int(len(symbols) * sps)
    t = np.arange(count) / args.rate
    nrz = symbols[np.minimum((np.arange(count) / sps).astype(np.int64), len(symbols) - 1)]
    # Gaussian pulse shaping: sigma in samples for a bandwidth-time product BT
    sigma = np.sqrt(np.log(2)) / (2 * np.pi * args.bt) * sps
    half = int(4 * sigma)
    kernel = np.exp(-0.5 * (np.arange(-half, half + 1) / sigma) ** 2)
    kernel /= kernel.sum()
    shaped = np.convolve(nrz, kernel, mode="same")
    frequency = args.offset + args.drift * (t / t[-1] - 0.5) + args.deviation * shaped
    phase = 2 * np.pi * np.cumsum(frequency) / args.rate + rng.uniform(0, 2 * np.pi)
    signal = np.exp(1j * phase)
    n0 = 1.0 / BAUD / 10 ** (args.ebn0 / 10)                       # Eb = P/baud with P = 1
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
    print(f"{args.output}: {len(frames)} frames, {count / args.rate:.1f} s at {args.rate:.0f} S/s, Eb/N0 {args.ebn0} dB, "
          f"carrier {args.offset:+.0f} Hz")


if __name__ == "__main__":
    main()
