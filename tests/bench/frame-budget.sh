#!/bin/bash
# 60 Hz frame budget check for the Plasma Wayland session (docs/tuning/perf-power.md).
# Run as the desktop user inside the session (passwordless sudo for debugfs):
#   ssh l410 'export XDG_RUNTIME_DIR=/run/user/${L410_UID:-1000} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${L410_UID:-1000}/bus;
#            cat > /tmp/fb.sh && kde-inhibit --power --screenSaver bash /tmp/fb.sh [seconds]' < tests/bench/frame-budget.sh
#
# Phases (small test windows appear on the screen):
#   feedback  weston-presentation-shm -f: redraw on every presentation, 60 fps expected
#   lowlat    weston-presentation-shm -p: commit right after presentation (latency mode)
#   egl       weston-simple-egl: continuous GL client (GPU + compositor)
#   idle      nothing on screen changes (power at rest)
# Per phase: present->present interval (dropped = over 1.5 frames), commit->present latency,
# kernel flip gaps (kirin_frames), boosts, CPU busy time and an energy estimate from the
# energy model (sum over clusters of busy time x power at the time-weighted frequency).
# With KWIN_LOG_PERFORMANCE_DATA=1 in KWin's environment it also reports KWin's render and
# predicted times and whether KWin stayed double buffered (predicted + 2.95 ms < 16.67 ms).
DUR=${1:-10}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
T=/tmp/frame-budget; rm -rf $T; mkdir -p $T
CSV="$HOME/kwin perf statistics eDP-1.csv"
DRI=$(sudo sh -c 'grep -l "^kirin" /sys/kernel/debug/dri/*/name | head -1 | xargs dirname')
PFD=$(sudo sh -c 'grep -l "^panfrost" /sys/kernel/debug/dri/*/name | head -1 | xargs dirname')

