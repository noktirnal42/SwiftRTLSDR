#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Compares `rtlsdr-tool lora` with gr-lora_sdr's receiver on the same synthetic signals, across signal to noise.

usage: lora-oracle-compare.py RTLSDR-TOOL PAYLOADS.txt WORKDIR [--snr=-10,-14,-18] [--ppm 10] [--freq 906.875e6]
                              [--sf 11] [--bw 250000] [--cr 1] [--rate 1000000] [--seed 7]

For each SNR, Tools/lora-oracle.py makes the frames (gr-lora_sdr's transmitter, a transmitter crystal --ppm off, noise)
and the frames are received three ways: this package (from the u8 file, as a dongle gives it, told --freq so that it
can follow the symbol clock), and gr-lora_sdr with hard and with soft decisions (from the complex-float file, told the
same frequency). A frame counts when its CRC holds and its payload is one that was sent. Needs GNU Radio 3.10 with
gr-lora_sdr; the signals are written to WORKDIR.
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def ours(tool, path, args):
    out = subprocess.run([tool, "lora", "--ifile", path, "--freq", str(args.freq), "--sf", str(args.sf), "--bw", str(args.bw),
                          "--cr", str(args.cr), "--rate", str(args.rate)], capture_output=True, text=True).stdout
    return [line.split()[-1] for line in out.splitlines() if "CRC ok" in line]


def theirs(path, args, soft):
    command = [sys.executable, os.path.join(HERE, "lora-oracle.py"), "rx", path, "--sf", str(args.sf), "--bw", str(args.bw),
               "--rate", str(args.rate), "--freq", str(args.freq)] + (["--soft"] if soft else [])
    out = subprocess.run(command, capture_output=True, text=True).stdout
    payloads, last = [], None
    for line in out.splitlines():
        if line.startswith("rx msg:"):
            last = "".join(f"{int(x, 16):02x}" for x in re.findall(r"0x[0-9a-f]+", line))
        elif line.startswith("CRC valid") and last is not None:
            payloads.append(last)
            last = None
    return payloads


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("tool")
    parser.add_argument("payloads")
    parser.add_argument("workdir")
    parser.add_argument("--snr", default="-10,-14,-18")
    parser.add_argument("--ppm", type=float, default=10)
    parser.add_argument("--freq", type=float, default=906.875e6)
    parser.add_argument("--sf", type=int, default=11)
    parser.add_argument("--bw", type=int, default=250000)
    parser.add_argument("--cr", type=int, default=1)
    parser.add_argument("--rate", type=int, default=1000000)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    sent = [line.strip().lower() for line in open(args.payloads) if line.strip()]
    os.makedirs(args.workdir, exist_ok=True)
    print(f"SF{args.sf}, {args.bw / 1e3:g} kHz, CR 4/{4 + args.cr}, {args.ppm:+g} ppm at {args.freq / 1e6:g} MHz, "
          f"{len(sent)} frames each")
    print(f"{'SNR dB':>7} {'ours':>6} {'gr hard':>8} {'gr soft':>8}")
    for snr in [float(x) for x in args.snr.split(",")]:
        base = os.path.join(args.workdir, f"snr{snr:g}")
        subprocess.run([sys.executable, os.path.join(HERE, "lora-oracle.py"), "tx", args.payloads, base, "--sf", str(args.sf),
                        "--bw", str(args.bw), "--cr", str(args.cr), "--rate", str(args.rate), "--ppm", str(args.ppm),
                        "--freq", str(args.freq), "--snr", str(snr), "--seed", str(args.seed + int(10 * abs(snr)))],
                       check=True, capture_output=True)
        counts = [sum(1 for p in got if p in sent) for got in
                  (ours(args.tool, base + ".u8", args), theirs(base + ".cf32", args, False), theirs(base + ".cf32", args, True))]
        print(f"{snr:>7g} {counts[0]:>6} {counts[1]:>8} {counts[2]:>8}")


if __name__ == "__main__":
    main()
