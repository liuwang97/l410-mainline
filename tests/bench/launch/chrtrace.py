#!/usr/bin/python3
"""chrtrace.py trace.json: longest complete slices on the browser process main thread, plus startup
milestones, from a chromium --trace-startup JSON."""
import json, sys, collections
d = json.load(open(sys.argv[1]))
ev = d["traceEvents"] if isinstance(d, dict) else d
names = {}
for e in ev:
    if e.get("ph") == "M" and e.get("name") in ("process_name", "thread_name"):
        names[(e["name"], e["pid"], e.get("tid"))] = e["args"]["name"]
proc = {pid: n for (k, pid, tid), n in names.items() if k == "process_name"}
thr = {(pid, tid): n for (k, pid, tid), n in names.items() if k == "thread_name"}
t0 = min(e["ts"] for e in ev if "ts" in e and e.get("ph") in ("X", "B", "I", "i", "R", "n"))
# pair B/E
stacks = collections.defaultdict(list); slices = []
for e in sorted((e for e in ev if "ts" in e), key=lambda e: e["ts"]):
    ph = e.get("ph"); key = (e["pid"], e.get("tid"))
    if ph == "X":
        slices.append((key, e["name"], e["ts"], e.get("dur", 0)))
    elif ph == "B":
        stacks[key].append(e)
    elif ph == "E" and stacks[key]:
        b = stacks[key].pop(); slices.append((key, b["name"], b["ts"], e["ts"] - b["ts"]))
def pname(key): return f"{proc.get(key[0], key[0])}/{thr.get(key, key[1])}"
print("longest slices (start ms, dur ms, process/thread, name):")
for key, n, ts, dur in sorted(slices, key=lambda s: -s[3])[:45]:
    if dur < 15000: break
    print(f"  {(ts - t0)/1000:7.0f} {dur/1000:7.0f}  {pname(key)[:40]:40s} {n[:70]}")
print("instant/milestones:")
for e in ev:
    if e.get("ph") in ("I", "i", "R", "n") and any(k in e.get("name", "") for k in ("Startup", "FirstPaint", "first", "First", "Paint", "Visible")):
        print(f"  {(e['ts'] - t0)/1000:7.0f}  {pname((e['pid'], e.get('tid')))[:40]:40s} {e['name'][:70]}")
