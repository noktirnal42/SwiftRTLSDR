#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Runs rs1729's imet1rs_dft and `rtlsdr-tool sonde --type imet` on the signals imet-oracle.py makes, and checks both
against what was sent.

usage: imet-compare.py IMET1RS_DFT RTLSDR-TOOL WORKDIR [--cnr 20,14,12,10] [--offset 3000] [--seconds 30] [--baud 1200]
                       [--deviation 3000] [--extended] [--xdata] [--seeds 1,2,3]

For each carrier-to-noise ratio (and seed) it makes OUT.u8 and OUT-fm.wav, decodes the audio with imet1rs_dft (--json) and
the I/Q with this package starting blind, and prints, per decoder, how many of the frames sent came out, how many reports
disagree with what was sent (wrong ones), and how many reports the two give alike. Position fields are compared to the 5
decimals the JSON has, the rest exactly. Needs numpy and scipy.
"""
import argparse
import json
import os
import subprocess
import sys

CLOSE = {"lat": 1.5e-5, "lon": 1.5e-5, "pressure": 0.011, "temp": 0.011, "humidity": 0.011, "batt": 0.051}
EXACT = ["id", "datetime", "alt", "sats", "ref_datetime", "ref_position", "aux"]


def reports(command, stdin=None):
    out = subprocess.run(command, capture_output=True, text=True).stdout
    result = {}
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("{"):
            record = json.loads(line)
            result[record["frame"]] = record
    return result


def wrong_fields(record, truth):
    problems = []
    for key, tolerance in CLOSE.items():
        if abs(record[key] - truth[key]) > tolerance:
            problems.append(f"{key} {record[key]} sent {truth[key]}")
    if record["datetime"] != truth["datetime"] + "Z":
        problems.append(f"datetime {record['datetime']} sent {truth['datetime']}")
    for key in ("alt", "sats"):
        if record[key] != truth[key]:
            problems.append(f"{key} {record[key]} sent {truth[key]}")
    if record.get("aux") != truth.get("aux"):
        problems.append(f"aux {record.get('aux')} sent {truth.get('aux')}")
    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("oracle")
    parser.add_argument("tool")
    parser.add_argument("work")
    parser.add_argument("--cnr", default="20,14,12,10")
    parser.add_argument("--offset", type=float, default=3000)
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--baud", type=float, default=1200)
    parser.add_argument("--deviation", type=float, default=3000)
    parser.add_argument("--extended", action="store_true")
    parser.add_argument("--xdata", action="store_true")
    parser.add_argument("--seeds", default="1")
    args = parser.parse_args()
    os.makedirs(args.work, exist_ok=True)
    here = os.path.dirname(os.path.abspath(__file__))
    rate = 240000
    bad = 0
    print(f"iMet {args.seconds} s at {args.baud:.0f} baud, deviation {args.deviation:.0f} Hz, carrier {args.offset:+.0f} Hz"
          f"{', extended packets' if args.extended else ''}{', XDATA' if args.xdata else ''}")
    print(f"{'CNR':>6} {'seed':>4} {'sent':>5} | {'ours':>5} {'wrong':>5} | {'imet1rs_dft':>11} {'wrong':>5} | {'ours=oracle':>11}")
    for cnr in [float(x) for x in args.cnr.split(",")]:
        for seed in [int(x) for x in args.seeds.split(",")]:
            prefix = os.path.join(args.work, f"imet-{cnr:g}-{seed}")
            command = [sys.executable, os.path.join(here, "imet-oracle.py"), prefix, "--seconds", str(args.seconds), "--cnr", str(cnr),
                       "--offset", str(args.offset), "--seed", str(seed), "--baud", str(args.baud), "--deviation", str(args.deviation),
                       "--rate", str(rate)]
            subprocess.run(command + (["--extended"] if args.extended else []) + (["--xdata"] if args.xdata else []), check=True,
                           capture_output=True)
            truth = {t["frame"]: t for t in json.load(open(prefix + ".truth.json"))}
            ours = reports([args.tool, "sonde", "--type", "imet", "--ifile", prefix + ".u8", "--rate", str(rate), "--offset", str(args.offset),
                            "--json"])
            theirs = reports([args.oracle, "--json", prefix + "-fm.wav"])
            wrong_ours = wrong_theirs = alike = 0
            for label, found in (("ours", ours), ("imet1rs_dft", theirs)):
                for frame, record in found.items():
                    problems = wrong_fields(record, truth[frame]) if frame in truth else ["not a frame that was sent"]
                    if problems:
                        if label == "ours":
                            wrong_ours += 1
                        else:
                            wrong_theirs += 1
                        for problem in problems[:3]:
                            print(f"    {label} frame {frame}: {problem}")
            for frame in set(ours) & set(theirs):
                a, b = ours[frame], theirs[frame]
                if all(a.get(k) == b.get(k) for k in EXACT) and all(abs(a[k] - b[k]) <= t for k, t in CLOSE.items()):
                    alike += 1
            print(f"{cnr:6g} {seed:4d} {len(truth):5d} | {len(set(ours) & set(truth)):5d} {wrong_ours:5d} | "
                  f"{len(set(theirs) & set(truth)):11d} {wrong_theirs:5d} | {alike:11d}")
            bad += wrong_ours
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
