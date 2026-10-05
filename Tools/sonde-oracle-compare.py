#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Compares `rtlsdr-tool sonde --json` with rs41mod (rs1729's RS project) on the same recordings, frame by frame.

usage: sonde-oracle-compare.py RS41MOD RTLSDR-TOOL FILE.wav ... [--invert]

rs41mod runs as `rs41mod [-i] --ecc2 --ptu --json FILE`; this package's decoder finds the polarity itself. Both write
one JSON object per frame; frames are matched by frame number. Text fields must be equal; numbers must agree to the
precision rs41mod prints (5 decimals for position and velocity, 0.1 for temperature, exactly for integers).
"""
import json
import subprocess
import sys

TEXT = ["id", "datetime", "subtype"]
EXACT = ["sats", "bt", "tx_frequency"]
CLOSE = {"lat": 1.5e-5, "lon": 1.5e-5, "alt": 1.5e-5, "vel_h": 1.5e-5, "heading": 1.5e-5, "vel_v": 1.5e-5,
         "batt": 0.006, "temp": 0.051}


def frames(command):
    out = subprocess.run(command, capture_output=True, text=True).stdout
    result = {}
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("{"):
            record = json.loads(line)
            result[record["frame"]] = record
    return result


def main():
    args = [a for a in sys.argv[1:] if a != "--invert"]
    invert = "--invert" in sys.argv
    oracle, tool, files = args[0], args[1], args[2:]
    total_problems = 0
    for path in files:
        theirs = frames([oracle] + (["-i"] if invert else []) + ["--ecc2", "--ptu", "--json", path])
        ours = frames([tool, "sonde", "--wav", path, "--json"])
        problems = []
        for number in sorted(set(theirs) | set(ours)):
            a, b = theirs.get(number), ours.get(number)
            if a is None or b is None:
                problems.append(f"frame {number}: only in {'rtlsdr-tool' if a is None else 'rs41mod'}")
                continue
            for key in TEXT + EXACT:
                if (key in a or key in b) and a.get(key) != b.get(key):
                    problems.append(f"frame {number}: {key} {a.get(key)!r} vs {b.get(key)!r}")
            for key, tolerance in CLOSE.items():
                if (key in a) != (key in b):
                    problems.append(f"frame {number}: {key} only in {'rs41mod' if key in a else 'rtlsdr-tool'}")
                elif key in a and abs(a[key] - b[key]) > tolerance:
                    problems.append(f"frame {number}: {key} {a[key]} vs {b[key]}")
        print(f"{path}: rs41mod {len(theirs)} frames, rtlsdr-tool {len(ours)}, {len(problems)} differences")
        for problem in problems[:20]:
            print("  " + problem)
        total_problems += len(problems)
    sys.exit(1 if total_problems else 0)


if __name__ == "__main__":
    main()
