#!/usr/bin/python3
"""ffprof.py profile.json [until_ms]: Gecko startup profile -> GeckoMain (parent) longest markers and
sample breakdown by innermost labelled/JS frame and by category, up to until_ms after process start."""
import json, sys, collections
p = json.load(open(sys.argv[1])); until = float(sys.argv[2]) if len(sys.argv) > 2 else 3000
meta = p["meta"]; cats = [c["name"] for c in meta.get("categories", [])]
def tables(th):
    st = th["stringTable"] if "stringTable" in th else th.get("stringArray", [])
    return st
def schema_rows(tab):
    s = tab["schema"]; return s, tab["data"]
th = next(t for t in p["threads"] if t["name"] == "GeckoMain")
strs = th["stringTable"]
t0 = th.get("processStartupTime", 0)
# markers
ms, md = schema_rows(th["markers"])
mk = []
for row in md:
    name = strs[row[ms["name"]]]
    st = row[ms["startTime"]] if "startTime" in ms else row[ms.get("time", 1)]
    en = row[ms["endTime"]] if "endTime" in ms and ms["endTime"] < len(row) else None
    if st is None: continue
    if en is not None and en - st > 8 and st - t0 < until:
        data = row[ms["data"]] if "data" in ms and ms["data"] < len(row) else None
        extra = ""
        if isinstance(data, dict):
            for k in ("name", "category", "eventType", "url", "filename", "stack"):
                if k in data and isinstance(data[k], str): extra = data[k][:60]; break
        mk.append((en - st, st - t0, name, extra))
print("longest GeckoMain markers (dur ms, start ms, name):")
for d, s, n, e in sorted(mk, reverse=True)[:30]:
    print(f"  {d:7.1f} {s:7.0f}  {n[:40]:40s} {e}")
# samples
ss, sd = schema_rows(th["samples"]); fs, fd = schema_rows(th["frameTable"]); ks, kd = schema_rows(th["stackTable"])
fn = lambda f: strs[fd[f][fs["location"]]]
by_frame = collections.Counter(); by_cat = collections.Counter(); by_top = collections.Counter(); n = 0
for row in sd:
    t = row[ss["time"]]; stk = row[ss["stack"]]
    if stk is None or t - t0 > until: continue
    n += 1
    leaf = stk; labels = []
    s = stk
    while s is not None:
        f = kd[s][ks["frame"]]; labels.append(fn(f)); s = kd[s][ks["prefix"]]
    cat = kd[stk][ks["category"]] if "category" in ks else None
    by_cat[cats[cat] if cat is not None and cat < len(cats) else "?"] += 1
    # innermost non-address frame
    lab = next((l for l in labels if not l.startswith("0x")), "?")
    by_frame[lab[:80]] += 1
    # outermost meaningful label below the root (phase)
    outer = [l for l in reversed(labels) if not l.startswith("0x")]
    by_top[" > ".join(x[:40] for x in outer[1:4])] += 1
iv = meta.get("interval", 1)
print(f"\nGeckoMain samples to {until:.0f} ms: {n} (~{n*iv:.0f} ms at {iv} ms)")
print("by category: " + ", ".join(f"{c} {k*iv:.0f}" for c, k in by_cat.most_common(10)))
print("innermost labelled frames:")
for l, k in by_frame.most_common(25): print(f"  {k*iv:6.0f}  {l}")
print("phases (outer labels):")
for l, k in by_top.most_common(20): print(f"  {k*iv:6.0f}  {l}")
