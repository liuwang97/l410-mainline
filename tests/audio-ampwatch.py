#!/usr/bin/env python3
# Watch both TAS2562 speaker amps (i2c3 0x4c/0x4e) and print every change of
# power mode, TDM clock detection and interrupt flags, 5 ms apart.
# Read-only: atomic I2C_RDWR reads, the page register is never written, so the
# kernel's regmap page cache stays valid. Skips a sample if an amp is not on
# book 0 / page 0. Run as root on the test kernel: audio-ampwatch.py [seconds]
#
# PWR 0c = active (I/V sense off), 0e = shutdown. TDMDET 0x24 = 48 kHz at
# 64 fs; 0x7f = no clock. LIVE0/LTCH0 bit 2 = TDM clock error.
import ctypes, fcntl, os, sys, time

I2C_RDWR = 0x0707
I2C_M_RD = 0x0001

class Msg(ctypes.Structure):
    _fields_ = [("addr", ctypes.c_uint16), ("flags", ctypes.c_uint16),
                ("len", ctypes.c_uint16), ("buf", ctypes.POINTER(ctypes.c_uint8))]

class RdWr(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(Msg)), ("nmsgs", ctypes.c_uint32)]

fd = os.open("/dev/i2c-3", os.O_RDWR)

def rd(addr, reg):
    w = (ctypes.c_uint8 * 1)(reg)
    r = (ctypes.c_uint8 * 1)()
    msgs = (Msg * 2)(Msg(addr, 0, 1, w), Msg(addr, I2C_M_RD, 1, r))
    fcntl.ioctl(fd, I2C_RDWR, RdWr(msgs, 2))
    return r[0]

REGS = [0x02, 0x03, 0x06, 0x07, 0x08, 0x11, 0x1f, 0x20, 0x24, 0x25]
NAMES = {0x02: "PWR", 0x03: "PB1", 0x06: "TDM0", 0x07: "TDM1", 0x08: "TDM2",
         0x11: "TDMDET", 0x1f: "LIVE0", 0x20: "LIVE1", 0x24: "LTCH0", 0x25: "LTCH1"}

dur = float(sys.argv[1]) if len(sys.argv) > 1 else 10
t0 = time.monotonic()
last = {}
while time.monotonic() - t0 < dur:
    for a in (0x4c, 0x4e):
        try:
            if rd(a, 0x00) or rd(a, 0x7f):
                continue
            vals = tuple(rd(a, r) for r in REGS)
        except OSError as e:
            vals = ("err", e.errno)
        if last.get(a) != vals:
            t = time.monotonic() - t0
            if vals[0] == "err":
                print(f"{t:7.3f} {a:02x} i2c err {vals[1]}", flush=True)
            else:
                print(f"{t:7.3f} {a:02x} " + " ".join(
                    f"{NAMES[r]}={v:02x}" for r, v in zip(REGS, vals)), flush=True)
            last[a] = vals
    time.sleep(0.005)
