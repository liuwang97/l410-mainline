# latch.py [kwin perf csv]: per continuous-animation run, flip gaps, KWin misses and how long before
# the target vblank KWin starts compositing ("latch lead"), from KWIN_LOG_PERFORMANCE_DATA output
import csv, statistics as st, sys
rows = []
import sys
with open(sys.argv[1] if len(sys.argv) > 1 else "kwin perf statistics eDP-1.csv") as f:
    r = csv.reader(f); next(r)
    for x in r:
        try: rows.append([int(v) for v in x])
        except ValueError: pass
REF = rows[0][5]
# active runs: consecutive frames <= 3 vblanks apart, lasting >= 5 s
runs = []; cur = [rows[0]]
for a, b in zip(rows, rows[1:]):
    if b[1] - a[1] <= 3.5 * REF: cur.append(b)
    else:
        if cur[-1][1] - cur[0][1] > 5e9: runs.append(cur)
        cur = [b]
if cur[-1][1] - cur[0][1] > 5e9: runs.append(cur)
print(f"refresh {REF/1e6:.3f} ms, {len(rows)} frames, {len(runs)} active runs >= 5 s")
allg = []; alln = []
for i, run in enumerate(runs):
    d = [round((b[1] - a[1]) / REF) for a, b in zip(run, run[1:])]
    lead = [(x[0] - x[2]) / 1e6 for x in run]          # target flip - render start (ms): KWin's latch point before vblank
    pred = [x[8] / 1e6 for x in run]
    missed = sum(1 for x in run if x[1] > x[0] + REF / 2)
    gaps = [j for j, v in enumerate(d) if v >= 2]
    # lead of the frame right before and after a gap vs normal
    lg = [lead[j + 1] for j in gaps]
    ln = [lead[j + 1] for j, v in enumerate(d) if v == 1]
    t0 = run[0][1]
    gt = [round((run[j + 1][1] - t0) / 1e9, 2) for j in gaps]
    print(f"run {i}: {len(run)} frames {(run[-1][1]-t0)/1e9:.1f} s, gaps2={d.count(2)} gaps3={d.count(3)}, missed {missed}; "
          f"latch lead med {st.median(lead):.1f} p90 {sorted(lead)[int(len(lead)*.9)]:.1f}; lead after gap {st.median(lg) if lg else 0:.1f} vs normal {st.median(ln):.1f}; pred med {st.median(pred):.1f}")
    allg += lg; alln += ln
print("gap times (s) of last run:", gt)
print(f"overall latch lead: normal frames med {st.median(alln):.1f} ms, frames after a gap med {st.median(allg):.1f} ms")
