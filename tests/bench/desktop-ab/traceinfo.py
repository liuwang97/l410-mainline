#!/usr/bin/python3
# traceinfo.py <trace.json.gz>: which processes/threads and events a Chrome trace holds (to pick
# the events framegaps.py lines up with KWin's frame log)
import collections, gzip, json, sys
d = json.load(gzip.open(sys.argv[1], "rt"))
ev = d["traceEvents"] if isinstance(d, dict) else d
pname, tname = {}, {}
for e in ev:
    if e.get("ph") == "M" and e.get("name") == "process_name":
        pname[e["pid"]] = e["args"]["name"]
    if e.get("ph") == "M" and e.get("name") == "thread_name":
        tname[(e["pid"], e["tid"])] = e["args"]["name"]
ts = [e["ts"] for e in ev if e.get("ph") not in ("M",) and "ts" in e]
print(f"{len(ev)} events, {min(ts) / 1e6:.3f} .. {max(ts) / 1e6:.3f} s")
c = collections.Counter()
for e in ev:
    if e.get("ph") == "M":
        continue
    c[(pname.get(e["pid"], e["pid"]), tname.get((e["pid"], e.get("tid")), e.get("tid")), e.get("cat"), e.get("name"), e.get("ph"))] += 1
for (p, t, cat, name, ph), n in sorted(c.items(), key=lambda x: -x[1])[:90]:
    print(f"{n:6d}  {str(p)[:14]:14s} {str(t)[:22]:22s} {str(cat)[:28]:28s} {ph} {name}")
