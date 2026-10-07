#!/usr/bin/python3
# thrsample.py <seconds> <out>: per-thread CPU of chromium/firefox/kwin/Xwayland, sampled every
# 20 ms: CPU %, share of that time on little (0-3) / mid (4-5) / big (6-7) cores, nice, RT prio.
import os, sys, time
dur, out = float(sys.argv[1]), sys.argv[2]
NAMES = ("chromium", "kwin_wayland", "Xwayland", "firefox-esr", "firefox", "plasmashell")
HZ = os.sysconf("SC_CLK_TCK")
def procs():
    r = {}
    for p in os.listdir("/proc"):
        if not p.isdigit(): continue
        try: c = open(f"/proc/{p}/comm").read().strip()
        except OSError: continue
        if c in NAMES or c.startswith("chromium") or c.startswith("Web Content") or c == "Isolated Web Co":
            try: cmd = open(f"/proc/{p}/cmdline").read().split("\0")
            except OSError: continue
            typ = next((a[7:] for a in cmd if a.startswith("--type=")), "browser" if "chromium" in c else c)
            r[p] = typ
    return r
def stat(p, t):
    s = open(f"/proc/{p}/task/{t}/stat").read()
    comm = s[s.index("(") + 1:s.rindex(")")]
    f = s[s.rindex(")") + 2:].split()
    # f[11]=utime f[12]=stime f[16]=nice f[36]=processor f[37]=rt_priority f[38]=policy
    return comm, int(f[11]) + int(f[12]), int(f[16]), int(f[36]), int(f[37]), int(f[38])
# GPU busy time per process from panfrost fdinfo (needs panfrost profiling=1), appended to thrsample output
def gpu_snap(pids):
    r = {}
    for p, typ in pids.items():
        try: fds = os.listdir(f"/proc/{p}/fdinfo")
        except OSError: continue
        for fd in fds:
            try: txt = open(f"/proc/{p}/fdinfo/{fd}").read()
            except OSError: continue
            if "drm-driver:\tpanfrost" not in txt: continue
            kv = dict(l.split(":", 1) for l in txt.splitlines() if ":" in l)
            cid = kv.get("drm-client-id", "").strip()
            ns = sum(int(kv.get(k, "0 ns").split()[0]) for k in ("drm-engine-fragment", "drm-engine-vertex-tiler"))
            frag = int(kv.get("drm-engine-fragment", "0 ns").split()[0])
            name = open(f"/proc/{p}/comm").read().strip()
            r[cid] = (name, frag, ns)
    return r

acc = {}
P = procs(); last = {}
g0 = gpu_snap(P); tg0 = time.time()
t_end = time.time() + dur
while time.time() < t_end:
    for p, typ in P.items():
        try: tids = os.listdir(f"/proc/{p}/task")
        except OSError: continue
        for t in tids:
            try: comm, ticks, nice, cpu, rtp, pol = stat(p, t)
            except (OSError, ValueError): continue
            k = (p, t)
            if k in last:
                d = ticks - last[k]
                a = acc.setdefault(k, {"typ": typ, "comm": comm, "t": 0, "cl": [0, 0, 0], "nice": nice, "rt": rtp, "pol": pol})
                a["t"] += d
                a["cl"][0 if cpu < 4 else 1 if cpu < 6 else 2] += d
            last[k] = ticks
    time.sleep(0.02)
g1 = gpu_snap(P); tg = time.time() - tg0
with open(out, "w") as o:
    per = {}
    for c, (n, f, t) in g1.items():
        if c in g0:
            a = per.setdefault(n, [0, 0]); a[0] += f - g0[c][1]; a[1] += t - g0[c][2]
    o.write("gpu busy: " + ", ".join(f"{n} frag {v[0]/1e9/tg*100:.0f}% all {v[1]/1e9/tg*100:.0f}%" for n, v in sorted(per.items(), key=lambda x: -x[1][1])) + "\n")
    o.write(f"{'cpu%':>6} {'L/M/B %':>12} {'nice':>4} {'rt':>3}  process/thread\n")
    for k, a in sorted(acc.items(), key=lambda x: -x[1]["t"])[:22]:
        if a["t"] == 0: break
        pct = a["t"] / HZ / dur * 100
        cl = "/".join(f"{c * 100 // max(a['t'], 1)}" for c in a["cl"])
        o.write(f"{pct:6.1f} {cl:>12} {a['nice']:4d} {a['rt']:3d}  {a['typ']}/{a['comm']}\n")
