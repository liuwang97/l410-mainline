#!/usr/bin/python3
# tweak.py <affinity|rr|rmain> [cpus]: Chromium's frame-critical threads (renderer Compositor, GPU
# process main + VizCompositorThread, IO threads) off the little cores; rr also makes them SCHED_RR 1;
# rmain instead pins only the renderer main threads (JS, style, layout, paint).
import os, re, sys
mode = sys.argv[1]; cpus = set(int(c) for c in (sys.argv[2] if len(sys.argv) > 2 else "4-7").replace("-", ",").split(","))
if "-" in (sys.argv[2] if len(sys.argv) > 2 else "4-7"):
    a, b = (sys.argv[2] if len(sys.argv) > 2 else "4-7").split("-"); cpus = set(range(int(a), int(b) + 1))
CRIT = {"Compositor", "VizCompositorTh", "Chrome_ChildIOT", "Chrome_IOThread"}
# rmain: only the renderer main threads (CrRendererMain: JS, style, layout, paint), affinity only
if mode == "rmain":
    CRIT = set()
n = 0
for p in os.listdir("/proc"):
    if not p.isdigit(): continue
    try:
        if open(f"/proc/{p}/comm").read().strip() != "chromium": continue
        cmd = open(f"/proc/{p}/cmdline").read().replace("\0", " ")
    except OSError: continue
    m = re.search(r"--type=(\S+)", cmd); typ = m.group(1) if m else "browser"
    for t in os.listdir(f"/proc/{p}/task"):
        try: c = open(f"/proc/{p}/task/{t}/comm").read().strip()
        except OSError: continue
        # a process main thread keeps the process comm ("chromium"): match it by tid == pid
        if (mode == "rmain" and typ == "renderer" and t == p) or \
           (mode != "rmain" and (c in CRIT or (typ == "gpu-process" and t == p))):
            try:
                os.sched_setaffinity(int(t), cpus)
                if mode == "rr":
                    os.sched_setscheduler(int(t), os.SCHED_RR, os.sched_param(1))
                n += 1
            except OSError as e:
                print(f"{typ}/{c} {t}: {e}")
print(f"tweak {mode} cpus {sorted(cpus)}: {n} threads")
