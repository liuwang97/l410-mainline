#!/usr/bin/python3
"""ana.py perf.txt trig kwinlog offset pattern: per trigger, CPU time by thread and cluster in [trigger, mapped],
plus the off-CPU gaps of the busiest thread of the launched process and the DSOs it spent time in."""
import os, re, sys, collections

txt, trigf, kwinf, offf, pat = sys.argv[1:6]
OFF = float(open(offf).read())     # realtime - monotonic, s
CL = lambda c: "L" if c < 4 else ("M" if c < 6 else "B")
hdr = re.compile(r"^\s*(.+?)\s+(\d+)/(\d+)\s+\[(\d+)\]\s+([\d.]+):\s+(\S+?):?\s+(.*)$")
sw = re.compile(r"prev_comm=(.*?) prev_pid=(\d+) .*prev_state=(\S+) ==> next_comm=(.*?) next_pid=(\d+)")
wk = re.compile(r"comm=(.*?) pid=(\d+) prio")
ev = []          # (t, kind, data)
for line in open(txt, errors="replace"):
    m = hdr.match(line)
    if not m:
        continue
    comm, pid, tid, cpu, t, e, rest = m.groups()
    ev.append((float(t), int(cpu), e, comm, int(pid), int(tid), rest))
ev.sort(key=lambda x: x[0])
tid2pid, tid2comm = {}, {}
for t, cpu, e, comm, pid, tid, rest in ev:
    tid2pid[tid] = pid; tid2comm[tid] = comm
    if e.startswith("sched:sched_switch"):
        m = sw.search(rest)
        if m:
            tid2comm.setdefault(int(m.group(5)), m.group(4))

maps = []
for line in open(kwinf):
    line = re.sub(r"^js: ", "", line).split()
    if len(line) > 2 and line[0] == "L410T" and line[1] == "add" and re.search(pat, " ".join(line)) and (not os.environ.get("NORMAL") or "type=0" in line):
        maps.append(int(line[2]) / 1000 - OFF)
trigs = [(l.split()[0], int(l.split()[1]) / 1000 - OFF) for l in open(trigf) if l.strip()]

for name, t0 in trigs:
    t1 = next((m for m in maps if m >= t0), None)
    if t1 is None or t1 - t0 > 10:
        print(f"## {name}: no window mapped"); continue
    print(f"## {name}: trigger -> mapped {1000*(t1-t0):.0f} ms")
    run = collections.defaultdict(lambda: collections.Counter())   # tid -> cluster -> s
    cur = {}                                                         # cpu -> (tid, since)
    offs = collections.defaultdict(list)                             # tid -> [(off_t, state)]
    gaps = collections.defaultdict(list)                             # tid -> [(start, len, state, waker)]
    lastwaker = {}
    samples = collections.defaultdict(collections.Counter)           # pid -> dso -> n
    syms = collections.defaultdict(collections.Counter)
    for t, cpu, e, comm, pid, tid, rest in ev:
        if t < t0 - 0.05 or t > t1:
            if t > t1:
                break
            # still track who is running before the window
        if e.startswith("sched:sched_switch"):
            m = sw.search(rest)
            if not m: continue
            prev, nxt, state = int(m.group(2)), int(m.group(5)), m.group(3)
            if cpu in cur and cur[cpu][0] == prev and t > t0:
                run[prev][CL(cpu)] += t - max(cur[cpu][1], t0)
            if prev and t >= t0:
                offs[prev] = (t, state)
            cur[cpu] = (nxt, t)
            if nxt and isinstance(offs.get(nxt), tuple) and t >= t0:
                ot, st = offs.pop(nxt)
                gaps[nxt].append((ot - t0, t - ot, st, lastwaker.get(nxt, "?")))
        elif e.startswith("sched:sched_wakeup"):
            m = wk.search(rest)
            if m: lastwaker[int(m.group(2))] = f"{comm}/{tid}"
        elif e.startswith("cpu-clock") and t >= t0:
            dso = re.search(r"\(([^)]*)\)\s*$", rest)
            d = dso.group(1).split("/")[-1] if dso else "?"
            samples[pid][d] += 1
            s = re.search(r"^\s*[0-9a-f]+\s+(.*?)\s+\(", rest)
            if s: syms[pid][s.group(1)[:60] + "  [" + d[:24] + "]"] += 1
    for cpu, (tid, since) in cur.items():
        if tid and since < t1: run[tid][CL(cpu)] += t1 - max(since, t0)
    tot = sorted(run.items(), key=lambda kv: -sum(kv[1].values()))
    print("   thread                         pid      ms   L/M/B ms")
    for tid, c in tot[:14]:
        s = sum(c.values()) * 1000
        if s < 3: break
        print(f"   {tid2comm.get(tid,'?')[:22]:22s}/{tid:<7d} {tid2pid.get(tid,0):7d} {s:6.0f}   "
              f"{c['L']*1000:.0f}/{c['M']*1000:.0f}/{c['B']*1000:.0f}")
    allL = sum(c['L'] for c in run.values()) * 1000; allM = sum(c['M'] for c in run.values()) * 1000
    allB = sum(c['B'] for c in run.values()) * 1000
    print(f"   all threads: L {allL:.0f} / M {allM:.0f} / B {allB:.0f} ms (window {1000*(t1-t0):.0f} ms x 8 CPUs)")
    # the launched process = pid of the top thread outside kwin
    top = next((tid for tid, c in tot if tid2comm.get(tid, "") not in ("kwin_wayland", "swapper") and not tid2comm.get(tid, "").startswith(("kworker", "perf"))), None)
    if top:
        p = tid2pid.get(top, top)
        print(f"   off-CPU gaps > 4 ms of {tid2comm.get(top)}/{top} (start ms after trigger, len, state, last waker):")
        for st, ln, s, w in gaps[top]:
            if ln > 0.004: print(f"     +{st*1000:6.0f}  {ln*1000:5.0f} ms  {s:2s} woken by {w}")
        n = sum(samples[p].values())
        if n:
            print(f"   pid {p} cpu-clock samples {n} (~{n/4:.0f} ms): top DSOs: " +
                  ", ".join(f"{d} {100*k/n:.0f}%" for d, k in samples[p].most_common(8)))
            print("   top symbols: " + "; ".join(f"{s} {k}" for s, k in syms[p].most_common(10)))
