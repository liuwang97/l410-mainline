#!/bin/bash
# Interleaved power of the power profiles, A B C A B C ..., to cancel drift (background jobs after
# boot, battery voltage).  Each configuration gets an idle window and a light-load window: one thread
# doing a fixed amount of work every 16.7 ms (about 2 ms at the fastest big-core OPP), like a
# frame-paced app, so the profiles differ only in how fast / how efficiently they do the same work.
# "before" is the state before the plan: powersave profile, memory at 2133 MHz, no KWin uclamp.
# sched_ext configurations (docs/tuning/sched-ext.md step 4): lavd, lavd-uclamp, bpfland, lavd-powersave.
# Run like tests/power-modes.sh (desktop user in the session, AC unplugged):
#   bash ~/l410-bench/power-ab.sh [seconds per window] [rounds] [configs...]
DUR=${1:-90}
ROUNDS=${2:-3}
shift 2
CFGS=${*:-before balanced}
B=/sys/class/power_supply/echub-battery
[ "$(cat /sys/class/power_supply/echub-ac/online)" = 0 ] || { echo "unplug the AC adapter first"; exit 1; }

setp() {
	sudo gdbus call --system --dest org.freedesktop.UPower.PowerProfiles \
		--object-path /org/freedesktop/UPower/PowerProfiles \
		--method org.freedesktop.DBus.Properties.Set org.freedesktop.UPower.PowerProfiles \
		ActiveProfile "<\"$1\">" > /dev/null
	sudo /usr/sbin/tuned-adm profile l410-$2 > /dev/null
	sleep 3
}
scx() {	# scx none|lavd|bpfland [keep-uclamp]: the sched_ext scheduler for a configuration
	sudo systemctl stop scx-lavd.service scx-bpfland.service 2> /dev/null
	if [ "$2" = keep-uclamp ]; then sudo touch /run/l410-perfd.noscx; else sudo rm -f /run/l410-perfd.noscx; fi
	[ "$1" = none ] || { sudo systemctl start scx-$1.service; sleep 3; }
	sleep 6	# l410-perfd polls every 5 s and re-applies the uclamp for the new state
}
config() {
	case $1 in
	lavd) setp balanced balanced; scx lavd ;;			# B: lavd, uclamp only on KWin's RT threads
	lavd-uclamp) setp balanced balanced; scx lavd keep-uclamp ;;	# C: lavd with the EAS-era uclamp floors
	bpfland) setp balanced balanced; scx bpfland ;;			# D
	lavd-powersave) setp power-saver powersave; scx lavd ;;
	*) scx none ;;
	esac
	case $1 in
	before)
		setp power-saver powersave
		for d in /sys/class/devfreq/*.ddr_devfreq; do echo performance | sudo tee $d/governor > /dev/null; done
		K=/sys/fs/cgroup$(cut -d: -f3 /proc/$(pgrep -x kwin_wayland)/cgroup)
		echo 0 > $K/cpu.uclamp.min ;;
	powersave) setp power-saver powersave ;;
	balanced) setp balanced balanced ;;
	performance) setp performance performance ;;
	esac
}
load() {	# fixed work per 16.7 ms frame
	exec python3 -c '
import time
t = time.monotonic()
while True:
    for _ in range(40000):
        pass
    t += 1 / 60
    d = t - time.monotonic()
    if d > 0:
        time.sleep(d)
    else:
        t = time.monotonic()
'
}
window() {	# mean mW over $DUR s; also the mean memory frequency, CPU use and the mode at the end
	local end=$((SECONDS + DUR)) n=0 sum=0 v i dsum=0
	local c0=$(awk '/^cpu /{print $2+$3+$4+$7+$8}' /proc/stat)
	while [ $SECONDS -lt $end ]; do
		v=$(cat $B/voltage_now); i=$(cat $B/current_now); i=${i#-}
		sum=$((sum + v / 1000 * i / 1000 / 1000)); n=$((n + 1))
		dsum=$((dsum + $(cat /sys/class/devfreq/*.ddr_devfreq/cur_freq) / 1000000))
		sleep 5
	done
	local c1=$(awk '/^cpu /{print $2+$3+$4+$7+$8}' /proc/stat)
	local mode=$(sed 's/.*\[\(.*\)\].*/\1/' /sys/kernel/l410_perf/mode)
	echo "$((sum / n)) mW, ddr $((dsum / n)) MHz, cpu $(( (c1 - c0) / DUR ))% of one core, mode $mode"
}
echo "battery $(cat $B/capacity)%, backlight $(cat /sys/class/backlight/backlight/brightness), $DUR s per window"
for r in $(seq 1 $ROUNDS); do
	for cfg in $CFGS; do
		config $cfg
		sleep 20
		printf "round %d %-11s idle  %s\n" $r $cfg "$(window)"
		load & L=$!
		sleep 5
		printf "round %d %-11s light %s\n" $r $cfg "$(window)"
		kill $L; wait $L 2> /dev/null
	done
done
config balanced
scx none
echo "battery now $(cat $B/capacity)%"
