#!/bin/bash
# One system suspend cycle with the kernel's sleep debugging on, detached from the ssh session
# (WiFi goes down while the system sleeps).  Run as root:
#   sudo bash suspend.sh <deep|s2idle> [pm_test level] [wake after seconds]
# pm_test levels (each stops at that stage, waits 5 s and resumes): freezer devices platform
# processors core; "none" really sleeps and the RTC alarm wakes it.  The deadman is armed to
# reset the board if it does not come back; the kernel log then survives in /sys/fs/pstore.
# Results: /var/tmp/suspend/<time>-<mode>-<level>.log (dmesg of the cycle and device checks).
# If WiFi is not back 60 s after resume, the log is synced and the board reboots.
MODE=${1:?deep or s2idle}
LEVEL=${2:-none}
WAKE=${3:-20}
D=/var/tmp/suspend
mkdir -p $D
LOG=$D/$(date +%H%M%S)-$MODE-$LEVEL.log

check() {	# the devices a user notices after resume
	echo "--- $1"
	echo "wlan0: $(cat /sys/class/net/wlan0/operstate 2>&1), hci0: $(ls /sys/class/bluetooth 2>&1 | tr '\n' ' ')"
	echo "display: $(cat /sys/class/drm/card*-DSI-1/dpms /sys/class/drm/card*-eDP-1/dpms 2>/dev/null | tr '\n' ' ')" \
		"backlight $(cat /sys/class/backlight/backlight/actual_brightness 2>&1)"
	echo "usb: $(ls /sys/bus/usb/devices | wc -l) devices, input: $(ls /dev/input | grep -c event) event nodes"
	echo "ufs: $(cat /sys/block/sdd/device/state 2>&1), battery $(cat /sys/class/power_supply/echub-battery/capacity 2>&1)%"
	echo "stats: success $(cat /sys/power/suspend_stats/success) fail $(cat /sys/power/suspend_stats/fail)" \
		"last failed dev '$(cat /sys/power/suspend_stats/last_failed_dev)' step '$(cat /sys/power/suspend_stats/last_failed_step)'"
}

run() {
	echo "suspend $MODE, pm_test $LEVEL, wake after $WAKE s, $(uname -r), $(date)"
	check before
	echo 600 > /sys/kernel/l410_deadman/timeout
	echo $MODE > /sys/power/mem_sleep
	echo $LEVEL > /sys/power/pm_test
	echo 1 > /sys/power/pm_debug_messages
	echo 1 > /sys/power/pm_print_times
	dmesg -n 8
	echo "=== l410-suspend start" > /dev/kmsg
	sync
	echo 0 > /sys/class/rtc/rtc0/wakealarm
	[ $LEVEL = none ] && echo +$WAKE > /sys/class/rtc/rtc0/wakealarm
	local t0=$(date +%s.%N)
	echo mem > /sys/power/state
	local rc=$? t1=$(date +%s.%N)
	echo "=== l410-suspend end rc=$rc" > /dev/kmsg
	echo "rc=$rc, write took $(awk "BEGIN { print $t1 - $t0 }") s"
	sleep 5
	check after
	echo none > /sys/power/pm_test
	echo 0 > /sys/power/pm_print_times
	echo "--- kernel log of the cycle"
	dmesg | tac | sed '/=== l410-suspend start/q' | tac
	echo 1800 > /sys/kernel/l410_deadman/timeout
	# WiFi is the only way in: if it does not come back, keep the log and reboot
	for i in $(seq 1 12); do
		[ "$(cat /sys/class/net/wlan0/operstate 2>/dev/null)" = up ] && return
		sleep 5
	done
	echo "--- wlan0 still $(cat /sys/class/net/wlan0/operstate 2>&1) after 60 s: rebooting"
	dmesg | tail -150
	sync
	systemctl reboot
}
setsid bash -c "$(declare -f check run); MODE=$MODE LEVEL=$LEVEL WAKE=$WAKE; run" > $LOG 2>&1 < /dev/null &
echo $LOG
