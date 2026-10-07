#!/usr/bin/python3
# tracepeek.py <trace.json.gz>: event names in the wayland category, sample args of Graphics.Pipeline per thread, EventLatency stages
import collections, gzip, json, sys
d = json.load(gzip.open(sys.argv[1], "rt")); ev = d["traceEvents"] if isinstance(d, dict) else d
pname = {e["pid"]: e["args"]["name"] for e in ev if e.get("ph") == "M" and e.get("name") == "process_name"}
tname = {(e["pid"], e["tid"]): e["args"]["name"] for e in ev if e.get("ph") == "M" and e.get("name") == "thread_name"}
c = collections.Counter((e.get("name"), e.get("ph"), tname.get((e["pid"], e.get("tid")))) for e in ev if "wayland" in str(e.get("cat")))
print("== wayland events"); [print(f"{n:5d} {k}") for k, n in c.most_common(30)]
print("== Graphics.Pipeline args (first per thread/ph)")
seen = set()
for e in ev:
    if e.get("name") == "Graphics.Pipeline":
        k = (pname.get(e["pid"]), tname.get((e["pid"], e.get("tid"))), e.get("ph"))
        if k not in seen:
            seen.add(k); print(k, json.dumps(e.get("args"))[:300])
steps = collections.Counter()
for e in ev:
    if e.get("name") == "Graphics.Pipeline" and e.get("ph") == "X":
        a = e.get("args", {}); g = a.get("chrome_graphics_pipeline", a)
        steps[(tname.get((e["pid"], e.get("tid"))), str(g.get("step")))] += 1
print("== steps"); [print(f"{n:5d} {k}") for k, n in steps.most_common(30)]
el = collections.Counter(e.get("name") for e in ev if "input.scrolling" in str(e.get("cat")) or e.get("name") == "EventLatency")
print("== EventLatency family"); [print(f"{n:5d} {k}") for k, n in el.most_common(40)]
for e in ev:
    if e.get("name") == "EventLatency" and e.get("ph") == "b":
        print("EventLatency args:", json.dumps(e.get("args"))[:400]); break
pr = [e for e in ev if e.get("name") in ("PipelineReporter",)]
print("== PipelineReporter", len(pr), json.dumps(pr[0].get("args"))[:400] if pr else "")
