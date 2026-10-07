#!/bin/bash
# ab.sh <label> [runs]: frame-budget + browser-bench (chromium) into results/<label>-*.txt
# BFLAGS in the environment go to chromium.
export XDG_RUNTIME_DIR=/run/user/${L410_UID:-1000} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${L410_UID:-1000}/bus WAYLAND_DISPLAY=wayland-0
B=$HOME/l410-bench; R=$B/cgpu/results; mkdir -p $R
L=$1; N=${2:-2}
wake() {
	for s in $(loginctl list-sessions --no-legend | awk '$4 == "seat0" {print $1}'); do sudo loginctl unlock-session $s; done
	kscreen-doctor --dpms on > /dev/null 2>&1
	b=$(cat /sys/class/backlight/*/brightness)
	[ "$b" -gt 20 ] || qdbus6 org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement/Actions/BrightnessControl setBrightness 6000 > /dev/null
	sleep 2
}
for i in $(seq 1 $N); do
	echo "### $L run $i (BFLAGS=${BFLAGS:-}) $(cat /sys/kernel/l410_perf/mode) $(date +%T)"
	wake
	echo "frame-budget $(date +%T)"
	kde-inhibit --power --screenSaver bash $B/frame-budget.sh 10 > $R/$L-fb-$i.txt 2>&1
	grep -E '^==|kwin' $R/$L-fb-$i.txt
	wake
	echo "browser-bench $(date +%T)"
	kde-inhibit --power --screenSaver bash $B/browser-bench.sh 8 > $R/$L-bb-$i.txt 2>&1
	grep -vE '^screen|^chromium [0-9]' $R/$L-bb-$i.txt | grep -E 'page:|^[0-9]-|KWin'
done
echo "AB-DONE $(date +%T)"
