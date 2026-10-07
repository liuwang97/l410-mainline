#!/bin/bash
# Real-world 60 Hz check on the Plasma Wayland session (docs/tuning/perf-power.md):
# a browser (BROWSER=chromium, the default, or firefox) on www.bilibili.com, then
#   scroll    very fast wheel scrolling of the page (3 notches / 20 ms, down then up)
#   drag      dragging the window around by its title bar
#   maximize  maximize / restore, 4 times
#   minimize  minimize / restore, 3 times
# Per phase: kernel flip gaps (a new frame every vblank = 60 fps; a gap of 2+ vblanks while
# things move is a dropped frame), KWin's own frame log (render and predicted time, missed
# target vblanks, double buffering), boosts, CPU busy x energy model, GPU and DDR frequency.
#
#   ssh l410 'export XDG_RUNTIME_DIR=/run/user/${L410_UID:-1000} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${L410_UID:-1000}/bus;
#            bash /tmp/browser-bench.sh [seconds per phase]'
# with tests/bench/uinput-bench.py as /tmp/uinput-bench.py. KWin must run with
# KWIN_LOG_PERFORMANCE_DATA=1 for the KWin columns. Needs passwordless sudo (uinput, debugfs).
DUR=${1:-8}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
T=/tmp/browser-bench; rm -rf $T; mkdir -p $T
CSV="$HOME/kwin perf statistics eDP-1.csv"
UB="sudo python3 $(dirname "$(readlink -f "$0")")/uinput-bench.py"
DRI=$(sudo sh -c 'grep -l "^kirin" /sys/kernel/debug/dri/*/name | head -1 | xargs dirname')
PFD=$(sudo sh -c 'grep -l "^panfrost" /sys/kernel/debug/dri/*/name | head -1 | xargs dirname')

kwin_js() {	# kwin_js <name> <javascript>: run a KWin script once
	echo "$2" > $T/$1.js
	qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript $1 > /dev/null 2>&1
	qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript $T/$1.js $1 > /dev/null
	qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start > /dev/null
	sleep 0.1
	qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript $1 > /dev/null 2>&1
}
BROWSER=${BROWSER:-chromium}
case $BROWSER in
chromium) BIN=chromium CLASS=chromium ;;
firefox) BIN=firefox-esr CLASS=firefox ;;
esac
FF='function ff() { for (const w of workspace.windowList()) if (w.normalWindow && String(w.resourceClass).toLowerCase().indexOf("'$CLASS'") >= 0) return w; return null; }'

snap() {
	{
		echo "T $(date +%s.%N)"
		sudo cat $DRI/kirin_frames | sed -n 's/^flip gap 1:\([0-9]*\) 2:\([0-9]*\) 3:\([0-9]*\) 4+:\([0-9]*\).*/GAP \1 \2 \3 \4/p'
		sudo cat $PFD/devfreq_boost | sed -n 's/^boosts idle \([0-9]*\) deadline \([0-9]*\) wait \([0-9]*\), deadlines seen \([0-9]*\)/GPUB \1 \2 \3 \4/p'
		sed -n 's/^boosts heavy \([0-9]*\) light \([0-9]*\) launch \([0-9]*\) [a-z]* \([0-9]*\), boosted \([0-9]*\) ms/PERF \1 \2 \3 \4 \5/p' /sys/kernel/l410_perf/stats
		awk '/^cpu[0-9]/ { print "CPU", substr($1, 4), $2 + $3 + $4 + $7 + $8, $5 + $6 }' /proc/stat
		for p in 0 4 6; do
			awk -v p=$p '{ print "TIS", p, $1, $2 }' /sys/devices/system/cpu/cpufreq/policy$p/stats/time_in_state
		done
		awk '{ s = $1 == "*" ? $2 : $1; gsub(":", "", s); if (s ~ /^[0-9]+$/) print "GTIS", s, $NF }' /sys/class/devfreq/*.mali/trans_stat
		awk '{ s = $1 == "*" ? $2 : $1; gsub(":", "", s); if (s ~ /^[0-9]+$/) print "DTIS", s, $NF }' /sys/class/devfreq/*ddr*/trans_stat 2>/dev/null
		sudo sh -c 'for d in /sys/kernel/debug/energy_model/cpu*; do c=${d##*/cpu}; for s in $d/ps:*; do echo "EM $c ${s##*ps:} $(cat $s/power)"; done; done'
		[ -f "$CSV" ] && echo "CSVL $(wc -l < "$CSV")"
	} > $1
}

# --- the browser on bilibili, placed at a known geometry
# a fresh browser on the home page every run (FRESH=0 keeps a running one)
if [ "${FRESH:-1}" = 1 ] && pgrep -x $BIN > /dev/null; then
	pkill -TERM -x $BIN; sleep 4
