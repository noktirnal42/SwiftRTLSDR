#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Runs m10m20mod (rs1729's RS project) and `rtlsdr-tool sonde --type m10` on the signals m10-oracle.py makes, and checks
both against what was sent.

usage: m10-oracle-compare.py M10M20MOD RTLSDR-TOOL WORKDIR [--esn0 20,14,12,10] [--model m10] [--offset 3000]
                             [--drift 0] [--seconds 30] [--baud 9600] [--deviation 4320] [--invert] [--seeds 1,2,3]

For each Es/N0 (and seed) it makes OUT.u8, OUT.wav (I/Q) and OUT-fm.wav, decodes the I/Q with both programs
(m10m20mod --IQ FQ --lpIQ --json --ptu; this package starting blind) and prints, per decoder, how many of the frames
sent came out, how many reports disagree with what was sent (wrong ones), and how many reports the two give alike.
Position fields are compared to the 5 decimals the JSON has, temperature to 0.15 K (the sender interpolates the
thermistor table, the decoders use a fit of it), the rest exactly. Needs numpy.
"""
import argparse
import json
import os
import subprocess
import sys

CLOSE = {"lat": 1.5e-5, "lon": 1.5e-5, "alt": 1.5e-5, "vel_h": 1.5e-5, "heading": 1.5e-5, "vel_v": 1.5e-5, "batt": 0.011}
EXACT = ["id", "datetime", "sats", "aprsid", "rawid", "subtype", "gpsutc_leapsec", "ref_datetime"]


def reports(command):
    out = subprocess.run(command, capture_output=True, text=True).stdout
    result = {}
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("{"):
            record = json.loads(line)
            result[record["frame"]] = record
    return result


def wrong_fields(record, truth, check_frame=True):
    problems = []
    for key in ("lat", "lon", "alt", "vel_h", "vel_v", "heading", "batt"):
        tolerance = 0.011 if key == "batt" else 1.5e-5
        if abs(record[key] - truth[key]) > tolerance:
            problems.append(f"{key} {record[key]} sent {truth[key]}")
    if "temp" in record and abs(record["temp"] - truth["temp"]) > 0.15:
        problems.append(f"temp {record['temp']} sent {truth['temp']}")
    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("oracle")
    parser.add_argument("tool")
    parser.add_argument("work")
    parser.add_argument("--esn0", default="20,14,12,10")
    parser.add_argument("--model", default="m10")
    parser.add_argument("--offset", type=float, default=3000)
    parser.add_argument("--drift", type=float, default=0)
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--baud", type=float, default=9600)
    parser.add_argument("--deviation", type=float, default=4320)
    parser.add_argument("--invert", action="store_true")
    parser.add_argument("--seeds", default="1")
    args = parser.parse_args()
    os.makedirs(args.work, exist_ok=True)
    here = os.path.dirname(os.path.abspath(__file__))
    rate = 288000
    bad = 0
    print(f"{args.model} {args.seconds} s at {args.baud:.0f} symbols/s, deviation {args.deviation:.0f} Hz, carrier {args.offset:+.0f} Hz "
          f"drifting {args.drift:+.0f} Hz{', inverted' if args.invert else ''}")
    print(f"{'Es/N0':>6} {'seed':>4} {'sent':>5} | {'ours':>5} {'wrong':>5} | {'m10m20mod':>9} {'wrong':>5} | {'ours=oracle':>11}")
    for esn0 in [float(x) for x in args.esn0.split(",")]:
        for seed in [int(x) for x in args.seeds.split(",")]:
            prefix = os.path.join(args.work, f"{args.model}-{esn0:g}-{seed}")
            command = [sys.executable, os.path.join(here, "m10-oracle.py"), prefix, "--model", args.model, "--seconds",
                       str(args.seconds), "--esn0", str(esn0), "--offset", str(args.offset), "--drift", str(args.drift),
                       "--seed", str(seed), "--baud", str(args.baud), "--deviation", str(args.deviation), "--rate", str(rate)]
            subprocess.run(command + (["--invert"] if args.invert else []), check=True, capture_output=True)
            truth = {t["gps_seconds"]: t for t in json.load(open(prefix + ".truth.json"))}
            ours = reports([args.tool, "sonde", "--type", "m10", "--ifile", prefix + ".u8", "--rate", str(rate), "--offset", "0", "--json"])
            theirs = reports([args.oracle, "--IQ", str(args.offset / rate), "--lpIQ", "--json", "--ptu", prefix + ".wav"])
            wrong_ours = wrong_theirs = alike = 0
            # The M10+ sends UTC, so its frame number (the JSON's) is UTC seconds, 18 s behind the GPS seconds of the truth.
            shift = 18 if args.model == "m10plus" else 0
            for label, found in (("ours", ours), ("m10m20mod", theirs)):
                for frame, record in found.items():
                    if args.model == "m10plus" and label == "m10m20mod":
                        continue                                         # the oracle gives no frame number for these
                    key = frame + shift
                    problems = wrong_fields(record, truth[key]) if key in truth else ["not a frame that was sent"]
                    if problems:
                        if label == "ours":
                            wrong_ours += 1
                        else:
                            wrong_theirs += 1
                        for problem in problems[:3]:
                            print(f"    {label} frame {frame}: {problem}")
            for frame in set(ours) & set(theirs):
                a, b = ours[frame], theirs[frame]
                if all(a.get(k) == b.get(k) for k in EXACT) and all(abs(a[k] - b[k]) <= t for k, t in CLOSE.items()) and \
                        ("temp" in a) == ("temp" in b) and abs(a.get("temp", 0) - b.get("temp", 0)) <= 0.051:
                    alike += 1
            print(f"{esn0:6g} {seed:4d} {len(truth):5d} | {len({f + shift for f in ours} & set(truth)):5d} {wrong_ours:5d} | "
                  f"{len(set(theirs) & set(truth)):9d} {wrong_theirs:5d} | {alike:11d}")
            bad += wrong_ours
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