snap() {	# snap <file>: kernel counters
	{
		echo "T $(date +%s.%N)"
		sudo cat $DRI/kirin_frames | sed -n 's/^flip gap 1:\([0-9]*\) 2:\([0-9]*\) 3:\([0-9]*\) 4+:\([0-9]*\).*/GAP \1 \2 \3 \4/p'
		sudo cat $DRI/kirin_frames | sed -n 's/^vblanks \([0-9]*\) flips \([0-9]*\)/VBL \1 \2/p'
		sudo cat $PFD/devfreq_boost | sed -n 's/^boosts idle \([0-9]*\) deadline \([0-9]*\) wait \([0-9]*\), deadlines seen \([0-9]*\)/GPUB \1 \2 \3 \4/p'
		sed -n 's/^boosts heavy \([0-9]*\) light \([0-9]*\) launch \([0-9]*\) [a-z]* \([0-9]*\), boosted \([0-9]*\) ms/PERF \1 \2 \3 \4 \5/p' /sys/kernel/l410_perf/stats
		awk '/^cpu[0-9]/ { print "CPU", substr($1, 4), $2 + $3 + $4 + $7 + $8, $5 + $6 }' /proc/stat
		for p in 0 4 6; do
			awk -v p=$p '{ print "TIS", p, $1, $2 }' /sys/devices/system/cpu/cpufreq/policy$p/stats/time_in_state
		done
		awk '{ s = $1 == "*" ? $2 : $1; gsub(":", "", s); if (s ~ /^[0-9]+$/) print "GTIS", s, $NF }' /sys/class/devfreq/*.mali/trans_stat 2>/dev/null
		sudo sh -c 'for d in /sys/kernel/debug/energy_model/cpu*; do c=${d##*/cpu}; for s in $d/ps:*; do echo "EM $c ${s##*ps:} $(cat $s/power)"; done; done'
		ddr=$(ls -d /sys/class/devfreq/*ddr* 2>/dev/null | head -1)
		[ -n "$ddr" ] && awk '{ s = $1 == "*" ? $2 : $1; gsub(":", "", s); if (s ~ /^[0-9]+$/) print "DTIS", s, $NF }' $ddr/trans_stat
		[ -f "$CSV" ] && echo "CSVL $(wc -l < "$CSV")"
	} > $1
}

run_phase() {	# run_phase <name> <command...>
	local n=$1; shift
	snap $T/$n.a
	if [ $# -gt 0 ]; then
		timeout -k 2 $DUR stdbuf -oL "$@" > $T/$n.out 2>&1
	else
		sleep $DUR
	fi
	snap $T/$n.b
}

sleep 2
run_phase feedback weston-presentation-shm -f
run_phase lowlat weston-presentation-shm -p
run_phase egl weston-simple-egl
sleep 2
run_phase idle
[ -f "$CSV" ] && cp "$CSV" $T/kwin.csv

python3 - $T "$DUR" <<'PY'
import os, re, sys
T, dur = sys.argv[1], float(sys.argv[2])
FRAME = 1000 / 60

def load(f):
    d = {"GAP": None, "VBL": None, "GPUB": None, "PERF": None, "CPU": {}, "TIS": {}, "EM": {}, "GTIS": {}, "DTIS": {}, "CSVL": None, "T": 0}
    for l in open(f):
        w = l.split()
        k = w[0]
        if k in ("GAP", "VBL", "GPUB", "PERF"):
            d[k] = list(map(int, w[1:]))
        elif k == "T":
            d["T"] = float(w[1])
        elif k == "CPU":
            d["CPU"][int(w[1])] = (int(w[2]), int(w[3]))
        elif k == "TIS":
            d["TIS"][(int(w[1]), int(w[2]))] = int(w[3])
        elif k == "EM":
            d["EM"][(int(w[1]), int(w[2]))] = int(w[3])
        elif k == "GTIS":
            d["GTIS"][int(w[1])] = int(w[2])
        elif k == "DTIS":
            d["DTIS"][int(w[1])] = int(w[2])
        elif k == "CSVL":
            d["CSVL"] = int(w[1])
    return d

def energy(a, b):
    """mW estimate: per cluster, busy CPU-seconds x power at the time-weighted frequency"""
    hz = os.sysconf("SC_CLK_TCK")
    el = b["T"] - a["T"]
    total, parts = 0.0, []
    for first, cpus in ((0, range(0, 4)), (4, range(4, 6)), (6, range(6, 8))):
        busy = sum(b["CPU"][c][0] - a["CPU"][c][0] for c in cpus) / hz	# CPU-seconds
        tis = {f: b["TIS"].get((first, f), 0) - a["TIS"].get((first, f), 0) for (p, f) in b["TIS"] if p == first}
        t = sum(tis.values())
        if t <= 0:
            continue
        # power at each OPP from the energy model (uW), time weighted
        pw = sum(tis[f] * b["EM"].get((first, f), 0) for f in tis) / t / 1000
        mw = busy / el * pw
        parts.append(f"c{first} {busy / el * 100:.0f}%busy@{sum(f * tis[f] for f in tis) / t / 1000:.0f}MHz {mw:.0f}mW")
        total += mw
    return total, parts

def pres(name):
    f = f"{T}/{name}.out"
    if not os.path.exists(f):
        return ""
    c, p = [], []
    for l in open(f):
        m = re.search(r"c2p\s+(\d+) ms.*p2p\s+(\d+) us", l)
        if m:
            c.append(int(m.group(1))); p.append(int(m.group(2)) / 1000)
    c, p = c[5:], p[5:]
    if not p:
        fps = re.findall(r"([\d.]+) fps", open(f).read())
        return f"fps {fps[-1]}" if fps else "no output"
    drop = sum(x > 1.5 * FRAME for x in p)
    ps = sorted(p)
    cs = sorted(c)
    return (f"frames {len(p)} dropped {drop} p2p med {ps[len(ps)//2]:.1f} max {ps[-1]:.1f} ms, "
            f"c2p med {cs[len(cs)//2]} ms p90 {cs[int(len(cs)*.9)]} max {cs[-1]}")

def kwin(a, b):
    f = f"{T}/kwin.csv"
    if not os.path.exists(f) or a["CSVL"] is None:
        return ""
    rows = [l.strip().split(",") for l in open(f)][a["CSVL"]:b["CSVL"]]
    d = []
    for r in rows:
        try:
            d.append([int(x) for x in r[:9]])
        except ValueError:
            pass
    if not d:
        return "kwin: no frames"
    rt = sorted((r[3] - r[2]) / 1e6 for r in d)
    pr = sorted(r[8] / 1e6 for r in d)
    dbl = sum(1 for r in d if r[8] / 1e6 + 2.95 < FRAME)
    q = lambda v, x: v[min(int(len(v) * x), len(v) - 1)]
    return (f"kwin frames {len(d)} render med {q(rt,.5):.2f} p99 {q(rt,.99):.2f} max {rt[-1]:.2f} ms, "
            f"predicted med {q(pr,.5):.2f} max {pr[-1]:.2f}, double-buffered {dbl * 100 / len(d):.1f}%")

for n in ("feedback", "lowlat", "egl", "idle"):
    a, b = load(f"{T}/{n}.a"), load(f"{T}/{n}.b")
    gap = [y - x for x, y in zip(a["GAP"], b["GAP"])] if a["GAP"] and b["GAP"] else []
    gb = [y - x for x, y in zip(a["GPUB"], b["GPUB"])] if a["GPUB"] and b["GPUB"] else []
    pb = [y - x for x, y in zip(a["PERF"], b["PERF"])] if a["PERF"] and b["PERF"] else []
    mw, parts = energy(a, b)
    gt = {f: b["GTIS"].get(f, 0) - a["GTIS"].get(f, 0) for f in b["GTIS"]}
    gsum = sum(gt.values()) or 1
    gavg = sum(f * t for f, t in gt.items()) / gsum / 1e6
    dt = {f: b["DTIS"].get(f, 0) - a["DTIS"].get(f, 0) for f in b["DTIS"]}
    dsum = sum(dt.values())
    davg = f" ddr avg {sum(f * t for f, t in dt.items()) / dsum / 1e6:.0f} MHz" if dsum else ""
    print(f"== {n}: {pres(n)}")
    if gap:
        print(f"   flips: gap1 {gap[0]} gap2 {gap[1]} gap3 {gap[2]} gap4+ {gap[3]}")
    print(f"   boosts: gpu idle/deadline/wait {gb[:3]} deadlines {gb[3] if len(gb) > 3 else '-'}; input heavy/light {pb[:2]} launch {pb[2:3]} frame {pb[3:4]}")
    print(f"   cpu est {mw:.0f} mW ({'; '.join(parts)}); gpu avg {gavg:.0f} MHz{davg}")
    k = kwin(a, b)
    if k:
        print(f"   {k}")
PY
