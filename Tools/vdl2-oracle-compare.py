#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Compares `rtlsdr-tool vdl2` with dumpvdl2 on the same signals from Tools/vdl2-oracle.py, across Eb/N0.

usage: vdl2-oracle-compare.py RTLSDR-TOOL DUMPVDL2 WORKDIR [--ebn0=20,14,12,10,9,8] [--bursts 60] [--offset 0] [--ppm 0]
                              [--seed 1] [--keep]

Both decoders read the same u8 I/Q at 1.05 MS/s (dumpvdl2 --iq-file --oversample 10 --raw-frames; this package's
`vdl2 --ifile --raw`). A frame counts when every octet, FCS included, equals one that was sent on that channel.
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHANNELS = [136.975e6, 136.875e6, 136.775e6]
CENTER = (min(CHANNELS) + max(CHANNELS)) / 2 + 12_500


def sent(path):
    out = {}
    for line in open(path):
        c, burst, frame = line.split()
        out.setdefault((int(c), frame), int(burst))
    return out


def ours(text):
    found = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2 and re.fullmatch(r"[0-9a-f]+", parts[1]):
            found.append((CHANNELS.index(round(float(parts[0]) * 1e6, -3)), parts[1]))
    return found


def theirs(text):
    found, channel, octets = [], None, []
    for line in text.splitlines() + ["["]:
        if line.startswith("["):
            if channel is not None and octets:
                found.append((channel, "".join(octets)))
            m = re.match(r"\[[^]]*\] \[([0-9.]+)\]", line)
            channel = CHANNELS.index(round(float(m.group(1)) * 1e6, -3)) if m else None
            octets = []
        elif channel is not None and re.match(r"^ ([0-9a-f]{2} )", line):
            octets += re.findall(r"\b([0-9a-f]{2})\b", line.split("|")[0])
        elif line.strip() and channel is not None:
            found.append((channel, "".join(octets)))
            channel, octets = None, []
    return found


def main():
    p = argparse.ArgumentParser()
    p.add_argument("tool")
    p.add_argument("dumpvdl2")
    p.add_argument("workdir")
    p.add_argument("--ebn0", default="20,14,12,10,9,8")
    p.add_argument("--bursts", type=int, default=60)
    p.add_argument("--offset", type=float, default=0)
    p.add_argument("--ppm", type=float, default=0)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--keep", action="store_true")
    a = p.parse_args()
    os.makedirs(a.workdir, exist_ok=True)
    print(f"{a.bursts} bursts on {len(CHANNELS)} channels, carrier {a.offset:+g} Hz, clock {a.ppm:+g} ppm")
    print(f"{'Eb/N0':>6} {'frames':>7} {'ours':>6} {'dumpvdl2':>9}")
    for ebn0 in [float(x) for x in a.ebn0.split(",")]:
        base = os.path.join(a.workdir, f"vdl2-{ebn0:g}")
        subprocess.run([sys.executable, os.path.join(HERE, "vdl2-oracle.py"), base, "--bursts", str(a.bursts),
                        "--channels", ",".join(f"{c:.0f}" for c in CHANNELS), "--center", f"{CENTER:.0f}",
                        "--ebn0", str(ebn0), "--offset", str(a.offset), "--ppm", str(a.ppm), "--seed", str(a.seed)],
                       check=True, capture_output=True)
        truth = sent(base + ".txt")
        mine = ours(subprocess.run([a.tool, "vdl2", "--ifile", base + ".u8", "--rate", "1050000", "--center", f"{CENTER:.0f}",
                                    "--freq", ",".join(f"{c:.0f}" for c in CHANNELS), "--raw"],
                                   capture_output=True, text=True).stdout)
        other = theirs(subprocess.run([a.dumpvdl2, "--iq-file", base + ".u8", "--sample-format", "U8", "--oversample", "10",
                                       "--centerfreq", f"{CENTER:.0f}"] + [f"{c:.0f}" for c in CHANNELS] + ["--raw-frames"],
                                      capture_output=True, text=True).stdout)
        good_mine = {f for f in mine if f in truth}
        good_other = {f for f in other if f in truth}
        wrong = f"   (wrong: ours {sum(f not in truth for f in mine)}, dumpvdl2 {sum(f not in truth for f in other)})" \
            if any(f not in truth for f in mine + other) else ""
        print(f"{ebn0:>6g} {len(truth):>7} {len(good_mine):>6} {len(good_other):>9}{wrong}")
        if a.keep:
            missing = sorted({truth[f] for f in truth if f not in good_mine})
            print(f"        bursts this decoder missed: {missing}")
        else:
            for ext in (".u8", ".txt"):
                os.remove(base + ext)


if __name__ == "__main__":
    main()
