#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Compares the PER-visible constraints of the ATN ASN.1 types in this package (Tools/asn1, from Wireshark) with the ones
asn1c generated for dumpvdl2 (which decodes live traffic), type by type.

usage: atn-schema-compare.py RTLSDR-TOOL DUMPVDL2-SRC-ASN1-DIR

For every named type that both have, compares the value constraint (integer range, enumeration size, choice size) and the
size constraint (strings, octet and bit strings, SEQUENCE OF) as PER sees them. Prints each difference; exits 1 if there is one.
Inline constraints inside a SEQUENCE are not named types and are not compared here (the end-to-end comparison finds those).
"""
import json
import os
import re
import subprocess
import sys

TUPLE = re.compile(r"\{\s*(APC_[A-Z_]+(?:\s*\|\s*APC_[A-Z_]+)?),\s*(-?\d+),\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)\s*\}")


def constraints(path, name):
    text = open(path, encoding="utf-8", errors="replace").read()
    key = "asn_PER_type_" + name.replace("-", "_") + "_constr_"
    at = text.find(key)
    if at < 0:
        return None
    block = text[at:at + 600]
    found = TUPLE.findall(block)[:2]
    out = []
    for kind, bits, effective, lower, upper in found:
        if "UNCONSTRAINED" in kind:
            out.append(None)
        elif "SEMI" in kind:
            out.append((int(lower), None, "EXTENSIBLE" in kind))
        else:
            out.append((int(lower), int(upper), "EXTENSIBLE" in kind))
    return out if len(out) == 2 else None


def members(path, name):
    """The members of an asn1c SEQUENCE or CHOICE: (name, named type or None for an inline one), in order."""
    text = open(path, encoding="utf-8", errors="replace").read()
    start = text.find("asn_MBR_" + name.replace("-", "_") + "_")
    if start < 0:
        return None
    end = text.find("};", start)
    block = text[start:end]
    out = []
    for entry in block.split("\t{ ATF_")[1:]:
        type_match = re.search(r"&asn_DEF_([A-Za-z0-9_]+),", entry)
        name_match = re.search(r'\n\t\t"([^"]+)"', entry)
        if not type_match or not name_match:
            return None
        out.append((name_match.group(1), type_match.group(1)))
    return out


def main():
    tool, directory = sys.argv[1], sys.argv[2]
    rows = [json.loads(l) for l in subprocess.run([tool, "atn-schema"], capture_output=True, text=True, check=True).stdout.splitlines()]
    compared = differences = 0
    for row in rows:
        if "." not in row["name"]:
            continue                                           # the plain name repeats a module-qualified one
        module, base = row["name"].split(".", 1)
        path = os.path.join(directory, base + ".c")
        if not os.path.exists(path) or row["kind"] in ("other", "sequence"):
            continue
        theirs = constraints(path, base)
        if theirs is None:
            continue
        compared += 1
        mine = [tuple(row["value"]) if row["value"] else None, tuple(row["size"]) if row["size"] else None]
        for index, label in ((0, "value"), (1, "size")):
            a, b = mine[index], theirs[index]
            if row["kind"] == "choice" and index == 0:
                continue                                       # asn1c lists a CHOICE's alternative count differently
            if row["kind"] in ("integer", "enumerated") and index == 1 or row["kind"] in ("string", "octetstring", "bitstring", "sequenceof") and index == 0:
                continue
            if a != b:
                differences += 1
                print(f"{row['name']} ({row['kind']}): {label} constraint here {a}, in dumpvdl2 {b}")
    # Member types: for every SEQUENCE and CHOICE, the named type of each member that has one (asn1c names an inline type after
    # its member, which is not compared). Wireshark's text and dumpvdl2's source can disagree here (and have).
    compared_members = 0
    for row in rows:
        if "." not in row["name"] or row["kind"] not in ("sequence", "choice"):
            continue
        module, base = row["name"].split(".", 1)
        path = os.path.join(directory, base + ".c")
        if not os.path.exists(path):
            continue
        theirs = members(path, base)
        if theirs is None:
            continue
        mine = [(m["name"], m["type"]) for m in row["members"]]
        compared_members += 1
        a = [(n, (t or "").replace("-", "_")) for n, t in mine]
        # dumpvdl2's list has the members in declaration order, and (for a CHOICE) its extensions too.
        names_here = [n for n, _ in a]
        names_there = [n for n, _ in theirs]
        if names_here != names_there[:len(names_here)] and set(names_here) != set(names_there):
            differences += 1
            print(f"{row['name']}: members here {names_here}, in dumpvdl2 {names_there}")
            continue
        by_name = dict(theirs)
        for n, t in a:
            if t and n in by_name and not by_name[n].startswith(n) and by_name[n] != t and by_name[n] != "NULL":
                differences += 1
                print(f"{row['name']}.{n}: type {t} here, {by_name[n]} in dumpvdl2")
    print(f"{compared_members} sequences and choices' members compared")
    print(f"{compared} named types compared, {differences} differences")
    sys.exit(1 if differences else 0)


main()
