#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Makes ACARS test signals: random messages as an aircraft or a ground station would send them, independently of this
package's code.

usage: acars-oracle.py OUT [--messages 20] [--channels 131.55e6,131.125e6,130.45e6] [--center auto] [--rate 2400000]
                           [--snr 20] [--audio-snr 20] [--seed 1]

Each message is framed as ARINC 618 has it (pre-key of ones, "+*", SYN SYN SOH, header, STX, text, ETX, CRC-16/CCITT
reflected, DEL; 7-bit characters with odd parity, least significant bit first) and sent as 2400 bit/s MSK: offset QPSK
with half-sine pulses two bits long on a reference at 1800 Hz, the pulse signs turning every second bit, the reference
tied to the bit timing. Writes OUT.wav (12.5 kHz, one audio channel per ACARS channel, as acarsdec's test file is laid
out: noise for --audio-snr dB, MSK power over the noise in 0-6.25 kHz), OUT.u8 (u8 I/Q at --rate: each channel AM
modulated at depth 0.6 while it transmits, noise for --snr dB of carrier over the noise in 12.5 kHz) and OUT.txt (the
messages, one per line: channel, registration, label, block, message number, flight, text). Needs numpy.
"""
import argparse
import numpy as np

T = 1 / 2400


def with_parity(c):
    c &= 0x7F
    return c | (0x80 if bin(c).count("1") % 2 == 0 else 0)


def crc(data):
    value = 0
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = (value >> 1) ^ 0x8408 if value & 1 else value >> 1
    return value


def frame(registration, label, block, number, flight, text, mode="2", ack=0x15):
    header = [ord(mode)] + list(registration.rjust(7, ".").encode()[:7]) + [ack] + list(label.encode()) + [ord(block)]
    body = list((number + flight + text).encode()) if (number or flight or text) else []
    chars = [with_parity(c) for c in header]
    if body:
        chars += [with_parity(0x02)] + [with_parity(c) for c in body]
    chars.append(0x83)                                           # ETX with its parity bit
    check = crc(chars)
    return [0xFF] * 16 + [with_parity(0x2B), with_parity(0x2A), 0x16, 0x16, 0x01] + chars + [check & 0xFF, check >> 8, 0x7F]


def bits_of(data):
    return [(byte >> i) & 1 for byte in data for i in range(8)]  # least significant bit first


def msk(bits, rate, start):
    """Audio of the MSK burst from `start` seconds, at `rate`: Re{s(u) e^(j 2π 1800 u)}, u = t − start."""
    n = int((len(bits) + 2) * T * rate) + 1
    u = np.arange(n) / rate
    s = np.zeros(n, dtype=complex)
    for k, bit in enumerate(bits):
        a = (1.0 if bit else -1.0) * (1.0 if k % 4 < 2 else -1.0)
        lo, hi = int(np.ceil(k * T * rate)), int(np.ceil((k + 2) * T * rate))
        seg = u[lo:hi]
        pulse = a * np.sin(np.pi * (seg - k * T) / (2 * T))
        s[lo:hi] += pulse if k % 2 == 0 else 1j * pulse
    return np.real(s * np.exp(2j * np.pi * 1800 * u))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    parser.add_argument("--messages", type=int, default=20)
    parser.add_argument("--channels", default="131.55e6,131.125e6,130.45e6")
    parser.add_argument("--center", default="auto")
    parser.add_argument("--rate", type=float, default=2_400_000)
    parser.add_argument("--snr", type=float, default=20)
    parser.add_argument("--audio-snr", type=float, default=20)
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    rng = np.random.default_rng(args.seed)
    channels = [float(x) for x in args.channels.split(",")]
    center = (min(channels) + max(channels)) / 2 + 12_500 if args.center == "auto" else float(args.center)

    labels = ["H1", "Q0", "5V", "SA", "10", "_\x7f", "B9", "80", "RA"]
    plan = [[] for _ in channels]                                # per channel: (start, bits, line)
    times = [0.3] * len(channels)
    for m in range(args.messages):
        c = m % len(channels)
        reg = rng.choice(["N%d%s" % (rng.integers(100, 999), "".join(rng.choice(list("ABCDEFGHJKLMNPRSTUVWXYZ"), 2))),
                          "G-" + "".join(rng.choice(list("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), 4))])
        label = str(rng.choice(labels))
        down = rng.random() < 0.7
        block = str(rng.integers(0, 10)) if down else chr(ord("A") + int(rng.integers(0, 26)))
        number = "M%02d%s" % (rng.integers(0, 100), "ABC"[int(rng.integers(0, 3))]) if down else ""
        flight = "%s%04d" % (rng.choice(["BA", "UA", "KL", "DL"]), rng.integers(0, 10000)) if down else ""
        length = int(rng.integers(0, 200))
        text = "".join(chr(int(x)) for x in rng.integers(0x20, 0x7F, length)) if length else ""
        if label == "_\x7f":
            number = flight = text = ""
        bits = bits_of(frame(reg, label, block, number, flight, text))
        start = times[c] + rng.uniform(0, 0.02)
        plan[c].append((start, bits, f"{c}\t{reg}\t{label.replace(chr(127), 'd')}\t{block}\t{number}\t{flight}\t{text}"))
        times[c] = start + len(bits) * T + rng.uniform(0.15, 0.6)
    duration = max(times) + 0.3

    # Audio: 12.5 kHz, a channel each.
    audio_rate = 12_500
    audio = np.zeros((int(duration * audio_rate), len(channels)))
    for c, entries in enumerate(plan):
        for start, bits, _ in entries:
            burst = msk(bits, audio_rate, 0)
            i0 = int(start * audio_rate)
            audio[i0:i0 + len(burst), c] += burst[:len(audio) - i0]
    power = 0.5                                                  # of the unit-amplitude MSK tone
    audio += rng.normal(0, np.sqrt(power / 10 ** (args.audio_snr / 10)), audio.shape)
    pcm = np.clip(np.round(audio / np.max(np.abs(audio)) * 30000), -32768, 32767).astype("<i2")
    with open(args.output + ".wav", "wb") as out:
        data = pcm.tobytes()
        nch = len(channels)
        out.write(b"RIFF" + (36 + len(data)).to_bytes(4, "little") + b"WAVEfmt " + (16).to_bytes(4, "little"))
        out.write((1).to_bytes(2, "little") + nch.to_bytes(2, "little") + audio_rate.to_bytes(4, "little"))
        out.write((audio_rate * 2 * nch).to_bytes(4, "little") + (2 * nch).to_bytes(2, "little") + (16).to_bytes(2, "little"))
        out.write(b"data" + len(data).to_bytes(4, "little") + data)

    # I/Q: each channel AM-modulated while it transmits (carrier keyed 50 ms early).
    rate = args.rate
    n = int(duration * rate)
    iq = np.zeros(n, dtype=complex)
    t = np.arange(n) / rate
    for c, entries in enumerate(plan):
        envelope = np.zeros(n)
        for start, bits, _ in entries:
            burst = msk(bits, rate, 0)
            i0 = int(start * rate)
            on = slice(max(0, i0 - int(0.05 * rate)), min(n, i0 + len(burst) + int(0.01 * rate)))
            envelope[on] += 1
            envelope[i0:i0 + len(burst)] += 0.6 * burst[:n - i0]
        iq += envelope * np.exp(2j * np.pi * (channels[c] - center) * t + 1j * rng.uniform(0, 2 * np.pi))
    sigma2 = rate / 12_500 * 10 ** (-args.snr / 10)              # carrier power 1, noise over 12.5 kHz
    iq += rng.normal(0, np.sqrt(sigma2 / 2), n) + 1j * rng.normal(0, np.sqrt(sigma2 / 2), n)
    scale = 40 / np.sqrt(np.mean(np.abs(iq) ** 2))
    out = np.empty(2 * n)
    out[0::2], out[1::2] = iq.real * scale + 127.5, iq.imag * scale + 127.5
    np.clip(np.round(out), 0, 255).astype(np.uint8).tofile(args.output + ".u8")

    with open(args.output + ".txt", "w") as out:
        for entries in plan:
            for _, _, line in entries:
                out.write(line + "\n")
    print(f"{args.output}: {args.messages} messages on {len(channels)} channels, {duration:.1f} s; tuned {center:.0f} Hz at "
          f"{rate:.0f} S/s (SNR {args.snr} dB), audio {audio_rate} Hz (SNR {args.audio_snr} dB)")


if __name__ == "__main__":
    main()
