#!/usr/bin/env python3
# usage: uat-oracle.py <seed> <output directory> <dump978 sample-data.txt>   (needs numpy, reedsolo)
# Writes uat.u8 (2.083334 MS/s; feed to dump978 on stdin and to rtlsdr-tool uat --ifile) and uat-truth.txt.
# Dev-time oracle check for UAT demodulation: real frames (dump978's sample data), parity from reedsolo, modulated
# as continuous-phase FSK (h = 0.6) with random timing, carrier phase and frequency offset, at several noise levels.
import sys, random, math
import numpy as np
from reedsolo import RSCodec
random.seed(int(sys.argv[1])); rng = np.random.default_rng(int(sys.argv[1]))
out = sys.argv[2]
frames = [l.strip() for l in open(sys.argv[3]) if l[:1] in '+-']
basic = RSCodec(12, nsize=255, fcr=120, prim=0x187, generator=2, c_exp=8)
long_ = RSCodec(14, nsize=255, fcr=120, prim=0x187, generator=2, c_exp=8)
up = RSCodec(20, nsize=255, fcr=120, prim=0x187, generator=2, c_exp=8)
def transmitted(line):
    payload = bytes.fromhex(line[1:].split(';')[0])
    if line[0] == '-':
        sync = 0xEACDDA4E2
        word = bytes((basic if len(payload) == 18 else long_).encode(payload))
    else:
        sync = 0x153225B1D
        blocks = [bytes(up.encode(payload[72 * b:72 * (b + 1)])) for b in range(6)]
        word = bytes(blocks[i % 6][i // 6] for i in range(552))
    bits = [(sync >> (35 - i)) & 1 for i in range(36)]
    for byte in word: bits += [(byte >> (7 - k)) & 1 for k in range(8)]
    return payload.hex(), line[0], bits
rate = 2083334.0
bitrate = rate / 2
chosen = random.sample(frames, 300)
levels = [3, 6, 10, 14, 18]          # noise standard deviation in ADC codes; signal amplitude 50
plan = []
t = 1000
for i, line in enumerate(chosen):
    payload, kind, bits = transmitted(line)
    plan.append((t, payload, kind, bits, levels[i % len(levels)]))
    t += int(len(bits) * 2 + 800 + random.random() * 3000)
n = t + 20000
sig = np.zeros(n, dtype=complex)
noise_level = np.zeros(n)
for start, payload, kind, bits, level in plan:
    tau = random.random()                                   # timing within a sample
    offset = random.uniform(-40e3, 40e3)
    phase0 = random.random() * 2 * math.pi
    count = len(bits) * 2
    k = np.arange(count)
    t_bits = (k + tau) / 2.0                                # position in bits
    idx = np.minimum(np.floor(t_bits).astype(int), len(bits) - 1)
    sym = np.where(np.array(bits)[idx] == 1, 1.0, -1.0)
    # Continuous phase: integrate ±0.6π per bit.
    cum = np.concatenate([[0.0], np.cumsum(np.where(np.array(bits) == 1, 1.0, -1.0))])
    phase = 0.6 * math.pi * (cum[idx] + (t_bits - idx) * sym) + 2 * math.pi * offset * k / rate + phase0
    sig[start:start + count] += 50 * np.exp(1j * phase)
    noise_level[start - 400:start + count + 400] = level
noise_level[noise_level == 0] = 3
i = 127.5 + sig.real + rng.normal(0, 1, n) * noise_level
q = 127.5 + sig.imag + rng.normal(0, 1, n) * noise_level
iq = np.empty(2 * n); iq[0::2] = i; iq[1::2] = q
np.clip(np.round(iq), 0, 255).astype(np.uint8).tofile(out + '/uat.u8')
with open(out + '/uat-truth.txt', 'w') as f:
    for start, payload, kind, bits, level in plan: f.write('%s%s %d\n' % (kind, payload, level))
print(len(plan), 'frames,', n, 'samples')
