#!/usr/bin/python3
# framecause.py <trace.json.gz>: why Chromium frames went missing while scrolling
#  - cc PipelineReporter states / drop reasons, only frames with scroll_state != SCROLL_NONE
#  - frame_skipped_reason of BeginFrames that produced no frame (renderer cc, viz)
#  - WaylandFrameManager: how often and how long the browser main thread waited for KWin's frame callback
import collections, gzip, json, sys
d = json.load(gzip.open(sys.argv[1], "rt")); ev = d["traceEvents"] if isinstance(d, dict) else d
tname = {(e["pid"], e["tid"]): e["args"]["name"] for e in ev if e.get("ph") == "M" and e.get("name") == "thread_name"}
st = collections.Counter(); keys = set()
for e in ev:
    if e.get("name") == "PipelineReporter" and e.get("ph") in ("b", "X"):
        fr = e.get("args", {}).get("frame_reporter", {})
        keys |= set(fr)
        if fr.get("scroll_state", "SCROLL_NONE") != "SCROLL_NONE" or fr.get("affects_smoothness"):
            st[(fr.get("state"), fr.get("frame_drop_reason", "-"), fr.get("scroll_state"))] += 1
print("frame_reporter fields:", sorted(keys))
print("== PipelineReporter (scrolling or affects_smoothness)")
for k, n in st.most_common(): print(f"{n:5d} {k}")
sk = collections.Counter()
for e in ev:
    if e.get("name") == "Graphics.Pipeline" and e.get("ph") == "X":
        g = e.get("args", {}).get("chrome_graphics_pipeline", {})
        if "DID_NOT_PRODUCE" in str(g.get("step")):
            sk[(tname.get((e["pid"], e.get("tid"))), g.get("frame_skipped_reason", "-"))] += 1
print("== BeginFrames that produced nothing"); [print(f"{n:5d} {k}") for k, n in sk.most_common()]
# frame callback waits: instant WaitForFrameCallback, then HandleFrameCallback
wl = sorted([e for e in ev if e.get("name") in ("WaitForFrameCallback", "HandleFrameCallback", "WaylandBufferManagerHost::CommitOverlays")], key=lambda e: e["ts"])
waits = []; pending = None
for e in wl:
    if e["name"] == "WaitForFrameCallback" and pending is None: pending = e["ts"]
    elif e["name"] == "HandleFrameCallback" and pending is not None: waits.append((e["ts"] - pending) / 1000); pending = None
if waits:
    w = sorted(waits)
    print(f"== waits for KWin frame callback: {len(w)}, med {w[len(w)//2]:.1f} ms, p90 {w[int(len(w)*.9)]:.1f}, max {w[-1]:.1f}")
com = [e["ts"] / 1000 for e in wl if e["name"] == "WaylandBufferManagerHost::CommitOverlays"]
iv = sorted(b - a for a, b in zip(com, com[1:]))
print(f"== wl commits {len(com)}: interval med {iv[len(iv)//2]:.1f} ms; >25 ms: {sum(1 for x in iv if x > 25)}, >42 ms: {sum(1 for x in iv if x > 42)}")
