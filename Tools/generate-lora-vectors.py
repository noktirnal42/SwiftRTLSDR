#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Writes LoRa test vectors: payloads and the chirp offsets gr-lora_sdr's transmit chain gives them.

usage: generate-lora-vectors.py OUT.txt [--seed 7]

Each line: spreading factor, coding rate (1-4), low-data-rate flag, payload hex, then the symbols. Payloads are random
bytes; the settings cover spreading factors 7-12, every coding rate, low data rate on and off, and lengths up to 255.
Needs GNU Radio 3.10 with gr-lora_sdr (EPFL TCL, GPL-3.0), and numpy.
"""
import argparse
import tempfile
import numpy as np
from gnuradio import blocks, gr
import gnuradio.lora_sdr as lora


def symbols(payload, sf, cr, ldro):
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
        handle.write(payload.hex() + ",")
        path = handle.name
    top = gr.top_block()
    chain = [blocks.file_source(gr.sizeof_char, path, False), lora.whitening(True, False, ",", "packet_len"),
             lora.header(False, True, cr), lora.add_crc(True), lora.hamming_enc(cr, sf),
             lora.interleaver(cr, sf, ldro, 125000), lora.gray_demap(sf)]
    sink = blocks.vector_sink_i()
    for a, b in zip(chain, chain[1:]):
        top.connect(a, b)
    top.connect(chain[-1], sink)
    top.run()
    return list(sink.data())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()
    rng = np.random.default_rng(args.seed)
    cases = [(sf, cr, 0, int(rng.integers(2, 61))) for sf in range(7, 13) for cr in range(1, 5)]
    cases += [(sf, cr, 1, int(rng.integers(2, 61))) for sf in (11, 12) for cr in range(1, 5)]
    cases += [(7, 1, 0, 255), (11, 1, 0, 255), (9, 3, 0, 2), (12, 4, 1, 255)]
    with open(args.output, "w") as out:
        out.write("# spreading factor, coding rate (1-4), low data rate, payload, symbols (gr-lora_sdr's transmit chain)\n")
        for sf, cr, ldro, length in cases:
            payload = bytes(rng.integers(0, 256, length, dtype=np.uint8))
            values = symbols(payload, sf, cr, ldro)
            out.write(f"{sf} {cr} {ldro} {payload.hex()} {' '.join(map(str, values))}\n")
    print(f"{args.output}: {len(cases)} vectors")


if __name__ == "__main__":
    main()