fi
if ! pgrep -x $BIN > /dev/null; then
	# in an app-*.scope, as Plasma starts applications (foreground uclamp, launch boost)
	if [ $BROWSER = chromium ]; then
		# own profile with the system title bar (server-side decoration: a KWin title bar)
		P=$HOME/.config/chromium-bench
		if [ ! -d $P/Default ]; then
			mkdir -p $P/Default
			echo '{"browser":{"custom_chrome_frame":false,"has_seen_welcome_page":true},"distribution":{"skip_first_run_ui":true}}' > $P/Default/Preferences
			touch "$P/First Run"
		fi
		systemd-run --user --scope -q -u app-chromium-bench-$$.scope \
			chromium --user-data-dir=$P --ozone-platform=wayland --no-first-run \
			--no-default-browser-check --disable-session-crashed-bubble --password-store=basic ${BFLAGS:-} --new-window https://www.bilibili.com/ > $T/browser.log 2>&1 &
	else
		systemd-run --user --scope -q -u app-firefox-bench-$$.scope \
			firefox-esr --new-window https://www.bilibili.com/ > $T/browser.log 2>&1 &
	fi
	sleep 25
fi
BPID=$(pgrep -x $BIN | head -1)
echo "$BROWSER $BPID in $(cut -d: -f3 /proc/$BPID/cgroup | sed 's#.*/##')"
since=$(date '+%Y-%m-%d %H:%M:%S')
kwin_js l410place "$FF
const s = workspace.virtualScreenSize, w = ff();
if (w) {
	w.minimized = false; w.setMaximize(false, false);
	w.frameGeometry = { x: Math.round(s.width * 0.12), y: Math.round(s.height * 0.08),
			    width: Math.round(s.width * 0.70), height: Math.round(s.height * 0.80) };
	workspace.activeWindow = w;
	print('L410BENCH ' + s.width + ' ' + s.height + ' ' + (w.clientGeometry.y - w.frameGeometry.y));
}"
sleep 1
read -r SW SH TB < <(journalctl --user --since "$since" --no-pager -o cat | sed -n 's/.*L410BENCH //p' | tail -1)
[ -n "$SH" ] || { echo "no $BROWSER window found"; exit 1; }
# centre of the page and a point on the title bar, as screen fractions
CX=0.47 CY=0.50
TX=0.30 TY=$(awk -v sh=$SH -v tb=${TB:-30} 'BEGIN { printf "%.4f", 0.08 + tb / 2 / sh }')
echo "screen ${SW}x${SH} (logical), title bar ${TB}px; page centre $CX,$CY title $TX,$TY"
TMAX=$(awk -v sh=$SH -v tb=${TB:-30} 'BEGIN { printf "%.4f", tb / 2 / sh }')	# title bar when maximized

# one input device for the whole run
mkfifo $T/in $T/out
$UB serve $T/in $T/out & UPID=$!
exec 3> $T/in 4< $T/out
ui() { echo "$*" >&3; read -r ack <&4; [ "$ack" = ok ] || echo "input: $* -> $ack"; }

ui move $CX $CY
# the page must have loaded (the network may lag behind a fresh boot): reload up to 3 times
caption() {
	local s=$(date '+%Y-%m-%d %H:%M:%S')
	kwin_js l410cap "$FF const w = ff(); if (w) print('L410CAP ' + w.caption);"
	journalctl --user --since "$s" --no-pager -o cat | sed -n 's/.*L410CAP //p' | tail -1
}
for r in 1 2 3; do
	c=$(caption)
	case "$c" in *bilibili*|*哔哩*) break ;; esac
	echo "page not loaded ('$c'), reloading"
	ui key 63; sleep 15
done
echo "page: $(caption)"
sleep 2

# DDR runs without polling, so its trans_stat misses the time in the current state: sample it
sampler() { while :; do cat /sys/class/devfreq/*ddr*/cur_freq 2>/dev/null; sleep 0.1; done > $1; }
begin() { snap $T/$1.a; sampler $T/$1.ddr & SPID=$!; }
end() { kill $SPID; wait $SPID 2> /dev/null; snap $T/$1.b; sed "s/.*\[\(.*\)\].*/\1/" /sys/kernel/l410_perf/mode > $T/$1.mode; }

PHASES=${PHASES:-scroll drag maximize minimize}
i=0
for ph in $PHASES; do
	i=$((i + 1)); n=$i-$ph
	case $ph in
	scroll) ui key 1; begin $n; ui scroll $CX $CY $DUR ${NOTCHES:-3}; end $n ;;
	drag) begin $n; ui drag $TX $TY $DUR; end $n ;;
	maximize)	# double click on the title bar: maximize, then restore
		begin $n
		for r in 1 2 3 4; do
			ui dclick $TX $TY; sleep 1.2
			ui dclick 0.5 $TMAX; sleep 1.2
		done
		end $n ;;
	minimize)	# Meta+PgDown; restore from a script (with a key press, as a click on the task bar)
		begin $n
		for r in 1 2 3; do
			ui key 125+109; sleep 1.2
			ui key 29
			kwin_js l410min "$FF const w = ff(); if (w) { w.minimized = false; workspace.activeWindow = w; }"; sleep 1.2
		done
		end $n ;;
	esac
	sleep 2
