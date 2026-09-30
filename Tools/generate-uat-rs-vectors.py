#!/usr/bin/env python3
# usage: generate-uat-rs-vectors.py > vectors.txt   (needs reedsolo, and karn_decode built from dump978's fec/ in a chroot)
# Dev-time: Reed-Solomon vectors for the three UAT codes. Parity from reedsolo; corrupted words decoded by Karn's
# decoder (compiled from dump978's copy) to give the expected outcome.
import random, subprocess, sys
from reedsolo import RSCodec
random.seed(11)
codes = [(30, 12), (48, 14), (92, 20)]
lines, cases = [], []
for n, nroots in codes:
    rsc = RSCodec(nroots, nsize=255, fcr=120, prim=0x187, generator=2, c_exp=8)
    k = n - nroots
    for trial in range(60):
        data = bytes(random.getrandbits(8) for _ in range(k))
        word = bytes(rsc.encode(data))
        assert len(word) == n
        errors = trial % (nroots // 2 + 4)
        bad = bytearray(word)
        for pos in random.sample(range(n), errors):
            bad[pos] ^= random.randrange(1, 256)
        lines.append('%d %d %s' % (nroots, 255 - n, bad.hex()))
        cases.append((n, nroots, word.hex(), bad.hex(), errors))
out = subprocess.run(['chroot', '/opt/questing', '/oracles/karn_decode'], input='\n'.join(lines) + '\n',
                     capture_output=True, text=True).stdout.split('\n')
print('# Reed-Solomon cases for the UAT codes (GF(2^8) poly 0x187, first root 120). Clean codewords from reedsolo 1.x;')
print('# the corrupted word decoded by Phil Karn\'s decoder as dump978 uses it.')
print('# Columns: length parityCount clean corrupted errorsInjected karnCount karnResult')
for (n, nroots, clean, bad, errors), result in zip(cases, out):
    count, fixed = result.split()
    print(n, nroots, clean, bad, errors, count, fixed)
