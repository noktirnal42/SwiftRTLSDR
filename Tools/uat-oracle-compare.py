#!/usr/bin/env python3
# Compares dump978 and rtlsdr-tool uat --raw output with the ground truth written by uat-oracle.py.
# usage: uat-oracle-compare.py <directory with uat-truth.txt, dump978.txt, ours.txt>
import collections, sys
D = sys.argv[1]
truth = [l.split() for l in open(D + '/uat-truth.txt')]
def load(p): return collections.Counter(l.strip().split(';')[0].lower() for l in open(p) if l[:1] in '+-')
d, o = load(D + '/dump978.txt'), load(D + '/ours.txt')
t = collections.Counter(k.lower() for k, _ in truth)
print('truth', len(truth), 'dump978', sum(d.values()), 'ours', sum(o.values()))
print('not in truth: dump978', sum((d - t).values()), 'ours', sum((o - t).values()))
print('identical output sets:', d == o)
for name, c0 in (('dump978', d), ('ours', o)):
    c = collections.Counter(c0); rates = collections.defaultdict(lambda: [0, 0])
    for k, level in truth:
        key = (k[0], int(level)); rates[key][1] += 1
        if c[k.lower()] > 0: rates[key][0] += 1; c[k.lower()] -= 1
    print('%-8s' % name, '  '.join('%s%d:%d/%d' % (kind, lv, v[0], v[1]) for (kind, lv), v in sorted(rates.items())))
