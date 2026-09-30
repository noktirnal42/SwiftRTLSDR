#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Compares the register state two recorded sessions leave behind.

    Tools/replay-trace.py <first.trace> <second.trace>

Traces are the one-line-per-transfer files written by RTLSDR_TRACE (this driver) or by
Tools/trace-librtlsdr.c (an unmodified rtl_sdr). Writes are replayed into a register file, up to the write that
restarts the sample FIFO, and the two files are compared register by register. Prints every register that differs.
"""
import re,sys
def replay(path, stop_at_reset=True):
    tuner={}; demod={}; other={}
    for line in open(path):
        p=line.split()
        if not p or p[0]!='W': continue
        value=int(p[1],16); index=int(p[2],16); data=[int(x,16) for x in p[3:]]
        blk=(index>>8)&0xff; 
        if blk==6:                                  # i2c block
            addr=value
            if addr==0x34 and len(data)>1:
                for i,d in enumerate(data[1:]): tuner[data[0]+i]=d
        elif blk==0:                                # demod: value=(addr<<8)|0x20, index=0x10|page
            page=index&0xf; addr=value>>8
            for i,d in enumerate(data): demod[(page,addr+i)]=d   # (multi-byte demod writes are big-endian pairs; per-byte ok for compare)
        else:
            other[(blk,value)]=tuple(data)
        # stop at first reset-buffer write (capture starts there)
        if stop_at_reset and (index>>8)==1 and value==0x2148 and data==[0,0]: break
    return tuner,demod,other
def show(name,a,b):
    keys=sorted(set(a)|set(b))
    diffs=[(k,a.get(k),b.get(k)) for k in keys if a.get(k)!=b.get(k)]
    print(f"{name}: {len(keys)} registers, {len(diffs)} differ")
    for k,x,y in diffs: print("   ",k,"ref=",None if x is None else (hex(x) if isinstance(x,int) else x),"native=",None if y is None else (hex(y) if isinstance(y,int) else y))
if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    a = replay(sys.argv[1]); b = replay(sys.argv[2])
    show("tuner (R820T)", a[0], b[0]); show("demod", a[1], b[1]); show("usb/sys/other", a[2], b[2])
