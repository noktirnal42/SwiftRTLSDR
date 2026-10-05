#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Makes Meteor-M LRPT transfer frames (a `.cadu` file) carrying MSU-MR images, independently of this package's code.

usage: lrpt-encode.py OUT.cadu [--lines 400] [--seed 3] [--quality 80] [--scene-out DIR]

A synthetic weather scene (land, sea and clouds from fractal noise, a different look in each of three channels) is
compressed the way MSU-MR does it — 8x8 blocks, the standard JPEG quantisation table scaled by a quality factor,
zig-zag order, the standard JPEG luminance Huffman tables, 14 blocks to a packet — and packed into CCSDS source packets
(APIDs 64, 65, 66, one shared sequence counter, 14 packets per channel per 8-line strip plus one APID 70 packet, an
idle packet to fill the last frame),
then into transfer frames (VCDU header 0x40 0x05, first-header pointer, 882-byte data zone) with Reed-Solomon
(255,223) parity interleaved 4 deep in the conventional basis (reedsolo, generator element alpha^11, first root 112).
`--scene-out` writes the source images as 8-bit PGM files, for comparing with what decoders make of them.

Needs numpy and reedsolo.
"""
import argparse
import os
import numpy as np
import reedsolo

WIDTH = 1568
QUANT = np.array([
    16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
    14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]).reshape(8, 8)
ZIGZAG = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14,
          21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60,
          61, 54, 47, 55, 62, 63]
DC_CODES = ["00", "010", "011", "100", "101", "110", "1110", "11110", "111110", "1111110", "11111110", "111111110"]
AC_BITS = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125]          # codes of length 1..16
AC_VALUES = [
    1, 2, 3, 0, 4, 17, 5, 18, 33, 49, 65, 6, 19, 81, 97, 7, 34, 113, 20, 50, 129, 145, 161, 8, 35, 66, 177, 193, 21, 82,
    209, 240, 36, 51, 98, 114, 130, 9, 10, 22, 23, 24, 25, 26, 37, 38, 39, 40, 41, 42, 52, 53, 54, 55, 56, 57, 58, 67, 68,
    69, 70, 71, 72, 73, 74, 83, 84, 85, 86, 87, 88, 89, 90, 99, 100, 101, 102, 103, 104, 105, 106, 115, 116, 117, 118,
    119, 120, 121, 122, 131, 132, 133, 134, 135, 136, 137, 138, 146, 147, 148, 149, 150, 151, 152, 153, 154, 162, 163,
    164, 165, 166, 167, 168, 169, 170, 178, 179, 180, 181, 182, 183, 184, 185, 186, 194, 195, 196, 197, 198, 199, 200,
    201, 202, 210, 211, 212, 213, 214, 215, 216, 217, 218, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 241, 242,
    243, 244, 245, 246, 247, 248, 249, 250]


def canonical_codes():
    codes, code, index = {}, 0, 0
    for length, count in enumerate(AC_BITS, start=1):
        for _ in range(count):
            codes[AC_VALUES[index]] = format(code, "0%db" % length)
            code += 1
            index += 1
        code <<= 1
    return codes


AC_CODES = canonical_codes()
COS = np.array([[np.cos((2 * x + 1) * u * np.pi / 16) for x in range(8)] for u in range(8)])
CU = np.array([1 / np.sqrt(2)] + [1] * 7)


def quantizer(quality):
    ratio = 5000 // quality if quality < 50 else 200 - 2 * quality
    return np.maximum(1, ((QUANT * ratio // 50) + 1) // 2)


def magnitude_bits(value):
    category = int(abs(value)).bit_length()
    if category == 0:
        return 0, ""
    bits = value if value > 0 else value + (1 << category) - 1
    return category, format(bits, "0%db" % category)


def encode_blocks(blocks, quality):
    """Huffman-codes 14 8x8 pixel blocks (the DC prediction restarts in every packet)."""
    q = quantizer(quality)
    out, previous = [], 0
    for block in blocks:
        f = block.astype(np.float64) - 128
        coefficients = 0.25 * np.outer(CU, CU) * (COS @ f.T @ COS.T).T   # F[v][u]: rows vertical, columns horizontal
        quantized = np.round(coefficients / q).astype(int).reshape(64)
        zz = [quantized[p] for p in ZIGZAG]
        category, bits = magnitude_bits(zz[0] - previous)
        previous = zz[0]
        out.append(DC_CODES[category] + bits)
        run = 0
        last = max([i for i in range(1, 64) if zz[i] != 0], default=0)
        for i in range(1, last + 1):
            if zz[i] == 0:
                run += 1
                continue
            while run > 15:
                out.append(AC_CODES[0xF0])
                run -= 16
            category, bits = magnitude_bits(zz[i])
            out.append(AC_CODES[(run << 4) | category] + bits)
            run = 0
        if last < 63:
            out.append(AC_CODES[0x00])
    bits = "".join(out)
    bits += "1" * (-len(bits) % 8)                  # pad with ones, as JPEG does
    return bytes(int(bits[i:i + 8], 2) for i in range(0, len(bits), 8))


def fractal(shape, beta, rng):
    h, w = shape
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    f = np.sqrt(fx * fx + fy * fy)
    f[0, 0] = 1
    spectrum = (rng.normal(size=shape) + 1j * rng.normal(size=shape)) / f ** beta
    field = np.real(np.fft.ifft2(spectrum))
    return (field - field.mean()) / field.std()


def scene(lines, rng):
    shape = (lines, WIDTH)
    land = fractal(shape, 1.6, rng) > 0.35
    relief = fractal(shape, 1.8, rng)
    cloud = np.clip(fractal(shape, 1.45, rng) * 1.1 - 0.15, 0, None)
    cloud = np.tanh(1.6 * cloud)
    high = np.clip(fractal(shape, 1.9, rng), 0, None) * cloud      # icy tops
    x = np.linspace(-1, 1, WIDTH)[None, :]
    limb = 1 - 0.35 * x ** 4                                         # darker towards the swath edges
    ch1 = np.where(land, 55 + 12 * relief, 18) * (1 - cloud) + 225 * cloud
    ch2 = np.where(land, 120 + 20 * relief, 9) * (1 - cloud) + 215 * cloud
    ch3 = np.where(land, 78 + 15 * relief, 5) * (1 - cloud) + (170 - 90 * high) * cloud
    return [np.clip(c * limb, 0, 255).astype(np.uint8) for c in (ch1, ch2, ch3)]


def packets(images, quality, rng):
    lines = images[0].shape[0]
    sequence, out = 0, []
    ms = 6 * 3600_000 + 2 * 60_000
    for strip in range(lines // 8):
        time = bytes([0, 0]) + ms.to_bytes(4, "big") + bytes([0, 0])
        for apid, image in zip((64, 65, 66), images):
            for packet in range(14):
                blocks = [image[strip * 8:(strip + 1) * 8, (packet * 14 + b) * 8:(packet * 14 + b + 1) * 8] for b in range(14)]
                q = int(np.clip(quality + rng.integers(-8, 9), 30, 100))
                data = bytes([packet * 14, 0, 0, 0xFF, 0xF0, q]) + encode_blocks(blocks, q)
                flags = 1 if packet == 0 else 0
                body = time + data
                header = bytes([0x08 | (apid >> 8), apid & 0xFF, (flags << 6) | (sequence >> 8 & 0x3F), sequence & 0xFF,
                                (len(body) - 1) >> 8, (len(body) - 1) & 0xFF])
                out.append(header + body)
                sequence = (sequence + 1) % 16384
        calibration = time + bytes(rng.integers(0, 256, 106, dtype=np.uint8))
        out.append(bytes([0x08, 70, 0xC0 | (sequence >> 8 & 0x3F), sequence & 0xFF, (len(calibration) - 1) >> 8,
                          (len(calibration) - 1) & 0xFF]) + calibration)
        sequence = (sequence + 1) % 16384
        ms += 1200
    return out


def frames(packet_list, counter=12_000_000):
    rs = reedsolo.RSCodec(32, 255, fcr=112, prim=0x187, generator=173)
    zone = 882
    # Fill the last data zone with an idle packet (APID 2047), as a continuous downlink would carry on.
    length = sum(len(p) for p in packet_list)
    pad = -length % zone
    if 0 < pad < 7:
        pad += zone
    if pad:
        packet_list = packet_list + [bytes([0x07, 0xFF, 0xC0, 0x00, (pad - 7) >> 8, (pad - 7) & 0xFF]) + b"\x55" * (pad - 6)]
    stream = b"".join(packet_list)
    starts = []
    position = 0
    for p in packet_list:
        starts.append(position)
        position += len(p)
    out = []
    for index in range(0, (len(stream) + zone - 1) // zone):
        begin, end = index * zone, (index + 1) * zone
        data = stream[begin:end]
        first = next((s - begin for s in starts if begin <= s < end), 0x7FF)
        c = counter + index
        vcdu = bytes([0x40, 0x05, c >> 16 & 0xFF, c >> 8 & 0xFF, c & 0xFF, 0, 0, 0, first >> 8, first & 0xFF]) + data
        assert len(vcdu) == 892
        body = bytearray(1020)
        for i in range(4):
            codeword = bytes(rs.encode(bytes(vcdu[i::4])))
            body[i::4] = codeword
        out.append(bytes([0x1A, 0xCF, 0xFC, 0x1D]) + bytes(body))
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    parser.add_argument("--lines", type=int, default=400)
    parser.add_argument("--seed", type=int, default=3)
    parser.add_argument("--quality", type=int, default=80)
    parser.add_argument("--scene-out")
    args = parser.parse_args()
    rng = np.random.default_rng(args.seed)
    images = scene(args.lines - args.lines % 8, rng)
    if args.scene_out:
        os.makedirs(args.scene_out, exist_ok=True)
        for apid, image in zip((64, 65, 66), images):
            with open(os.path.join(args.scene_out, "scene-%d.pgm" % apid), "wb") as handle:
                handle.write(b"P5 %d %d 255\n" % (WIDTH, image.shape[0]) + image.tobytes())
    result = frames(packets(images, args.quality, rng))
    with open(args.output, "wb") as handle:
        handle.write(b"".join(result))
    print(f"{args.output}: {len(result)} frames, {images[0].shape[0]} lines")


if __name__ == "__main__":
    main()
