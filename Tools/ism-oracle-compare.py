#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Runs rtl_433 and `rtlsdr-tool ism` on the same recordings and compares their JSON output line for line.

usage: ism-oracle-compare.py RTL_433 RTLSDR_TOOL TESTS_DIR [SUBDIR ...]

TESTS_DIR is a checkout of https://github.com/merbanan/rtl_433_tests (its `tests` directory). Both decoders are
restricted to the protocols this package has ported (rtl_433 `-R`), so that decoder priorities work alike. A
directory's `demod` file (extra rtl_433 options such as `-Y minmax`) is honoured where this package has an
equivalent. Prints each difference and a summary; exits 1 if any recording differs.
"""
import json
import os
import shlex
import subprocess
import sys

PROTOCOLS = [2, 12, 18, 19, 20, 30, 40, 73, 78, 119, 172]


def demod_options(directory):
    """rtl_433 options from a `demod` file, and the equivalent options for rtlsdr-tool (None if unsupported)."""
    path = os.path.join(directory, "demod")
    if not os.path.isfile(path):
        return [], []
    words = shlex.split(open(path).read())
    ours = []
    index = 0
    while index < len(words):
        word = words[index]
        value = words[index + 1] if index + 1 < len(words) else ""
        if word == "-Y" and value in ("minmax", "classic"):
            ours += ["--fsk", value]
        elif word == "-f":
            number = value.rstrip("MmKk")
            scale = 1e6 if value[-1:] in "Mm" else 1e3 if value[-1:] in "Kk" else 1
            ours += ["--freq", str(int(float(number) * scale))]
        else:
            return words, None
        index += 2
    return words, ours


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    return [line for line in result.stdout.splitlines() if line.startswith("{")]


def main():
    rtl_433, tool, tests = sys.argv[1:4]
    subdirs = sys.argv[4:] or ["."]
    selection = [argument for protocol in PROTOCOLS for argument in ("-R", str(protocol))]
    same = different = skipped = decoded = 0
    for subdir in subdirs:
        for root, _, files in sorted(os.walk(os.path.join(tests, subdir))):
            theirs_options, our_options = demod_options(root)
            for name in sorted(files):
                if not name.endswith(".cu8"):
                    continue
                path = os.path.join(root, name)
                if our_options is None:
                    skipped += 1
                    print(f"skipped (options {theirs_options}): {path}")
                    continue
                theirs = run([rtl_433, "-c", "0", "-F", "json"] + selection + theirs_options + ["-r", path])
                ours = run([tool, "ism", "--ifile", path, "--json", "--protocols", ",".join(map(str, PROTOCOLS))] + our_options)
                decoded += len(theirs)
                if [json.loads(line) for line in theirs] == [json.loads(line) for line in ours] and theirs == ours:
                    same += 1
                else:
                    different += 1
                    print(f"DIFFERENT: {path}")
                    for line in theirs:
                        if line not in ours:
                            print(f"  rtl_433 only: {line}")
                    for line in ours:
                        if line not in theirs:
                            print(f"  ours only:    {line}")
    print(f"{same} recordings identical ({decoded} messages from rtl_433), {different} different, {skipped} skipped")
    sys.exit(1 if different else 0)


if __name__ == "__main__":
    main()
