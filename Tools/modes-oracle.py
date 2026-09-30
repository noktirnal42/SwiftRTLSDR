#!/usr/bin/env python3
# usage: modes-oracle.py <seed> <output directory>   (needs numpy)
# Writes modes-2000.u8 (for rtlsdr-tool adsb --ifile), modes-2400.u8 (for dump1090 --ifile) and modes-truth.txt.
# Dev-time oracle check: the same Mode S frames rendered at 2.0 and 2.4 MS/s from a continuous-time pulse model.
import random, math, struct, sys
import numpy as np
G = 0x1FFF409
def crc(v, nbits):
    r = v << 24
    for i in range(nbits + 23, 23, -1):
        if r & (1 << i): r ^= G << (i - 24)
    return r & 0xFFFFFF
def df17(icao):
    me = random.getrandbits(56)
    tc = random.choice([1, 4, 11, 12, 19, 13, 20])
    me = (me & ((1 << 51) - 1)) | (tc << 51)
    head = (17 << 83) | (5 << 80) | (icao << 56) | me
    return (head << 24 | crc(head, 88)).to_bytes(14, 'big')
def df11(icao):
    head = (11 << 27) | (5 << 24) | icao
    return (head << 24 | crc(head, 32)).to_bytes(7, 'big')
def df4(icao):
    head = (4 << 27) | (random.getrandbits(8) << 13) | (random.getrandbits(13) & ~0x40 | 0x10)
    return (head << 24 | (crc(head, 32) ^ icao)).to_bytes(7, 'big')
random.seed(int(sys.argv[1]) if len(sys.argv) > 1 else 7)
duration = 6e-3 * 400           # 2.4 s
frames = []
t = 1e-3
icaos = [random.getrandbits(24) for _ in range(40)]
while t < duration - 1e-3:
    icao = random.choice(icaos)
    kind = random.random()
    msg = df17(icao) if kind < 0.7 else df11(icao) if kind < 0.85 else df4(icao)
    amp = random.choice([80, 40, 20, 12, 8, 6])
    frames.append((t, msg, amp))
    t += 150e-6 + random.random() * 3e-3
def render(rate, path, noise=2.5, seed=1):
    rng = np.random.default_rng(seed)
    n = int(duration * rate)
    sig = np.zeros(n, dtype=complex)
    for t0, msg, amp in frames:
        phase = random.Random(hash((t0, amp))).random() * 2 * math.pi
        pulses = [0, 1.0, 3.5, 4.5]
        for bit in range(len(msg) * 8):
            one = (msg[bit // 8] >> (7 - bit % 8)) & 1
            pulses.append(8 + bit + (0 if one else 0.5))
        for p in pulses:
            a, b = (t0 + p * 1e-6) * rate, (t0 + (p + 0.5) * 1e-6) * rate   # pulse edges in samples
            for k in range(int(math.floor(a)), int(math.ceil(b))):
                overlap = min(b, k + 1) - max(a, k)
                if overlap > 0: sig[k] += amp * overlap * math.e ** (1j * phase)
    i = 127.5 + sig.real + rng.normal(0, noise, n)
    q = 127.5 + sig.imag + rng.normal(0, noise, n)
    iq = np.empty(2 * n); iq[0::2] = i; iq[1::2] = q
    np.clip(np.round(iq), 0, 255).astype(np.uint8).tofile(path)
render(2_000_000, sys.argv[2] + '/modes-2000.u8')
render(2_400_000, sys.argv[2] + '/modes-2400.u8')
with open(sys.argv[2] + '/modes-truth.txt', 'w') as f:
    for t0, msg, amp in frames: f.write('%s %d\n' % (msg.hex().upper(), amp))
print(len(frames), 'frames')
