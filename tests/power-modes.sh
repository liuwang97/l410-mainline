#!/bin/bash
# Whole-machine power per power profile, on battery (docs/tuning/perf-power.md). Run as the
# desktop user inside the Plasma session (passwordless sudo), with the AC adapter unplugged:
#   ssh l410 'export XDG_RUNTIME_DIR=/run/user/${L410_UID:-1000} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${L410_UID:-1000}/bus;
#            bash ~/l410-bench/power-modes.sh [seconds per measurement]'
# Power = battery voltage x current from the EC (the driver polls it every 10 s), averaged.
# Configurations: the three profiles, and "before" = powersave with the memory at 2133 MHz and
# no KWin uclamp, i.e. roughly the kernel before docs/tuning/perf-power.md. Workloads: idle desktop
# (screen on, fixed brightness) and continuous fast scrolling in Chromium (browser-bench.sh).
DUR=${1:-120}
D=$(dirname "$(readlink -f "$0")")
B=/sys/class/power_supply/echub-battery
A=/sys/class/power_supply/echub-ac
[ "$(cat $A/online)" = 0 ] || { echo "AC adapter plugged in: unplug it first"; exit 1; }

setp() {
	sudo gdbus call --system --dest org.freedesktop.UPower.PowerProfiles \
		--object-path /org/freedesktop/UPower/PowerProfiles \
		--method org.freedesktop.DBus.Properties.Set org.freedesktop.UPower.PowerProfiles \
		ActiveProfile "<\"$1\">" > /dev/null
	sudo /usr/sbin/tuned-adm profile l410-$2 > /dev/null	# re-apply even if unchanged
	sleep 3
}
measure() {	# measure <seconds>: mean power in mW from the EC samples
	local end=$((SECONDS + $1)) n=0 sum=0 v i
	while [ $SECONDS -lt $end ]; do
		v=$(cat $B/voltage_now); i=$(cat $B/current_now)
		i=${i#-}
		sum=$((sum + v / 1000 * i / 1000 / 1000)); n=$((n + 1))
		sleep 5
	done
	echo $((sum / n))
}
bright=$(cat /sys/class/backlight/backlight/brightness)
echo "battery $(cat $B/capacity)%, backlight $bright, $DUR s per measurement"
pkill -TERM -x chromium; sleep 3

for cfg in before powersave balanced performance; do
	case $cfg in
	before) setp power-saver powersave
		for d in /sys/class/devfreq/*.ddr_devfreq; do echo performance | sudo tee $d/governor > /dev/null; done
		K=/sys/fs/cgroup$(cut -d: -f3 /proc/$(pgrep -x kwin_wayland)/cgroup)
		echo 0 > $K/cpu.uclamp.min ;;
	powersave) setp power-saver powersave ;;
	balanced) setp balanced balanced ;;
	performance) setp performance performance ;;
	esac
	sleep 30
	idle=$(measure $DUR)
	# busy: Chromium scrolling bilibili for the measurement time
	BROWSER=chromium PHASES="scroll" bash $D/bench/browser-bench.sh $DUR > /tmp/power-$cfg-scroll.txt 2>&1 &
	sleep 35
	busy=$(measure $((DUR - 10)))
	wait
	fps=$(awk '/^1-scroll/ {print $3}' /tmp/power-$cfg-scroll.txt)
	printf "%-12s idle %5d mW   scrolling %5d mW (%s fps)\n" $cfg $idle $busy "${fps:-?}"
	pkill -TERM -x chromium; sleep 3
done
setp balanced balanced
echo "battery now $(cat $B/capacity)%"
