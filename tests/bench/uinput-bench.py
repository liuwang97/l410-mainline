#!/usr/bin/python3
"""Synthetic user input for tests/bench/browser-bench.sh: an absolute pointer (like QEMU's usb-tablet:
ABS_X/ABS_Y + buttons + wheel + a few keys), so positions are exact whatever the pointer
acceleration. Coordinates are fractions of the screen (0..1). Run as root.

  uinput-bench.py serve <command fifo> <ack fifo>

keeps one device for the whole run (a device hot-plug costs KWin work of its own) and executes
one command per line, answering "ok" on the ack fifo:

  move   <x> <y>
  scroll <x> <y> <seconds> [n]      wheel scrolling, n notches every 20 ms (default 3), down then up
  drag   <x> <y> <seconds>          press at (x, y), move around, release
  click  <x> <y>
  dclick <x> <y>                    double click (title bar: maximize / restore)
  key    <code>[+<code>...]         key chord, e.g. 125+109 = Meta+PgDown
  quit
"""
import fcntl
import math
import os
import struct
import sys
import time

EV_SYN, EV_KEY, EV_REL, EV_ABS = 0, 1, 2, 3
BTN_LEFT, BTN_RIGHT = 0x110, 0x111
REL_WHEEL, REL_WHEEL_HI_RES = 0x08, 0x0B
ABS_X, ABS_Y = 0, 1
MAX = 32767
KEYS = (125, 109, 104, 29, 56, 1, 63)	# LEFTMETA, PAGEDOWN, PAGEUP, LEFTCTRL, LEFTALT, ESC, F5

UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT, UI_SET_ABSBIT = 0x40045564, 0x40045565, 0x40045566, 0x40045567
UI_DEV_SETUP, UI_ABS_SETUP, UI_DEV_CREATE, UI_DEV_DESTROY = 0x405C5503, 0x401C5504, 0x5501, 0x5502


class Tablet:
    def __init__(self):
        self.fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
        for ev in (EV_KEY, EV_REL, EV_ABS):
            fcntl.ioctl(self.fd, UI_SET_EVBIT, ev)
        for k in (BTN_LEFT, BTN_RIGHT) + KEYS:
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, k)
        for r in (REL_WHEEL, REL_WHEEL_HI_RES):
            fcntl.ioctl(self.fd, UI_SET_RELBIT, r)
        for a in (ABS_X, ABS_Y):
            fcntl.ioctl(self.fd, UI_SET_ABSBIT, a)
            # struct uinput_abs_setup { __u16 code; struct input_absinfo absinfo; }
            fcntl.ioctl(self.fd, UI_ABS_SETUP, struct.pack("HxxiiiiII", a, 0, 0, MAX, 0, 0, 0))
        fcntl.ioctl(self.fd, UI_DEV_SETUP, struct.pack("HHHH80sI", 3, 0x0627, 0x0001, 1, b"l410-bench tablet", 0))
        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        time.sleep(1.5)		# let libinput / KWin pick the device up

    def emit(self, *events):
        now = time.time()
        s, us = int(now), int((now - int(now)) * 1e6)
        buf = b"".join(struct.pack("llHHi", s, us, t, c, v) for t, c, v in events)
        os.write(self.fd, buf + struct.pack("llHHi", s, us, EV_SYN, 0, 0))

    def move(self, x, y):
        self.emit((EV_ABS, ABS_X, int(x * MAX)), (EV_ABS, ABS_Y, int(y * MAX)))

    def button(self, b, down):
        self.emit((EV_KEY, b, 1 if down else 0))

    def wheel(self, clicks):
        self.emit((EV_REL, REL_WHEEL_HI_RES, -120 * clicks), (EV_REL, REL_WHEEL, -clicks))

    def close(self):
        time.sleep(0.2)
        fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        os.close(self.fd)


def run(t, w):
    cmd = w[0]
    if cmd == "key":
        codes = [int(c) for c in w[1].split("+")]
        for c in codes:
            t.emit((EV_KEY, c, 1))
            time.sleep(0.02)
        for c in reversed(codes):
            t.emit((EV_KEY, c, 0))
            time.sleep(0.02)
        return
    x, y = float(w[1]), float(w[2])
    dur = float(w[3]) if len(w) > 3 else 0
    notches = int(w[4]) if len(w) > 4 else 3
    t.move(x, y)
    time.sleep(0.2)
    if cmd == "scroll":
        # "very fast" scrolling: 3 notches every 20 ms, 2/3 of the time down, then back up
        start = time.monotonic()
        while (el := time.monotonic() - start) < dur:
            t.wheel(notches if el < dur * 2 / 3 else -notches)
            time.sleep(0.02)
    elif cmd == "drag":
        t.button(BTN_LEFT, True)
        time.sleep(0.15)
        start = time.monotonic()
        while (el := time.monotonic() - start) < dur:
            # a Lissajous path around the start point, 125 Hz updates
            t.move(x + 0.18 * math.sin(el * 2.1), y + 0.12 * math.sin(el * 3.3))
            time.sleep(0.008)
        t.move(x, y)
        time.sleep(0.05)
        t.button(BTN_LEFT, False)
    elif cmd in ("click", "dclick"):
        for _ in range(2 if cmd == "dclick" else 1):
            t.button(BTN_LEFT, True)
            time.sleep(0.04)
            t.button(BTN_LEFT, False)
            time.sleep(0.08)


def main():
    if sys.argv[1] != "serve":
        sys.exit(__doc__)
    t = Tablet()
    with open(sys.argv[2]) as cmds, open(sys.argv[3], "w") as ack:
        for line in cmds:
            w = line.split()
            if not w:
                continue
            if w[0] == "quit":
                break
            try:
                run(t, w)
                ack.write("ok\n")
            except Exception as e:	# report, keep serving
                ack.write(f"error {e}\n")
            ack.flush()
    t.close()


if __name__ == "__main__":
    main()
