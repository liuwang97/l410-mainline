#!/bin/bash
# Desktop latency probe for the Plasma Wayland session (6.18 Debian).
# Run as the desktop user inside the running session, e.g.
#   ssh l410 'export XDG_RUNTIME_DIR=/run/user/${L410_UID:-1000} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${L410_UID:-1000}/bus;
#            cat > /tmp/dl.sh && kde-inhibit --power --screenSaver bash /tmp/dl.sh' < tests/bench/desktop-latency.sh
# Opens small test windows on the screen for ~25 s.
#
# Prints commit->present latency (c2p) and present->present interval (p2p) from
# weston-presentation-shm in three modes. If KWin runs with
# KWIN_LOG_PERFORMANCE_DATA=1 (see docs/tuning/desktop-latency.md), it also cuts
# ~/kwin perf statistics eDP-1.csv by phase and prints KWin's own measured and
# predicted render times.
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
T=/tmp/desktop-latency; mkdir -p $T
CSV="$HOME/kwin perf statistics eDP-1.csv"
: > $T/marks
mark() { [ -f "$CSV" ] && echo "$1 $(wc -l < "$CSV")" >> $T/marks; }
cat > $T/stat.py <<'PY'
import re, sys
c=[];p=[]
for l in open(sys.argv[1]):
    m=re.search(r'c2p\s+(\d+) ms.*p2p\s+(\d+) us', l)
    if m: c.append(int(m.group(1))); p.append(int(m.group(2))/1000)
c=sorted(c[5:]); p=sorted(p[5:])
if c: print(f"frames {len(c)} c2p median {c[len(c)//2]} ms (min {c[0]} max {c[-1]}); p2p median {p[len(p)//2]:.1f} ms, >20ms: {sum(x>20 for x in p)}")
PY
sleep 2
mark idle
echo -n "idle (1 frame/s) c2p ms:"; timeout -s INT 8 stdbuf -oL weston-presentation-shm -i 2>&1 | grep -oE 'c2p +[0-9]+' | awk 'NR>1{printf " %s",$2}'; echo
mark feedback
timeout -s INT 6 stdbuf -oL weston-presentation-shm -f > $T/pf.txt 2>&1
echo "feedback: $(python3 $T/stat.py $T/pf.txt)"
mark lowlat
timeout -s INT 6 stdbuf -oL weston-presentation-shm -p > $T/pl.txt 2>&1
echo "lowlat:   $(python3 $T/stat.py $T/pl.txt)"
mark egl
timeout -s INT 6 stdbuf -oL weston-simple-egl > $T/se.txt 2>&1
echo "simple-egl: $(grep fps $T/se.txt | tail -1)"
mark end
[ -f "$CSV" ] || { echo "(no KWin perf CSV: KWIN_LOG_PERFORMANCE_DATA not set)"; exit 0; }
cp "$CSV" $T/perf.csv
python3 - $T <<'PY'
import csv, sys
T = sys.argv[1]
data = list(csv.reader(open(f'{T}/perf.csv')))[1:]
marks = [l.split() for l in open(f'{T}/marks')]
marks = [(n, int(c) - 1) for n, c in marks]
q = lambda v, p: sorted(v)[min(int(len(v) * p), len(v) - 1)]
print(f"{'phase':10s} {'frames':>6s} {'render med':>10s} {'p90':>6s} {'max':>6s} {'pred med':>9s} {'p90':>6s} {'start->flip':>11s} {'missed':>6s}")
for (n, a), (_, b) in zip(marks, marks[1:]):
    d = [[int(x) for x in r[:9]] for r in data[a:b]]
    if not d: continue
    rt = [(r[3] - r[2]) / 1e6 for r in d]; pr = [r[8] / 1e6 for r in d]; sf = [(r[1] - r[2]) / 1e6 for r in d]
    miss = sum(1 for r in d if r[1] - r[0] > r[5] / 2)
    print(f"{n:10s} {len(d):6d} {q(rt,.5):10.2f} {q(rt,.9):6.2f} {max(rt):6.2f} {q(pr,.5):9.2f} {q(pr,.9):6.2f} {q(sf,.5):11.2f} {miss:6d}")
PY
