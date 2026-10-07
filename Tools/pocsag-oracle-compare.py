#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Runs multimon-ng and `rtlsdr-tool pager` on the signals pocsag-oracle.py makes, and checks both against what was sent.

usage: pocsag-oracle-compare.py MULTIMON-NG RTLSDR-TOOL WORKDIR [--cnr 25,18,15,12,10] [--baud 1200] [--pages 24]
                                [--offset 3000] [--invert] [--seeds 1,2,3] [--cutoff 10000]

For each carrier-to-noise ratio (and seed) it makes OUT.u8 and OUT-fm.wav, decodes the I/Q with this package (starting blind),
and the FM audio (from a discriminator on the same noisy samples) with multimon-ng (default mode: function 0 is numeric, the
others alphanumeric) and with this package, and prints, per decoder, how many of the pages sent came out, how many pages
disagree with what was sent (wrong ones: an address that was sent with other text, or one that was not sent), and how many
pages the I/Q decode and multimon-ng give alike. Needs numpy and scipy.
"""
import argparse
import json
import os
import re
import subprocess
import sys

LINE = re.compile(r"POCSAG(\d+): Address:\s+(\d+)\s+Function: (\d)\s+(Alpha|Numeric):\s?(.*)$")


def clean(text):
    text = re.sub(r"(\s+\[\d+ (corrected|damaged)\])+$", "", text)         # this package's notes on repaired codewords
    return text.replace("<NUL>", "").replace("<EOT>", "").strip()


def multimon(binary, wav):
    out = subprocess.run([binary, "-t", "wav", "-a", "POCSAG512", "-a", "POCSAG1200", "-a", "POCSAG2400", wav], capture_output=True, text=True).stdout
    pages = {}
    for line in out.splitlines():
        m = LINE.match(line)
        if m:
            pages[int(m.group(2))] = (int(m.group(3)), clean(m.group(5)))
    return pages


def ours(command):
    out = subprocess.run(command, capture_output=True, text=True).stdout
    pages = {}
    for line in out.splitlines():
        m = LINE.match(line)
        if m:
            pages[int(m.group(2))] = (int(m.group(3)), clean(m.group(5)))
    return pages


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("oracle")
    parser.add_argument("tool")
    parser.add_argument("work")
    parser.add_argument("--cnr", default="25,18,15,12,10")
    parser.add_argument("--baud", type=float, default=1200)
    parser.add_argument("--pages", type=int, default=24)
    parser.add_argument("--offset", type=float, default=3000)
    parser.add_argument("--invert", action="store_true")
    parser.add_argument("--seeds", default="1,2,3")
    parser.add_argument("--cutoff", type=float, default=0)
    args = parser.parse_args()
    os.makedirs(args.work, exist_ok=True)
    here = os.path.dirname(os.path.abspath(__file__))
    bad = 0
    print(f"POCSAG {args.pages} pages at {args.baud:.0f} bit/s, carrier {args.offset:+.0f} Hz{', inverted' if args.invert else ''}")
    print(f"{'CNR':>6} {'seed':>4} {'sent':>5} | {'ours':>5} {'wrong':>5} | {'ours (audio)':>12} | {'multimon-ng':>11} {'wrong':>5} | {'I/Q=oracle':>10}")
    for cnr in [float(x) for x in args.cnr.split(",")]:
        for seed in [int(x) for x in args.seeds.split(",")]:
            prefix = os.path.join(args.work, f"pocsag-{args.baud:.0f}-{cnr:g}-{seed}")
            command = [sys.executable, os.path.join(here, "pocsag-oracle.py"), prefix, "--pages", str(args.pages), "--cnr", str(cnr),
                       "--baud", str(args.baud), "--offset", str(args.offset), "--seed", str(seed)]
            subprocess.run(command + (["--invert"] if args.invert else []), check=True, capture_output=True)
            truth = {}
            for p in json.load(open(prefix + ".truth.json")):
                truth[p["address"]] = (p["function"], p["text"].strip())
            iq = [args.tool, "pager", "--ifile", prefix + ".u8", "--rate", "240000", "--offset", str(args.offset)]
            if args.cutoff:
                iq += ["--cutoff", str(args.cutoff)]
            mine = ours(iq)
            audio = ours([args.tool, "pager", "--wav", prefix + "-fm.wav"])
            theirs = multimon(args.oracle, prefix + "-fm.wav")
            wrong_ours = sum(1 for a, v in mine.items() if truth.get(a) != v)
            wrong_theirs = sum(1 for a, v in theirs.items() if truth.get(a) != v)
            for label, found in (("ours", mine), ("multimon-ng", theirs)):
                for a, v in found.items():
                    if truth.get(a) != v:
                        print(f"    {label} {a}: {v} sent {truth.get(a)}")
            alike = sum(1 for a in set(mine) & set(theirs) if mine[a] == theirs[a])
            good = lambda found: sum(1 for a, v in found.items() if truth.get(a) == v)
            print(f"{cnr:6g} {seed:4d} {len(truth):5d} | {good(mine):5d} {wrong_ours:5d} | {good(audio):12d} | {good(theirs):11d} {wrong_theirs:5d} | {alike:10d}")
            bad += wrong_ours
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
