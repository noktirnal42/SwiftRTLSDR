#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Makes Tests/RTLSDRDecodersTests/Resources/ism-code-vectors.txt: bit buffers and what rtl_433 decodes from them.

usage: generate-ism-vectors.py RTL_433 RTLSDR_TOOL TESTS_DIR OUTPUT [SUBDIR ...]

`rtlsdr-tool ism --codes` prints every bit buffer its decoders are given (rtl_433's `-y` notation) while it decodes
the recordings of an rtl_433_tests checkout. rtl_433 (`-y`, one decoder at a time) decodes each buffer that decoded;
up to three are kept per model, and a few that fail their integrity check per protocol. The output holds only the bit
strings (no recordings) and rtl_433's JSON without its time field:

    [19]{36}b510bef470...<TAB>{"model" : "Nexus-TH", ...}
    [19]{36}0000000000<TAB>-            (rtl_433 decodes nothing)
"""
import os
import re
import subprocess
import sys
import tempfile

PROTOCOLS = [2, 12, 18, 19, 20, 30, 40, 73, 78, 119, 172]
PER_MODEL, FAILURES = 3, 3


def rtl_433_decode(rtl_433, tests, code):
    """rtl_433's JSON lines for one bit buffer: `-y @file` with only that protocol enabled (the file inside TESTS_DIR,
    so a chroot can see it). The `[n]` prefix is not passed on: rtl_433 cannot find decoders registered through a
    factory (the WH2's) by number."""
    protocol, bits = code[1:code.index("]")], code[code.index("]") + 1:]
    selection = ["-R", protocol]
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, dir=tests) as handle:
        handle.write(bits + "\n")
        path = handle.name
    try:
        result = subprocess.run([rtl_433, "-c", "0", "-F", "json"] + selection + ["-y", "@" + path], capture_output=True, text=True)
    finally:
        os.unlink(path)
    return [re.sub(r'^\{"time" : "[^"]*", ', "{", line) for line in result.stdout.splitlines() if line.startswith("{")]


def main():
    rtl_433, tool, tests, output = sys.argv[1:5]
    subdirs = sys.argv[5:] or ["."]
    successes = {protocol: [] for protocol in PROTOCOLS}
    failures = {protocol: [] for protocol in PROTOCOLS}
    for subdir in subdirs:
        for root, _, files in sorted(os.walk(os.path.join(tests, subdir))):
            for name in sorted(files):
                if not name.endswith(".cu8"):
                    continue
                result = subprocess.run([tool, "ism", "--ifile", os.path.join(root, name), "--codes"], capture_output=True, text=True)
                for line in result.stdout.splitlines():
                    if not line.startswith("codes\t"):
                        continue
                    _, code, status = line.split("\t")
                    protocol = int(code[1:code.index("]")])
                    if int(status) > 0 and code not in successes[protocol]:
                        successes[protocol].append(code)
                    elif int(status) == -3 and code not in failures[protocol] and len(failures[protocol]) < FAILURES:
                        failures[protocol].append(code)

    lines = []
    per_model = {}
    for protocol in PROTOCOLS:
        for code in successes[protocol]:
            decoded = rtl_433_decode(rtl_433, tests, code)
            model = re.search(r'"model" : "([^"]*)"', decoded[0]).group(1) if decoded else "-"
            if per_model.get(model, 0) >= PER_MODEL:
                continue
            per_model[model] = per_model.get(model, 0) + 1
            lines += [f"{code}\t{json}" for json in decoded] or [f"{code}\t-"]
        for code in failures[protocol]:
            decoded = rtl_433_decode(rtl_433, tests, code)
            lines += [f"{code}\t{json}" for json in decoded] or [f"{code}\t-"]
    with open(output, "w") as handle:
        handle.write("# Bit buffers seen by this package's decoders in rtl_433_tests recordings, and rtl_433 25.02's output\n")
        handle.write("# for each (`rtl_433 -y`, time field removed). Made by Tools/generate-ism-vectors.py.\n")
        handle.write("\n".join(lines) + "\n")
    print(f"{len(lines)} lines; buffers per model: " + ", ".join(f"{model} {count}" for model, count in sorted(per_model.items())))


if __name__ == "__main__":
    main()
