#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Runs `rtlsdr-tool ais` on the signals ais-oracle.py makes and checks it against what was sent and against pyais.

usage: ais-oracle-compare.py RTLSDR-TOOL WORKDIR [--cnr 25,18,14,12,10] [--messages 36] [--offset 0] [--both] [--invert]
                             [--seeds 1,2,3]

For each carrier-to-noise ratio (and seed) it makes OUT.u8, decodes it with this package starting blind (--nmea and --json),
and prints how many of the messages sent came out with exactly the bits that were sent, how many frames came out that were
not sent (wrong ones), and how many messages' JSON fields disagree with pyais's reading of the same sentences (pyais is
the independent decoder of the message tables; it names the fields as this JSON does, except msg_type and name, and gives
the rate of turn converted). Needs numpy, scipy and pyais.
"""
import argparse
import json
import math
import os
import subprocess
import sys

try:
    from pyais import decode
except ImportError:
    decode = None

RENAME = {"msg_type": "type", "name": "shipname"}


def pyais_fields(sentences):
    d = decode(*sentences).asdict()
    out = {RENAME.get(k, k): v for k, v in d.items()}
    if out.get("type") == 21 and "shipname" not in out and "name" in d:
        out["shipname"] = d["name"]
    return out


def agree(ours, ref):
    problems = []
    for key, value in ours.items():
        if key in ("channel", "freq", "repeat"):
            continue
        if key == "rot":
            if "turn" in ref and ref["turn"] is not None:
                expect = math.copysign((abs(value) / 4.733) ** 2, value)
                if abs(expect - ref["turn"]) > 0.6:
                    problems.append((key, value, ref["turn"]))
            continue
        if key == "accuracy":
            if bool(ref.get(key)) != bool(value):
                problems.append((key, value, ref.get(key)))
            continue
        if key not in ref:
            problems.append((key, value, "absent"))
            continue
        r = ref[key]
        if key == "ship_type":
            r = int(getattr(r, "value", r))
            if r != value and r // 10 == value // 10:
                continue                                   # pyais maps a reserved value to another of its class
        if isinstance(value, float):
            if r is None or abs(value - float(r)) > 1.5e-6 * max(1, abs(float(r))) + (0.06 if key in ("speed", "course", "draught") else 0) \
                    + (2e-6 if key in ("lat", "lon") else 0):
                problems.append((key, value, r))
        elif isinstance(value, str):
            if str(r).strip().rstrip("@").strip() != value:
                problems.append((key, value, r))
        elif value != r:
            problems.append((key, value, r))
    return problems


def body_end(sentence):
    return sentence.index("*")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("tool")
    parser.add_argument("work")
    parser.add_argument("--cnr", default="25,18,14,12,10")
    parser.add_argument("--messages", type=int, default=36)
    parser.add_argument("--offset", type=float, default=0)
    parser.add_argument("--both", action="store_true")
    parser.add_argument("--invert", action="store_true")
    parser.add_argument("--seeds", default="1,2,3")
    args = parser.parse_args()
    if decode is None:
        sys.exit("pyais is needed (pip install pyais)")
    os.makedirs(args.work, exist_ok=True)
    here = os.path.dirname(os.path.abspath(__file__))
    bad = 0
    print(f"AIS {args.messages} messages, carrier {args.offset:+.0f} Hz{', both channels' if args.both else ''}{', inverted' if args.invert else ''}")
    print(f"{'CNR':>6} {'seed':>4} {'sent':>5} | {'ours':>5} {'wrong':>5} | {'fields differ from pyais':>24}")
    for cnr in [float(x) for x in args.cnr.split(",")]:
        for seed in [int(x) for x in args.seeds.split(",")]:
            prefix = os.path.join(args.work, f"ais-{cnr:g}-{seed}")
            command = [sys.executable, os.path.join(here, "ais-oracle.py"), prefix, "--messages", str(args.messages), "--cnr", str(cnr),
                       "--offset", str(args.offset), "--seed", str(seed)]
            subprocess.run(command + (["--both"] if args.both else []) + (["--invert"] if args.invert else []), check=True, capture_output=True)
            truth = json.load(open(prefix + ".truth.json"))
            def normal(sentences):                       # the sequence id of a multipart message is the receiver's to number
                out = []
                for sentence in sentences:
                    parts = sentence.split(",")
                    parts[3] = ""
                    body = ",".join(parts)[1:body_end(sentence)]
                    out.append(body)
                return tuple(out)

            sent = {normal(t["nmea"]) for t in truth}
            run = [args.tool, "ais", "--ifile", prefix + ".u8"]
            nmea = subprocess.run(run + ["--nmea"], capture_output=True, text=True).stdout.split()
            frames, current = [], []
            for line in nmea:
                parts = line.split(",")
                current.append(line)
                if parts[1] == parts[2]:
                    frames.append(tuple(current))
                    current = []
            got = {normal(f) for f in frames}
            sentences_of = {normal(f): f for f in frames}
            wrong = len(got - sent)
            reports = [json.loads(l) for l in subprocess.run(run + ["--json"], capture_output=True, text=True).stdout.splitlines() if l.startswith("{")]
            differ = 0
            by_mmsi = {}
            for sentences in frames:
                f = pyais_fields(sentences)
                by_mmsi.setdefault((f["mmsi"], f["type"], f.get("partno")), f)
            for r in reports:
                ref = by_mmsi.get((r["mmsi"], r["type"], r.get("partno")))
                problems = agree(r, ref) if ref else [("frame", "not in the NMEA output", None)]
                if problems:
                    differ += 1
                    print("    differs:", r["type"], problems[:3])
            print(f"{cnr:6g} {seed:4d} {len(sent):5d} | {len(got & sent):5d} {wrong:5d} | {differ:24d}")
            bad += wrong + differ
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
