#!/bin/bash
# scrollprobe.sh <label>: browser-bench scroll phase only, with a per-thread CPU sample during it.
# TWEAK="affinity 4-7" / "rr 4-5": applied to Chromium's frame-critical threads before scrolling.
export XDG_RUNTIME_DIR=/run/user/${L410_UID:-1000} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${L410_UID:-1000}/bus WAYLAND_DISPLAY=wayland-0
B=$HOME/l410-bench; R=$B/cgpu/results; mkdir -p $R; L=$1
for s in $(loginctl list-sessions --no-legend | awk '$4 == "seat0" {print $1}'); do sudo loginctl unlock-session $s; done
kscreen-doctor --dpms on > /dev/null 2>&1
rm -f /tmp/browser-bench/1-scroll.a
( if [ -n "$TWEAK" ]; then
	sleep 22; sudo python3 $B/cgpu/tweak.py $TWEAK > $R/$L-tweak.txt 2>&1
  fi
  until [ -e /tmp/browser-bench/1-scroll.a ]; do sleep 0.2; done
  sudo python3 $B/cgpu/thrsample.py 7 $R/$L-threads.txt ) &
PHASES=scroll kde-inhibit --power --screenSaver bash $B/browser-bench.sh 8 > $R/$L-bb.txt 2>&1
wait
grep -E 'page:|^[0-9]-|KWin' $R/$L-bb.txt
cat $R/$L-tweak.txt 2>/dev/null
head -8 $R/$L-threads.txt
echo "PROBE-DONE $(date +%T)"