done
echo "$PHASES" > $T/phases
echo quit >&3
exec 3>&- 4<&-
wait $UPID
[ -f "$CSV" ] && cp "$CSV" $T/kwin.csv

python3 - $T <<'PY'
import os, sys
T = sys.argv[1]
FRAME = 1000 / 60

def load(f):
    d = {"GAP": None, "GPUB": None, "PERF": None, "CPU": {}, "TIS": {}, "EM": {}, "GTIS": {}, "DTIS": {}, "CSVL": None, "T": 0}
    for l in open(f):
        w = l.split()
        k = w[0]
        if k in ("GAP", "GPUB", "PERF"): d[k] = list(map(int, w[1:]))
        elif k == "T": d["T"] = float(w[1])
        elif k == "CPU": d["CPU"][int(w[1])] = (int(w[2]), int(w[3]))
        elif k == "TIS": d["TIS"][(int(w[1]), int(w[2]))] = int(w[3])
        elif k == "EM": d["EM"][(int(w[1]), int(w[2]))] = int(w[3])
        elif k == "GTIS": d["GTIS"][int(w[1])] = int(w[2])
        elif k == "DTIS": d["DTIS"][int(w[1])] = int(w[2])
        elif k == "CSVL": d["CSVL"] = int(w[1])
    return d

def energy(a, b):
    hz = os.sysconf("SC_CLK_TCK"); el = b["T"] - a["T"]; total = 0; parts = []
    for first, cpus in ((0, range(0, 4)), (4, range(4, 6)), (6, range(6, 8))):
        busy = sum(b["CPU"][c][0] - a["CPU"][c][0] for c in cpus) / hz
        tis = {f: b["TIS"].get((first, f), 0) - a["TIS"].get((first, f), 0) for (p, f) in b["TIS"] if p == first}
        t = sum(tis.values())
        if t <= 0: continue
        pw = sum(tis[f] * b["EM"].get((first, f), 0) for f in tis) / t / 1000
        mw = busy / el * pw; total += mw
        parts.append(f"c{first} {busy / el * 100:.0f}%@{sum(f * tis[f] for f in tis) / t / 1000:.0f}MHz")
    return total, parts

def avg(a, b, k):
    t = {f: b[k].get(f, 0) - a[k].get(f, 0) for f in b[k]}
    s = sum(t.values())
    return sum(f * v for f, v in t.items()) / s / 1e6 if s else 0

def kwin(a, b):
    f = f"{T}/kwin.csv"
    if not os.path.exists(f) or a["CSVL"] is None: return "no KWin log"
    d = []
    for r in [l.strip().split(",") for l in open(f)][a["CSVL"]:b["CSVL"]]:
        try: d.append([int(x) for x in r[:9]])
        except ValueError: pass
    if not d: return "no KWin frames"
    rt = sorted((r[3] - r[2]) / 1e6 for r in d); pr = sorted(r[8] / 1e6 for r in d)
    miss = sum(1 for r in d if r[1] - r[0] > r[5] / 2)
    dbl = sum(1 for r in d if r[8] / 1e6 + 2.95 < FRAME)
    q = lambda v, x: v[min(int(len(v) * x), len(v) - 1)]
    return (f"KWin {len(d)} frames, missed {miss}; render med {q(rt,.5):.1f} p99 {q(rt,.99):.1f} max {rt[-1]:.1f} ms; "
            f"predicted med {q(pr,.5):.1f} max {pr[-1]:.1f}; double-buffered {dbl * 100 / len(d):.0f}%")

def ddr(n):
    try:
        v = [int(l) for l in open(f"{T}/{n}.ddr") if l.strip().isdigit()]
        return sum(v) / len(v) / 1e6 if v else 0
    except OSError:
        return 0

print(f"{'phase':11s} {'frames':>6s} {'fps':>5s} {'gap1':>5s} {'gap2':>5s} {'gap3':>5s} {'gap4+':>5s}")
for i, ph in enumerate(open(f"{T}/phases").read().split(), 1):
    n = f"{i}-{ph}"
    a, b = load(f"{T}/{n}.a"), load(f"{T}/{n}.b")
    el = b["T"] - a["T"]
    g = [y - x for x, y in zip(a["GAP"], b["GAP"])]
    fl = sum(g)
    try:
        mode = open(f"{T}/{n}.mode").read().strip()
    except OSError:
        mode = "?"
    print(f"{n:11s} {fl:6d} {fl / el:5.1f} {g[0]:5d} {g[1]:5d} {g[2]:5d} {g[3]:5d}  [{mode}]")
    mw, parts = energy(a, b)
    gb = [y - x for x, y in zip(a["GPUB"], b["GPUB"])]
    pb = [y - x for x, y in zip(a["PERF"], b["PERF"])]
    print(f"            {kwin(a, b)}")
    print(f"            cpu ~{mw:.0f} mW ({', '.join(parts)}); gpu {avg(a, b, 'GTIS'):.0f} MHz; ddr {ddr(n):.0f} MHz; "
          f"gpu boosts idle/deadline/wait {gb[:3]}; input heavy/light {pb[:2]} frame {pb[3]}")
PY
