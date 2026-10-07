#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Compares `rtlsdr-tool atn` with dumpvdl2 on ATN traffic that `rtlsdr-tool atn-sample` makes.

usage: atn-oracle-compare.py RTLSDR-TOOL DUMPVDL2 WORKDIR [--count 200] [--seeds 1,2,3] [--extensions]

`atn-sample` writes random CPDLC and context-management messages as AVLC frames (X.25, a compressed or a full CLNP header,
class 4 transport in data and connect and disconnect TPDUs, the ULCS short forms or presentation data, and X.25 packets
split in two), as values of the ASN.1 types encoded by this package's own PER encoder. dumpvdl2 (whose decoders are made by
asn1c from the same standard) and `atn --frames --json` decode the same frames; for every frame that completes a message
this checks that both found the same application and that the sequence of CHOICE alternatives, the character strings and the
header's message numbers are identical. Needs only the standard library.
"""
import argparse
import json
import os
import struct
import subprocess
import sys


def varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def field_varint(num, v):
    return varint(num << 3) + varint(v)


def field_bytes(num, b):
    return varint(num << 3 | 2) + varint(len(b)) + b


def raw_record(frame_hex, ts):
    stamp = field_varint(1, 1700000000 + ts) + field_varint(2, 0)
    meta = field_varint(2, 136975000) + field_varint(4, len(frame_hex) // 2) + field_varint(8, 1) + field_bytes(11, stamp)
    body = field_bytes(1, meta) + field_bytes(2, bytes.fromhex(frame_hex))
    return struct.pack(">H", len(body) + 2) + body


def walk(node, choices, strings):
    """Choice labels and strings of a dumpvdl2 JSON tree, in document order."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "choice" and isinstance(value, str):
                choices.append(value)
            elif isinstance(value, (dict, list)):
                walk(value, choices, strings)
            elif isinstance(value, str) and key not in ("choice_label",) and value not in ("notRequired", "required"):
                strings.append((key, value))
    elif isinstance(node, list):
        for item in node:
            walk(item, choices, strings)


def mine(node, choices, strings):
    if isinstance(node, dict):
        if "choice" in node and "value" in node and len(node) == 2:
            choices.append(node["choice"])
            mine(node["value"], choices, strings)
            return
        for key, value in node.items():
            mine(value, choices, strings)
    elif isinstance(node, list):
        for item in node:
            mine(item, choices, strings)
    elif isinstance(node, str):
        strings.append(node)


LATLON = ("latitudeDegrees", "latitudeDegreesMinutes", "latitudeDMS", "latitudeReportingPoints",
          "longitudeDegrees", "longitudeDegreesMinutes", "longitudeDMS", "longitudeReportingPoints")


