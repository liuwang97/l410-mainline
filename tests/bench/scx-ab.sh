#!/bin/bash
# sched_ext A/B on the real workload (docs/tuning/sched-ext.md step 4): tests/bench/browser-bench.sh
# (Chromium on bilibili: scroll, drag, maximize, minimize) per configuration, interleaved
# A B C ... for ROUNDS rounds, idle and with a CPU hog competing (8 stress-ng workers in an
# app scope, like a compile in a terminal). Balanced mode throughout.
#
#   bash tests/bench/scx-ab.sh [rounds=3] [configs="eas lavd lavd-uclamp"] [loads="none cpu"]
#
#   eas          EEVDF/EAS, KWin cgroup uclamp max, foreground 37.5% (the current setup, A)
#   lavd         scx_lavd --balanced, uclamp only on KWin's RT threads, no foreground floor (B)
#   lavd-uclamp  scx_lavd with the EAS-era uclamp floors (C: what the little-core pinning costs)
#   bpfland      scx_bpfland (D)
# Runs as the desktop user in the session, with browser-bench.sh and uinput-bench.py next to
# it. Needs scx-lavd.service / scx-bpfland.service (system/sched-ext) and passwordless sudo.
# Output: /var/tmp/l410-scx-ab/<time>/{<round>-<load>-<cfg>.txt, summary.txt}
ROUNDS=${1:-3}
CFGS=${2:-eas lavd lavd-uclamp}
LOADS=${3:-none cpu}
D=$(dirname "$(readlink -f "$0")")
OUT=/var/tmp/l410-scx-ab/$(date +%Y%m%d-%H%M%S); mkdir -p $OUT
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
export DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}

setp() {
	sudo gdbus call --system --dest org.freedesktop.UPower.PowerProfiles \
		--object-path /org/freedesktop/UPower/PowerProfiles \
		--method org.freedesktop.DBus.Properties.Set org.freedesktop.UPower.PowerProfiles \
		ActiveProfile "<\"balanced\">" > /dev/null
	sudo /usr/sbin/tuned-adm profile l410-balanced > /dev/null
}
scx() {	# scx none|lavd|bpfland [keep-uclamp]
	sudo systemctl stop scx-lavd.service scx-bpfland.service 2> /dev/null
	if [ "$2" = keep-uclamp ]; then sudo touch /run/l410-perfd.noscx; else sudo rm -f /run/l410-perfd.noscx; fi
	[ "$1" = none ] || sudo systemctl start scx-$1.service
	sleep 8	# l410-perfd polls every 5 s
	echo "sched_ext $(cat /sys/kernel/sched_ext/state 2> /dev/null) $(cat /sys/kernel/sched_ext/root/ops 2> /dev/null)"
}
config() {
	case $1 in
	eas) scx none ;;
	lavd) scx lavd ;;
	lavd-uclamp) scx lavd keep-uclamp ;;
	bpfland) scx bpfland ;;
	esac
}
setp
for r in $(seq 1 $ROUNDS); do
	for ld in $LOADS; do
		for c in $CFGS; do
			f=$OUT/$r-$ld-$c.txt
			{ echo "# round $r load $ld config $c"; config $c; } > $f
			H=""
			if [ $ld = cpu ]; then
				systemd-run --user --scope -q -u app-scxab-hog-$$-$r-$c.scope stress-ng --cpu 8 --timeout 300s > /dev/null 2>&1 &
				H=$!; sleep 3
			fi
			FRESH=1 bash $D/browser-bench.sh 8 >> $f 2>&1
			[ -n "$H" ] && { pkill -x stress-ng; wait $H 2> /dev/null; }
			# little-core pinning: time at the top OPP of policy0 is in the bench's cpu line
			grep -E '^[0-9]-(scroll|drag|maximize|minimize)|cpu ~' $f | tr -s ' ' | head -8 | sed "s/^/  [$r $ld $c] /"
		done
	done
done
scx none
python3 - $OUT << 'PY' | tee $OUT/summary.txt
import glob, os, re, sys, collections
out = sys.argv[1]
acc = collections.defaultdict(lambda: collections.defaultdict(list))
for f in sorted(glob.glob(f"{out}/*-*-*.txt")):
    r, ld, cfg = os.path.basename(f)[:-4].split("-", 2)
    lines = open(f).read().splitlines()
    for i, l in enumerate(lines):
        m = re.match(r"^\d-(\w+)\s+(\d+)\s+([\d.]+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)", l)
        if not m: continue
        ph = m.group(1); fl = int(m.group(2)); fps = float(m.group(3))
        drops = int(m.group(5)) + 2 * int(m.group(6)) + 3 * int(m.group(7))
        mw = 0
        for l2 in lines[i + 1:i + 3]:
            mm = re.search(r"cpu ~(\d+) mW", l2)
            if mm: mw = int(mm.group(1))
        acc[(ld, cfg)][ph].append((fps, drops, mw))
print(f"{'load':5s} {'config':12s} {'phase':9s} {'fps':>6s} {'drops':>6s} {'cpu mW':>7s}  (mean of rounds)")
for (ld, cfg), phs in sorted(acc.items()):
    tot = [0, 0, 0, 0]
    for ph, v in phs.items():
        n = len(v); fps = sum(x[0] for x in v) / n; dr = sum(x[1] for x in v) / n; mw = sum(x[2] for x in v) / n
        tot[0] += fps; tot[1] += dr; tot[2] += mw; tot[3] += 1
        print(f"{ld:5s} {cfg:12s} {ph:9s} {fps:6.1f} {dr:6.1f} {mw:7.0f}")
    print(f"{ld:5s} {cfg:12s} {'ALL':9s} {tot[0] / tot[3]:6.1f} {tot[1]:6.1f} {tot[2] / tot[3]:7.0f}")
PY
echo "OUT: $OUT"
