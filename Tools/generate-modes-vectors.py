#!/usr/bin/env python3
# usage: generate-modes-vectors.py > vectors.txt   (needs pyModeS 3)
# Dev-time helper: builds Mode S surveillance replies with correct address/parity and records what pyModeS decodes.
import random, pyModeS as pms
G = 0x1FFF409
def crc(bits_int, nbits):
    # remainder of (message << 24) mod G
    r = bits_int << 24
    for i in range(nbits + 24 - 1, 23, -1):
        if r & (1 << i):
            r ^= G << (i - 24)
    return r & 0xFFFFFF
def reply(df, field13, icao, fs=0, dr=0, um=0):
    head = (df << 27) | (fs << 24) | (dr << 19) | (um << 13) | field13
    ap = crc(head, 32) ^ icao
    return '%08X%06X' % (head, ap)
random.seed(4)
icao = 0x4840D6
rows = []
codes = set()
# Q-bit codes (M=0, Q=1), Gillham codes (M=0, Q=0, valid C states), plus some edge cases.
while len(codes) < 30:
    code = random.getrandbits(13) & ~0x40
    code |= 0x10
    codes.add(code)
cstates = [0b001, 0b011, 0b010, 0b110, 0b100]
while len(codes) < 70:
    code = random.getrandbits(13) & ~0x40 & ~0x10
    c = random.choice(cstates)
    # C1 at bit 12, C2 at bit 10, C4 at bit 8 of the 13-bit field
    code = (code & ~((1 << 12) | (1 << 10) | (1 << 8))) | ((c >> 2 & 1) << 12) | ((c >> 1 & 1) << 10) | ((c & 1) << 8)
    codes.add(code)
for code in sorted(codes):
    msg = reply(4, code, icao)
    d = dict(pms.decode(msg))
    rows.append(('alt', msg, code, d.get('altitude'), d.get('icao')))
for _ in range(20):
    code = random.getrandbits(13) & ~0x40
    msg = reply(5, code, icao)
    d = dict(pms.decode(msg))
    rows.append(('id', msg, code, d.get('squawk'), d.get('icao')))
for kind, msg, code, value, ic in rows:
    print(kind, msg, code, value, ic)
