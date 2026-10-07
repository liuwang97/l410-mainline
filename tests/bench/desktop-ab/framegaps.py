#!/usr/bin/python3
# framegaps.py <trace.json.gz> <kwin.csv>: line up Chromium's Wayland commits with KWin's frames
# (both CLOCK_MONOTONIC) and say, for every vblank during scrolling that showed no new Chromium
# frame, what Chromium was doing:
#   late      Chromium committed, but after KWin had started compositing for that vblank
#   cb-wait   the browser main thread was holding a ready frame, waiting for KWin's frame callback
#   main      the renderer compositor skipped the BeginFrame waiting on the main thread
#   skipped   another "did not produce" (no damage, throttled, recover latency) or a dropped frame
#   none      nothing in the trace explains it
import bisect, collections, csv, gzip, json, sys

d = json.load(gzip.open(sys.argv[1], "rt")); ev = d["traceEvents"] if isinstance(d, dict) else d
tname = {(e["pid"], e["tid"]): e["args"]["name"] for e in ev if e.get("ph") == "M" and e.get("name") == "thread_name"}
ms = lambda e: e["ts"] / 1000.0
commits = sorted(ms(e) for e in ev if e.get("name") == "WaylandBufferManagerHost::CommitOverlays")
waits, pend = [], None
for e in sorted((e for e in ev if e.get("name") in ("WaitForFrameCallback", "HandleFrameCallback")), key=lambda e: e["ts"]):
    if e["name"] == "WaitForFrameCallback" and pend is None: pend = ms(e)
    elif e["name"] == "HandleFrameCallback" and pend is not None: waits.append((pend, ms(e))); pend = None
skips = []
for e in ev:
    if e.get("name") == "Graphics.Pipeline" and e.get("ph") == "X":
        g = e.get("args", {}).get("chrome_graphics_pipeline", {})
        if "DID_NOT_PRODUCE" in str(g.get("step")):
            skips.append((ms(e), tname.get((e["pid"], e.get("tid"))), g.get("frame_skipped_reason", "-")))
skips.sort()
# Chromium's pipeline per frame: viz BeginFrame issue -> renderer submit -> viz draw -> browser commit
stage = collections.defaultdict(dict)
for e in ev:
    if e.get("name") == "Graphics.Pipeline" and e.get("ph") == "X":
        g = e.get("args", {}).get("chrome_graphics_pipeline", {})
        tid = g.get("display_trace_id") or g.get("surface_frame_trace_id")
        if tid: stage[tid].setdefault(g.get("step"), ms(e))

rows = []
with open(sys.argv[2]) as f:
    r = csv.reader(f); next(r)
    for x in r:
        if len(x) >= 9:
            try: rows.append([int(v) / 1e6 for v in x])   # ns -> ms: target, flip, render start, render end, margin, refresh, ...
            except ValueError: pass
t0, t1 = commits[0], commits[-1]
kw = [x for x in rows if t0 - 50 <= x[1] <= t1 + 50]
if not kw: sys.exit("no KWin frames in the trace window: is the KWin frame log on?")
REF = kw[0][5]
starts = [x[2] for x in kw]
# which KWin frame picked up each commit: the first one that started compositing after it
shown = collections.Counter()
late = []
for c in commits:
    i = bisect.bisect_left(starts, c)
    if i < len(kw): shown[round(kw[i][1] / REF)] += 1
# walk the vblank grid between first and last commit
first, last = round(kw[0][1] / REF), round(kw[-1][1] / REF)
kwin_at = {round(x[1] / REF): x for x in kw}
cause = collections.Counter(); detail = []
for v in range(first + 1, last):
    if shown.get(v):
        continue
    vt = v * REF; frame = kwin_at.get(v)
    latch = frame[2] if frame else vt - 10.0          # KWin did not compose at all: assume ~10 ms before the vblank
    prev_latch = latch - REF
    # a commit between this vblank's latch and the vblank itself: late
    j = bisect.bisect_left(commits, latch)
    if j < len(commits) and commits[j] <= vt:
        c = "late"; info = f"commit {commits[j] - latch:+.1f} ms after KWin started"
    elif any(a < latch < b for a, b in waits):
        a, b = next((a, b) for a, b in waits if a < latch < b)
        c = "cb-wait"; info = f"waited for frame callback {a - latch:+.1f} .. {b - latch:+.1f} ms around KWin start"
    else:
        near = [s for s in skips if prev_latch - REF <= s[0] <= latch]
        if any(s[2] == "SKIPPED_REASON_WAITING_ON_MAIN" for s in near): c, info = "main", "renderer waited on main thread"
        elif near: c, info = "skipped", ", ".join(sorted({f"{s[1]}:{s[2]}" for s in near}))
        else: c, info = "none", ""
    cause[c] += 1; detail.append((round(vt - t0), c, info))
gaps = sum(cause.values())
print(f"trace {t1 - t0:.0f} ms, {len(commits)} commits, {len(kw)} KWin frames, vblanks {last - first - 1}, without a new Chromium frame {gaps}")
for c, n in cause.most_common(): print(f"  {c:8s} {n}")
for t, c, info in detail[:60]: print(f"  t={t:5d} ms {c:8s} {info}")
