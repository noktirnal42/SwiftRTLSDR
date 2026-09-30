#!/usr/bin/env python3
# Compares dump1090 and rtlsdr-tool adsb output (AVR lines) with the ground truth written by modes-oracle.py.
# usage: modes-oracle-compare.py <directory with modes-truth.txt, dump1090.txt, ours.txt>
import collections, sys
D = sys.argv[1]
truth = [l.split() for l in open(D + '/modes-truth.txt')]
def load(p): return collections.Counter(l.strip().strip('*;').upper() for l in open(p) if l.startswith('*'))
d, o = load(D + '/dump1090.txt'), load(D + '/ours.txt')
tset = collections.Counter(m for m, a in truth)
print('truth', len(truth), 'dump1090', sum(d.values()), 'ours', sum(o.values()))
print('not in truth: dump1090', sum((d - tset).values()), 'ours', sum((o - tset).values()))
for kind, c0 in (('dump1090', d), ('ours', o)):
    c = collections.Counter(c0); rates = collections.defaultdict(lambda: [0, 0])
    for m, a in truth:
        rates[int(a)][1] += 1
        if c[m] > 0: rates[int(a)][0] += 1; c[m] -= 1
    print('%-9s' % kind, '  '.join('%d:%d/%d' % (a, v[0], v[1]) for a, v in sorted(rates.items(), reverse=True)))