def same_choices(theirs, mine):
    """dumpvdl2's alternative names are shorter (`feet` for `levelFeet`) and its latitude and longitude formatters print no
    alternative at all: line the two sequences up with that allowed."""
    i = 0
    for name in mine:
        if i < len(theirs) and theirs[i].startswith("null") and name.endswith("NULL"):
            i += 1                                       # an extension alternative's NULL: asn1c names it for its position
        elif i < len(theirs) and (lambda a, b: a == b or a.endswith(b) or a.startswith(b) or b.startswith(a) or b.endswith(a))(name.lower(), theirs[i].lower()):
            i += 1
        elif name in LATLON:
            continue
        else:
            return False
    return i == len(theirs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("tool")
    parser.add_argument("dumpvdl2")
    parser.add_argument("work")
    parser.add_argument("--count", type=int, default=200)
    parser.add_argument("--seeds", default="1,2,3")
    parser.add_argument("--extensions", action="store_true")
    parser.add_argument("--tally", action="store_true", help="count the message elements that the failing messages have")
    args = parser.parse_args()
    failing_elements = {}
    total_elements = {}
    os.makedirs(args.work, exist_ok=True)
    bad = 0
    print(f"{'seed':>4} {'frames':>6} {'messages':>8} | {'dumpvdl2 read':>13} {'ours read':>9} | {'differ':>6}")
    for seed in [int(x) for x in args.seeds.split(",")]:
        sample = os.path.join(args.work, f"atn-{seed}.jsonl")
        extra = ["--extensions"] if args.extensions else []
        open(sample, "w").write(subprocess.run([args.tool, "atn-sample", "--count", str(args.count), "--seed", str(seed)] + extra,
                                               capture_output=True, text=True, check=True).stdout)
        records = [json.loads(line) for line in open(sample)]
        raw = os.path.join(args.work, f"atn-{seed}.raw")
        with open(raw, "wb") as f:
            for n, record in enumerate(records):
                f.write(raw_record(record["frame"], n))
        hexfile = os.path.join(args.work, f"atn-{seed}.hex")
        open(hexfile, "w").write("\n".join(r["frame"] for r in records) + "\n")
        theirs = []
        for line in subprocess.run([args.dumpvdl2, "--raw-frames-file", raw, "--output", "decoded:json:file:path=-"], capture_output=True,
                                   text=True).stdout.splitlines():
            if line.startswith("{"):
                theirs.append(json.loads(line))
        ours = [json.loads(line) for line in subprocess.run([args.tool, "atn", "--frames", hexfile, "--json"], capture_output=True, text=True, check=True).stdout.splitlines()]
        messages = sum(1 for r in records if r["complete"])
        read_theirs = read_ours = differ = ambiguous = 0
        if len(theirs) != len(records) or len(ours) != len(records):
            print(f"  output counts differ: {len(records)} frames, dumpvdl2 {len(theirs)}, ours {len(ours)}")
            bad += 1
            continue
        for line_number, (record, t, o) in enumerate(zip(records, theirs, ours)):
            if not record["complete"]:
                continue
            app = record["app"]
            tavlc = t["vdl2"]["avlc"]
            node = None
            stack = [tavlc]
            while stack:                                # find the application's subtree in dumpvdl2's output
                item = stack.pop()
                if isinstance(item, dict):
                    for key in ("cpdlc", "context_mgmt"):
                        if key in item:
                            node = (key, item[key])
                    stack.extend(item.values())
                elif isinstance(item, list):
                    stack.extend(item)
            key = "cpdlc" if app == "cpdlc" else "context_mgmt"
            has_theirs = node is not None and node[0] == key
            has_ours = key in o and "message" in o[key]
            read_theirs += has_theirs
            read_ours += has_ours
            if record["app"] == "cm" and not record["from_aircraft"] and not (has_theirs and has_ours):
                # A context management message in plain data has no marker of its own: a decoder that does not know which
                # application the connection is for tries CPDLC first, and a message that happens to read as that is read as it.
                ambiguous += 1
                continue
            for element in record.get("elements", []):
                total_elements[element] = total_elements.get(element, 0) + 1
            if not has_ours or not has_theirs:
                for element in record.get("elements", []):
                    failing_elements[element] = failing_elements.get(element, 0) + 1
                differ += 1
                print(f"  frame {line_number} ({record['pdu']}): dumpvdl2 {'read' if has_theirs else 'did not read'} it, ours {'read' if has_ours else 'did not read'} it")
                continue
            tc, ts = [], []
            walk(node[1], tc, ts)
            oc, os_ = [], []
            mine(o[key]["message"], oc, os_)
            tstr = [v for _, v in ts if isinstance(v, str)]
            problems = []
            if not same_choices(tc, oc):
                problems.append(f"choices {tc[:6]} vs {oc[:6]}")
            expected = record.get("strings", [])
            if any(s not in tstr and s not in " ".join(tstr) for s in expected):
                problems.append("a string is missing in dumpvdl2's output")
            if any(s not in os_ for s in expected):
                problems.append("a string is missing in ours")
            if record["pdu"].startswith("ATC"):
                header = {h["name"]: h["value"] for h in record.get("header", [])}
                tj = json.dumps(node[1])
                for name, jname in (("messageIdNumber", '"msg_id": '), ("messageRefNumber", '"msg_ref": ')):
                    if name in header and f'{jname}{header[name]}' not in tj:
                        problems.append(f"{name} {header[name]} not as sent in dumpvdl2")
            if problems:
                for element in record.get("elements", []):
                    failing_elements[element] = failing_elements.get(element, 0) + 1
                differ += 1
                print(f"  frame {line_number} ({record['pdu']}): " + "; ".join(problems))
        print(f"{seed:4d} {len(records):6d} {messages:8d} | {read_theirs:13d} {read_ours:9d} | {differ:6d}" + (f"   ({ambiguous} CM data messages read as CPDLC by one of them)" if ambiguous else ""))
        bad += differ
    if args.tally and failing_elements:
        print("elements in failing messages (failing / all messages that have it):")
        for element, count in sorted(failing_elements.items(), key=lambda kv: -kv[1] / total_elements[kv[0]])[:15]:
            print(f"  {element}: {count} / {total_elements[element]}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
