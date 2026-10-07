# predictor-replay.py [kwin perf csv]: replay KWin's render times through the 6.7 predictor and the !8517 one (mean + 3 sd of last 100)
import csv, math, statistics as st
from collections import deque
rows = []
import sys
with open(sys.argv[1] if len(sys.argv) > 1 else "kwin perf statistics eDP-1.csv") as f:
    r = csv.reader(f); next(r)
    for x in r:
        if len(x) < 9: continue
        try: rows.append([int(v) for v in x])
        except ValueError: pass
REF = rows[0][5] / 1e6
def old():
    res = var = 0.0; last = None; out = []
    for x in rows:
        rt = (x[3] - x[2]) / 1e6; t = x[1] / 1e6
        out.append(res + 2 * var)              # prediction used for this frame (before adding it)
        dt = (t - last) if last is not None else 10000.0; last = t
        vr = min(max(dt / 6000, 0.001), 0.1)
        d = max(rt - res, 0)
        var = max(d * vr + var * (1 - vr), d)
        rr = min(max(dt / 500, 0.01), 1.0)
        res = rt * rr + res * (1 - rr)
    return out
def new():
    h = deque(maxlen=100); out = []; res = 0.0
    for x in rows:
        out.append(res)
        h.append((x[3] - x[2]) / 1e6)
        m = sum(h) / len(h)
        sd = math.sqrt(sum((v - m) ** 2 for v in h) / max(len(h) - 1, 1))
        res = m + 3 * sd
    return out
o, n = old(), new()
logged = [x[8] / 1e6 for x in rows]
rt = [(x[3] - x[2]) / 1e6 for x in rows]
margin = rows[0][4] / 1e6
def q(a, p): s = sorted(a); return s[int(len(s) * p)]
print(f"{len(rows)} frames, refresh {REF:.2f} ms, safety margin {margin:.2f} ms")
print(f"actual render     med {st.median(rt):.2f} p90 {q(rt,.9):.2f} p99 {q(rt,.99):.2f}")
print(f"6.7 (logged)      med {st.median(logged):.2f} p90 {q(logged,.9):.2f} p99 {q(logged,.99):.2f}")
print(f"6.7 (replayed)    med {st.median(o):.2f} p90 {q(o,.9):.2f} p99 {q(o,.99):.2f}")
print(f"!8517             med {st.median(n):.2f} p90 {q(n,.9):.2f} p99 {q(n,.99):.2f}")
for name, p in (("6.7", o), ("!8517", n)):
    lead = [v + margin + 1 for v in p]
    tb = sum(1 for v in lead if v > REF) / len(lead) * 100
    late = sum(1 for a, b in zip(rt, p) if a > b) / len(rt) * 100
    print(f"{name:6s}: start before vblank med {st.median(lead):.1f} ms; would need triple buffering {tb:.0f}% of frames; "
          f"render longer than predicted {late:.1f}% of frames")
for name, p in (("6.7", o), ("!8517", n)):
    miss = sum(1 for a, b in zip(rt, p) if a > b + margin + 1)
    print(f"{name:6s}: render overran prediction + margin + 1 ms (would miss the vblank) {miss} of {len(rt)} frames ({miss / len(rt) * 100:.2f}%)")
