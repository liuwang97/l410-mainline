#!/usr/bin/env python3
# Copy to the L410 and run as root while hci0 is up (BFGX heartbeat-timeout investigation).
# Precise-timing HCI stress for the hi110x BFGX sleep/wake handshake.
#   bt-hcistress.py sweep <rounds>   : cmd, then next cmd at 1500 ms + delta (delta -10..+60 ms, 2 ms steps)
#   bt-hcistress.py random <seconds> : cmds at random gaps 0..2.5 s
# Stops at the first command that gets no Command Complete within 3 s.
import socket, struct, time, random, sys, os, select

HCI_FILTER = 2
def open_hci():
    s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
    s.bind((0,))
    # type mask: event packets; event mask: all
    flt = struct.pack("<IIIHxx", 1 << 4, 0xffffffff, 0xffffffff, 0)
    s.setsockopt(socket.SOL_HCI, HCI_FILTER, flt)
    return s

def cmd(s, ogf=0x04, ocf=0x0001, timeout=3.0):
    op = (ogf << 10) | ocf
    t0 = time.monotonic()
    s.send(struct.pack("<BHB", 1, op, 0))
    while True:
        left = t0 + timeout - time.monotonic()
        if left <= 0:
            return t0, None
        r, _, _ = select.select([s], [], [], left)
        if not r:
            return t0, None
        pkt = s.recv(300)
        if len(pkt) >= 6 and pkt[0] == 4 and pkt[1] == 0x0e and struct.unpack("<H", pkt[4:6])[0] == op:
            return t0, time.monotonic() - t0

def kmsg(msg):
    try:
        with open("/dev/kmsg", "w") as f:
            f.write("hcistress: " + msg + "\n")
    except OSError:
        pass

def fail(what):
    print("FAIL", what, flush=True)
    kmsg("FAIL " + what)
    sys.exit(1)

s = open_hci()
mode = sys.argv[1]
n = 0
lat = []
if mode == "sweep":
    for r in range(int(sys.argv[2])):
        for d in range(-10, 62, 2):
            t0, dt = cmd(s)
            if dt is None: fail("round %d delta %d first" % (r, d))
            target = t0 + 1.5 + d / 1000.0
            while time.monotonic() < target - 0.002:
                time.sleep(0.001)
            while time.monotonic() < target:
                pass
            t1, dt = cmd(s)
            if dt is None: fail("round %d delta %d second" % (r, d))
            lat.append(dt); n += 2
        print("round %d ok, %d cmds, max lat %.1f ms" % (r, n, max(lat) * 1000), flush=True)
else:
    end = time.monotonic() + float(sys.argv[2])
    while time.monotonic() < end:
        t0, dt = cmd(s)
        if dt is None: fail("cmd %d" % n)
        lat.append(dt); n += 1
        time.sleep(random.choice([0, 0.001, 0.01, 0.05, random.uniform(0, 2.5), random.uniform(1.45, 1.6)]))
        if n % 200 == 0:
            print("%d cmds ok, max lat %.1f ms" % (n, max(lat) * 1000), flush=True)
print("done %d cmds, max lat %.1f ms" % (n, max(lat) * 1000))
