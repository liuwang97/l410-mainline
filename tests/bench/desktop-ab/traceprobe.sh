#!/bin/bash
# traceprobe.sh <label>: browser-bench scroll phase with a Chrome trace (cdptrace.py) over the
# scroll and the KWin frame log copied next to it (KWin must run with KWIN_LOG_PERFORMANCE_DATA=1).
export XDG_RUNTIME_DIR=/run/user/${L410_UID:-1000} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${L410_UID:-1000}/bus WAYLAND_DISPLAY=wayland-0
B=$HOME/l410-bench; R=$B/cgpu/results; mkdir -p $R; L=$1
for s in $(loginctl list-sessions --no-legend | awk '$4 == "seat0" {print $1}'); do sudo loginctl unlock-session $s; done
kscreen-doctor --dpms on > /dev/null 2>&1
rm -f /tmp/browser-bench/1-scroll.a
( until [ -e /tmp/browser-bench/1-scroll.a ]; do sleep 0.1; done
  python3 $B/cgpu/cdptrace.py 7 $R/$L-trace.json.gz > $R/$L-trace.log 2>&1 ) &
BFLAGS="--remote-debugging-port=9222 ${BFLAGS:-}" PHASES=scroll kde-inhibit --power --screenSaver bash $B/browser-bench.sh 8 > $R/$L-bb.txt 2>&1
wait
cp "$HOME/kwin perf statistics eDP-1.csv" $R/$L-kwin.csv
grep -E 'page:|^[0-9]-|KWin' $R/$L-bb.txt
cat $R/$L-trace.log
echo "PROBE-DONE $(date +%T)"
