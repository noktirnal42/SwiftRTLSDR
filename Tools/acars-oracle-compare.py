#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Compares `rtlsdr-tool acars` with acarsdec on the same signals from Tools/acars-oracle.py, across signal to noise.

usage: acars-oracle-compare.py RTLSDR-TOOL ACARSDEC WORKDIR [--audio-snr=12,9,7,5] [--snr=15,12,9] [--messages 60]

For each audio SNR both decode the same WAV (12.5 kHz AM audio, a channel each: acarsdec -o 4 -f, and
`rtlsdr-tool acars --wav --json`); for each RF SNR this package decodes the I/Q (acarsdec reads no I/Q files). A
message counts when registration, label, block, message number, flight and text all equal what was sent.
"""
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def sent(path):
    out = set()
    for line in open(path, encoding="utf-8"):
        c, reg, label, block, number, flight, text = line.rstrip("\n").split("\t", 6)
        out.add((reg, label, block, number, flight, text))
    return out


def decoded(lines):
    out = []
    for line in lines.splitlines():
        if not line.startswith("{"):
            continue
        m = json.loads(line)
        out.append((m.get("tail", ""), m.get("label", ""), m.get("block_id", ""), m.get("msgno", ""), m.get("flight", ""),
                    m.get("text", "")))
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("tool")
    parser.add_argument("acarsdec")
    parser.add_argument("workdir")
    parser.add_argument("--audio-snr", default="12,9,7,5")
    parser.add_argument("--snr", default="15,12,9")
    parser.add_argument("--messages", type=int, default=60)
    args = parser.parse_args()
    os.makedirs(args.workdir, exist_ok=True)
    channels = "131.55e6,131.125e6,130.45e6"
    print(f"{args.messages} messages on 3 channels each")
    print(f"{'audio SNR':>10} {'ours':>6} {'acarsdec':>9}")
    for snr in [float(x) for x in args.audio_snr.split(",")]:
        base = os.path.join(args.workdir, f"audio{snr:g}")
        subprocess.run([sys.executable, os.path.join(HERE, "acars-oracle.py"), base, "--messages", str(args.messages),
                        "--channels", channels, "--audio-snr", str(snr), "--snr", "40", "--seed", str(int(snr * 10) + 3)],
                       check=True, capture_output=True)
        truth = sent(base + ".txt")
        ours = decoded(subprocess.run([args.tool, "acars", "--wav", base + ".wav", "--json"], capture_output=True, text=True).stdout)
        theirs = decoded(subprocess.run([args.acarsdec, "-o", "4", "-f", base + ".wav"], capture_output=True, text=True).stdout)
        print(f"{snr:>10g} {sum(m in truth for m in ours):>6} {sum(m in truth for m in theirs):>9}"
              + (f"   (wrong: ours {sum(m not in truth for m in ours)}, acarsdec {sum(m not in truth for m in theirs)})"
                 if any(m not in truth for m in ours + theirs) else ""))
    print(f"{'RF SNR':>10} {'ours':>6}")
    for snr in [float(x) for x in args.snr.split(",")]:
        base = os.path.join(args.workdir, f"rf{snr:g}")
        subprocess.run([sys.executable, os.path.join(HERE, "acars-oracle.py"), base, "--messages", str(args.messages),
                        "--channels", channels, "--snr", str(snr), "--audio-snr", "40", "--seed", str(int(snr * 10) + 7)],
                       check=True, capture_output=True)
        truth = sent(base + ".txt")
        ours = decoded(subprocess.run([args.tool, "acars", "--ifile", base + ".u8", "--freq", channels.replace("e6", ""),
                                       "--center", "131.0125e6", "--json"], capture_output=True, text=True).stdout)
        print(f"{snr:>10g} {sum(m in truth for m in ours):>6}" + (f"   (wrong {sum(m not in truth for m in ours)})" if any(m not in truth for m in ours) else ""))


if __name__ == "__main__":
    main()
