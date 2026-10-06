#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Runs dfm09mod (rs1729's RS project) and `rtlsdr-tool sonde --type dfm` on the signals dfm-oracle.py makes, and checks
both against what was sent.

usage: dfm-oracle-compare.py DFM09MOD RTLSDR-TOOL WORKDIR [--esn0 20,14,12,10] [--model dfm09] [--offset 3000]
                             [--drift 0] [--seconds 40] [--serial N] [--invert] [--seeds 1,2,3]

For each Es/N0 (and seed) it makes OUT.u8, OUT.wav (I/Q) and OUT-fm.wav (FM audio), decodes the I/Q with both programs
(dfm09mod --IQ FQ --lpIQ --ecc --ptu --json; this package starting blind) and prints, per decoder, how many of the
seconds sent came out, how many reports disagree with what was sent (wrong ones), and how many frames the two give
alike. Position fields are compared to the 5 decimals the JSON has, temperature to 0.5 K (the channel it comes from can be seconds old at a low signal level) (the sender interpolates the thermistor table, the decoders use a fit of it), everything else exactly. Needs numpy.
"""
import argparse
import json
import os
import subprocess
import sys

TEXT = ["datetime"]
EXACT = ["sats"]
CLOSE = {"lat": 1.5e-5, "lon": 1.5e-5, "alt": 1.5e-5, "vel_h": 1.5e-5, "heading": 1.5e-5, "vel_v": 1.5e-5}


def reports(command):
    out = subprocess.run(command, capture_output=True, text=True).stdout
    result = {}
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("{"):
            record = json.loads(line)
            result[record["frame"]] = record
    return result


def wrong_fields(record, truth, serial_known=True):
    """The fields of a report that differ from what was sent."""
    problems = []
    for key in TEXT + EXACT:
        sent = {"datetime": "%04d-%02d-%02dT%02d:%02d:%06.3fZ" % (truth["year"], truth["month"], truth["day"], truth["hour"],
                                                                  truth["minute"], truth["second"])}.get(key, truth.get(key))
        if record.get(key) != sent:
            problems.append(f"{key} {record.get(key)!r} sent {sent!r}")
    for key, tolerance in CLOSE.items():
        if abs(record[key] - truth[key]) > tolerance:
            problems.append(f"{key} {record[key]} sent {truth[key]}")
    if record["id"] != "DFM-xxxxxxxx" and record["id"] != "DFM-" + truth["serial"]:
        problems.append(f"id {record['id']} sent {truth['serial']}")
    if "temp" in record and abs(record["temp"] - truth["temp"]) > 0.5:
        problems.append(f"temp {record['temp']} sent {truth['temp']}")
    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("oracle")
    parser.add_argument("tool")
    parser.add_argument("work")
    parser.add_argument("--esn0", default="20,14,12,10")
    parser.add_argument("--model", default="dfm09")
    parser.add_argument("--offset", type=float, default=3000)
    parser.add_argument("--drift", type=float, default=0)
    parser.add_argument("--seconds", type=int, default=40)
    parser.add_argument("--serial", type=int, default=21071356)
    parser.add_argument("--invert", action="store_true")
    parser.add_argument("--seeds", default="1")
    args = parser.parse_args()
    os.makedirs(args.work, exist_ok=True)
    here = os.path.dirname(os.path.abspath(__file__))
    rate = 240000
    bad = 0
    print(f"{args.model} {args.seconds} s, carrier {args.offset:+.0f} Hz drifting {args.drift:+.0f} Hz"
          f"{', inverted' if args.invert else ''}")
    print(f"{'Es/N0':>6} {'seed':>4} {'sent':>5} | {'ours':>5} {'wrong':>5} | {'dfm09mod':>8} {'wrong':>5} | {'ours=oracle':>11}")
    for esn0 in [float(x) for x in args.esn0.split(",")]:
        for seed in [int(x) for x in args.seeds.split(",")]:
            prefix = os.path.join(args.work, f"{args.model}-{esn0:g}-{seed}")
            command = [sys.executable, os.path.join(here, "dfm-oracle.py"), prefix, "--model", args.model, "--seconds",
                       str(args.seconds), "--esn0", str(esn0), "--offset", str(args.offset), "--drift", str(args.drift),
                       "--seed", str(seed), "--serial", str(args.serial)] + (["--invert"] if args.invert else [])
            subprocess.run(command, check=True, capture_output=True)
            truth = {t["gps_seconds"]: t for t in json.load(open(prefix + ".truth.json"))}
            ours = reports([args.tool, "sonde", "--type", "dfm", "--ifile", prefix + ".u8", "--offset", "0", "--json"])
            theirs = reports([args.oracle] + (["-i"] if args.invert else []) +
                             ["--IQ", str(args.offset / rate), "--lpIQ", "--ecc", "--ptu", "--json", prefix + ".wav"])
            wrong_ours = wrong_theirs = alike = 0
            for label, found in (("ours", ours), ("dfm09mod", theirs)):
                for frame, record in found.items():
                    problems = wrong_fields(record, truth[frame]) if frame in truth else ["not a second that was sent"]
                    if problems:
                        if label == "ours":
                            wrong_ours += 1
                        else:
                            wrong_theirs += 1
                        for problem in problems[:3]:
                            print(f"    {label} frame {frame}: {problem}")
            for frame in set(ours) & set(theirs):
                a, b = ours[frame], theirs[frame]
                if all(a.get(k) == b.get(k) for k in TEXT + EXACT + ["id"]) and \
                        all(abs(a[k] - b[k]) <= t for k, t in CLOSE.items()) and \
                        abs(a.get("temp", 0) - b.get("temp", 0)) <= 0.051 and ("temp" in a) == ("temp" in b):
                    alike += 1
            print(f"{esn0:6g} {seed:4d} {len(truth):5d} | {len(set(ours) & set(truth)):5d} {wrong_ours:5d} | "
                  f"{len(set(theirs) & set(truth)):8d} {wrong_theirs:5d} | {alike:11d}")
            bad += wrong_ours
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
