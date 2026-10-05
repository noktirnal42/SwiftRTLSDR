#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Writes Meshtastic test packets: the bytes a node would put in a LoRa frame, built from the published format.

usage: meshtastic-vectors.py OUT.txt

Each line: a case name, the channel name, the channel key (base64, as the apps share it; "-" for a packet no
configured channel can open) and the packet in hex (16-byte header, then the encrypted Data message). The protobuf
encoding is written out by hand here and the encryption is OpenSSL's AES in counter mode (the `openssl` command; its
128-bit counter and Meshtastic's 32-bit one agree for any packet LoRa can carry), so neither shares code with the
Swift decoder the packets test. The contents each case carries are listed in Tests/RTLSDRDecodersTests/MeshtasticTests.swift.
"""
import base64
import struct
import subprocess
import sys

DEFAULT_KEY = bytes.fromhex("d4f1bb3a20290759f0bcffabcf4e6901")
BROADCAST = 0xFFFFFFFF


def varint(n):
    out = bytearray()
    n &= (1 << 64) - 1
    while True:
        byte = n & 0x7F
        n >>= 7
        out.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(out)


def field_varint(number, value):
    return varint(number << 3) + varint(value)


def field_bytes(number, data):
    data = data.encode() if isinstance(data, str) else data
    return varint(number << 3 | 2) + varint(len(data)) + data


def field_fixed32(number, value):
    return varint(number << 3 | 5) + struct.pack("<I", value & 0xFFFFFFFF)


def field_sfixed32(number, value):
    return varint(number << 3 | 5) + struct.pack("<i", value)


def field_float(number, value):
    return varint(number << 3 | 5) + struct.pack("<f", value)


def packed_fixed32(number, values):
    return field_bytes(number, b"".join(struct.pack("<I", v) for v in values))


def expand(psk):
    """The firmware's key expansion: one byte picks a well-known key."""
    if len(psk) == 1:
        if psk[0] == 0:
            return b""
        return DEFAULT_KEY[:15] + bytes([(DEFAULT_KEY[15] + psk[0] - 1) & 0xFF])
    return psk


def channel_hash(name, key):
    h = 0
    for b in name.encode() + key:
        h ^= b
    return h


def encrypt(key, sender, packet_id, plain):
    if not key:
        return plain
    nonce = struct.pack("<QI", packet_id, sender) + bytes(4)
    cipher = f"-aes-{8 * len(key)}-ctr"     # AES-128 or AES-256 by key length
    return subprocess.run(["openssl", "enc", cipher, "-nosalt", "-K", key.hex(), "-iv", nonce.hex()],
                          input=plain, capture_output=True, check=True).stdout


def packet(to, sender, packet_id, hop_limit, hop_start, hash_byte, body, want_ack=False, next_hop=0, relay=0):
    flags = hop_limit | (0x08 if want_ack else 0) | hop_start << 5
    return struct.pack("<IIIBBBB", to, sender, packet_id, flags, hash_byte, next_hop, relay) + body


def data(port, payload=b"", **extra):
    out = field_varint(1, port)
    if payload:
        out += field_bytes(2, payload)
    if extra.get("want_response"):
        out += field_varint(3, 1)
    if "request_id" in extra:
        out += field_fixed32(6, extra["request_id"])
    if "reply_id" in extra:
        out += field_fixed32(7, extra["reply_id"])
    return out


def main():
    out_path = sys.argv[1]
    lines = []

    def add(name, channel, psk, to, sender, packet_id, hop_limit, hop_start, plain, **header):
        key = expand(psk)
        body = encrypt(key, sender, packet_id, plain)
        frame = packet(to, sender, packet_id, hop_limit, hop_start, channel_hash(channel, key), body, **header)
        lines.append(f"{name} {channel} {base64.b64encode(psk).decode()} {frame.hex()}")

    lf, default = "LongFast", b"\x01"
    add("text", lf, default, BROADCAST, 0x12345678, 0xDEADBEEF, 3, 3, data(1, "Hello from the mesh"))
    position = (field_sfixed32(1, 377749000) + field_sfixed32(2, -1224194000) + field_varint(3, 15)
                + field_fixed32(4, 1700000000) + field_varint(19, 9) + field_varint(23, 32))
    add("position", lf, default, BROADCAST, 0x12345678, 0x00000101, 2, 3, data(3, position))
    user = (field_bytes(1, "!12345678") + field_bytes(2, "Swift Node") + field_bytes(3, "SWFT")
            + field_varint(5, 43) + field_varint(7, 2) + field_bytes(8, bytes(range(32))))
    add("nodeinfo", lf, default, BROADCAST, 0x12345678, 0x00000102, 3, 3, data(4, user, want_response=True))
    device = (field_varint(1, 87) + field_float(2, 4.05) + field_float(3, 12.5) + field_float(4, 1.25)
              + field_varint(5, 3600))
    add("device", lf, default, BROADCAST, 0x0A0B0C0D, 0x00000103, 3, 3,
        data(67, field_fixed32(1, 1700000100) + field_bytes(2, device)))
    environment = field_float(1, 21.5) + field_float(2, 45.0) + field_float(3, 1013.25)
    add("environment", lf, default, BROADCAST, 0x0A0B0C0D, 0x00000104, 3, 3, data(67, field_bytes(3, environment)))
    route = packed_fixed32(1, [0x11111111, 0x22222222]) + packed_fixed32(3, [0x33333333])
    add("traceroute", lf, default, 0x0A0B0C0D, 0x12345678, 0x00000105, 3, 7, data(70, route, request_id=0x00000099))
    neighbors = field_varint(1, 0x12345678) + b"".join(
        field_bytes(4, field_varint(1, node) + field_float(2, snr)) for node, snr in [(0x0A0B0C0D, 6.25), (0x01020304, -3.5)])
    add("neighbors", lf, default, BROADCAST, 0x12345678, 0x00000106, 0, 3, data(71, neighbors))
    add("ack", lf, default, 0x12345678, 0x0A0B0C0D, 0x00000107, 3, 3, data(5, request_id=0x00000105))
    secret = bytes((7 * i + 3) & 0xFF for i in range(32))
    add("private", "Secret", secret, BROADCAST, 0x0A0B0C0D, 0x00000108, 3, 3, data(1, "AES-256 channel"),
        want_ack=True)
    # A direct message encrypted to a public key: channel hash 0, addressed to one node.
    lines.append("direct - - " + packet(0x12345678, 0x0A0B0C0D, 0x00000109, 3, 3, 0, bytes(range(40))).hex())
    # A channel nobody here has the key for.
    add("unknown", "Hidden", bytes(range(16)), BROADCAST, 0x0A0B0C0D, 0x0000010A, 3, 3, data(1, "you can't read this"))

    with open(out_path, "w") as out:
        out.write("# Meshtastic packets (Tools/meshtastic-vectors.py): case, channel name, key (base64), packet hex\n")
        out.write("\n".join(lines) + "\n")
    print(f"{out_path}: {len(lines)} packets")


if __name__ == "__main__":
    main()
