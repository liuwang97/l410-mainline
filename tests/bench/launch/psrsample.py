#!/usr/bin/python3
"""psrsample.py NAME SECONDS: wait for process NAME, then sample which CPU its main thread runs on
(state R only) every 5 ms; print the share of running samples per cluster (L 0-3, M 4-5, B 6-7)."""
import os, sys, time, collections
name, secs = sys.argv[1], float(sys.argv[2])
def find():
    for p in os.listdir("/proc"):
        if p.isdigit():
            try:
                if open(f"/proc/{p}/comm").read().strip() == name: return p
            except OSError: pass
t0 = time.time(); pid = None
while not pid and time.time() - t0 < 5: pid = find(); time.sleep(0.002)
if not pid: sys.exit("not found")
c = collections.Counter(); end = time.time() + secs
while time.time() < end:
    try: f = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
    except OSError: break
    if f[0] == "R":
        cpu = int(f[36]); c["L" if cpu < 4 else "M" if cpu < 6 else "B"] += 1
    time.sleep(0.005)
n = sum(c.values()) or 1
print(f"{name} {pid}: running samples {n}: " + ", ".join(f"{k} {100*v//n}%" for k, v in sorted(c.items())))
