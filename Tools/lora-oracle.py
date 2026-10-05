#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""LoRa transmit and receive with gr-lora_sdr (EPFL TCL, GPL-3.0), as an oracle for this package's LoRa decoder.

usage: lora-oracle.py tx PAYLOADS.txt OUT [--sf 11] [--bw 250000] [--cr 1] [--rate 1000000] [--sync 0x2B]
                         [--preamble 16] [--ldro 0|1|2] [--cfo 0] [--ppm 0 --freq 906.875e6] [--snr 30] [--gap 20] [--seed 1]
       lora-oracle.py rx IN.cf32 [--sf 11] [--bw 250000] [--rate 1000000] [--sync 0x2B] [--preamble 16] [--ldro 2] [--soft]
       lora-oracle.py symbols PAYLOADS.txt [--sf 11] [--cr 1] [--ldro 0|1|2]

tx: PAYLOADS.txt holds one payload per line in hex. gr-lora_sdr's transmit chain (whitening, header, CRC, Hamming,
interleaver, Gray demapping, modulation) makes the frames at --rate; a transmitter crystal --ppm off moves the carrier
(by ppm of --freq) and the symbol clock together (GNU Radio's channel model); numpy then shifts them by --cfo Hz, adds noise
for --snr dB in the LoRa bandwidth and writes OUT.cf32 (complex float) and OUT.u8 (unsigned 8-bit I/Q, as a dongle
gives). --cr is 1 to 4 (4/5 … 4/8). rx: gr-lora_sdr's receive chain on a cf32 file (hard decisions, or soft with --soft); prints one
line per frame: the payload in hex and whether its CRC held. symbols: the chirp offsets the transmit chain gives each payload (the
Gray demapper's output), all frames in one line. Needs GNU Radio 3.10 with gr-lora_sdr installed, and numpy.
"""
import argparse
import subprocess
import sys
import tempfile
import numpy as np
from gnuradio import blocks, channels, gr
import gnuradio.lora_sdr as lora


def tx(args):
    payloads = [line.strip() for line in open(args.payloads) if line.strip()]
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
        handle.write(",".join(payloads) + ",")
        source_path = handle.name
    raw = tempfile.NamedTemporaryFile(suffix=".cf32", delete=False).name
    top = gr.top_block()
    source = blocks.file_source(gr.sizeof_char, source_path, False)
    gap = int(args.gap * 2 ** args.sf * args.rate / args.bw)
    chain = [
        lora.whitening(True, False, ",", "packet_len"),
        lora.header(False, True, args.cr),
        lora.add_crc(True),
        lora.hamming_enc(args.cr, args.sf),
        lora.interleaver(args.cr, args.sf, args.ldro, args.bw),
        lora.gray_demap(args.sf),
        lora.modulate(args.sf, args.rate, args.bw, [args.sync], gap, args.preamble),
    ]
    if args.ppm:
        chain.append(channels.channel_model(noise_voltage=0, frequency_offset=args.freq * args.ppm * 1e-6 / args.rate,
                                            epsilon=1 + args.ppm * 1e-6, taps=[1.0 + 0j], noise_seed=0, block_tags=True))
    sink = blocks.file_sink(gr.sizeof_gr_complex, raw)
    top.connect(source, chain[0])
    for a, b in zip(chain, chain[1:]):
        top.connect(a, b)
    top.connect(chain[-1], sink)
    top.run()
    sink.close()

    rng = np.random.default_rng(args.seed)
    signal = np.fromfile(raw, dtype=np.complex64).astype(np.complex128)
    lead = np.zeros(int(0.05 * args.rate))
    signal = np.concatenate([lead, signal, lead])
    n = np.arange(len(signal))
    signal *= np.exp(2j * np.pi * args.cfo * n / args.rate + 1j * rng.uniform(0, 2 * np.pi))
    # Noise for the SNR in the LoRa bandwidth: the signal has unit power.
    sigma2 = 10 ** (-args.snr / 10) * args.rate / args.bw
    noisy = signal + rng.normal(0, np.sqrt(sigma2 / 2), len(signal)) + 1j * rng.normal(0, np.sqrt(sigma2 / 2), len(signal))
    noisy.astype(np.complex64).tofile(args.output + ".cf32")
    scale = 30 / np.sqrt(np.mean(np.abs(noisy) ** 2))
    iq = np.empty(2 * len(noisy))
    iq[0::2], iq[1::2] = noisy.real * scale + 127.5, noisy.imag * scale + 127.5
    np.clip(np.round(iq), 0, 255).astype(np.uint8).tofile(args.output + ".u8")
    print(f"{args.output}: {len(payloads)} frames, {len(noisy) / args.rate:.2f} s at {args.rate:.0f} S/s, SF{args.sf} "
          f"BW {args.bw / 1e3:.0f} kHz CR 4/{4 + args.cr}, CFO {args.cfo:+.0f} Hz, SNR {args.snr} dB")


def symbols(args):
    payloads = [line.strip() for line in open(args.payloads) if line.strip()]
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
        handle.write(",".join(payloads) + ",")
        source_path = handle.name
    top = gr.top_block()
    source = blocks.file_source(gr.sizeof_char, source_path, False)
    chain = [
        lora.whitening(True, False, ",", "packet_len"),
        lora.header(False, True, args.cr),
        lora.add_crc(True),
        lora.hamming_enc(args.cr, args.sf),
        lora.interleaver(args.cr, args.sf, args.ldro, args.bw),
        lora.gray_demap(args.sf),
    ]
    sink = blocks.vector_sink_i()
    top.connect(source, chain[0])
    for a, b in zip(chain, chain[1:]):
        top.connect(a, b)
    top.connect(chain[-1], sink)
    top.run()
    print(" ".join(str(v) for v in sink.data()))


def rx(args):
    top = gr.top_block()
    source = blocks.file_source(gr.sizeof_gr_complex, args.input, False)
    source.set_min_output_buffer(1 << 18)             # frame_sync wants more than the default 8191 at SF11 and up
    sync = lora.frame_sync(int(args.freq), args.bw, args.sf, False, [args.sync], int(args.rate / args.bw), args.preamble)
    demod = lora.fft_demod(args.soft, True)
    gray = lora.gray_mapping(args.soft)
    deinterleave = lora.deinterleaver(args.soft)
    hamming = lora.hamming_dec(args.soft)
    header = lora.header_decoder(False, 1, 255, True, args.ldro, False)
    dewhiten = lora.dewhitening()
    crc = lora.crc_verif(2, False)
    null = blocks.null_sink(gr.sizeof_char)
    top.connect(source, sync, demod, gray, deinterleave, hamming, header, dewhiten, crc, null)
    top.msg_connect((header, "frame_info"), (sync, "frame_info"))
    top.run()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["tx", "rx", "symbols"])
    parser.add_argument("input")
    parser.add_argument("output", nargs="?")
    parser.add_argument("--sf", type=int, default=11)
    parser.add_argument("--bw", type=int, default=250000)
    parser.add_argument("--cr", type=int, default=1)
    parser.add_argument("--rate", type=int, default=1000000)
    parser.add_argument("--sync", type=lambda x: int(x, 0), default=0x2B)
    parser.add_argument("--preamble", type=int, default=16)
    parser.add_argument("--ldro", type=int, default=2)
    parser.add_argument("--cfo", type=float, default=0)
    parser.add_argument("--ppm", type=float, default=0)
    parser.add_argument("--freq", type=float, default=906.875e6)
    parser.add_argument("--snr", type=float, default=30)
    parser.add_argument("--gap", type=float, default=20)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--soft", action="store_true")
    args = parser.parse_args()
    if args.mode in ("tx", "symbols"):
        args.payloads = args.input
        (tx if args.mode == "tx" else symbols)(args)
    else:
        rx(args)


if __name__ == "__main__":
    main()
