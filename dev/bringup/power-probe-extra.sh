#!/bin/sh
# T2 power: extra diagnostics for l410.mode=probe (busybox initramfs).
# Packed into the initrd as /l410-extra.sh by tests/power-repack-initrd.sh;
# every line ends up in the kernel log (pstore) prefixed "L410INIT: extra:".
echo "== spmi"
ls /sys/bus/spmi/devices 2>&1
echo "== regulators (name uV state users)"
for r in /sys/class/regulator/regulator.*; do
	echo "$(cat $r/name) $(cat $r/microvolts 2>/dev/null) $(cat $r/state 2>/dev/null) $(cat $r/num_users 2>/dev/null)"
done
echo "== regulator_summary"
cat /sys/kernel/debug/regulator/regulator_summary 2>&1
echo "== rtc"
for r in /sys/class/rtc/rtc*; do
	[ -e "$r" ] && echo "$(basename $r) $(cat $r/name) $(cat $r/date) $(cat $r/time) epoch=$(cat $r/since_epoch)"
done
echo "== thermal"
for z in /sys/class/thermal/thermal_zone*; do
	[ -e "$z" ] && echo "$(basename $z) $(cat $z/type) $(cat $z/temp 2>&1)"
done
echo "== input"
grep -E "^N:|^H:" /proc/bus/input/devices 2>&1
echo "== pmic irqs"
grep -i "pmic\|spmi\|gpio" /proc/interrupts 2>&1
echo "== cpufreq"
for p in /sys/devices/system/cpu/cpufreq/policy*; do
	[ -e "$p" ] || continue
	echo "$(basename $p) cpus=$(cat $p/related_cpus) $(cat $p/scaling_driver) gov=$(cat $p/scaling_governor) cur=$(cat $p/scaling_cur_freq) hw=$(cat $p/cpuinfo_cur_freq 2>&1)"
	echo "  avail: $(cat $p/scaling_available_frequencies 2>/dev/null)"
	# switch between lowest, middle and highest with the userspace governor
	old=$(cat $p/scaling_governor)
	if echo userspace > $p/scaling_governor 2>/dev/null; then
		set -- $(cat $p/scaling_available_frequencies)
		n=$#; mid=$(( (n + 1) / 2 ))
		lo=$1; eval mi=\${$mid}; eval hi=\${$n}
		for f in $lo $mi $hi $lo; do
			echo $f > $p/scaling_setspeed
			sleep 1
			echo "  set $f -> granted $(cat $p/cpuinfo_cur_freq 2>&1)"
		done
		echo $old > $p/scaling_governor
	fi
done
for c in /sys/class/thermal/cooling_device*; do
	[ -e "$c" ] && echo "$(basename $c) $(cat $c/type) max=$(cat $c/max_state) cur=$(cat $c/cur_state)"
done
echo "== ip power domain switch (test node)"
t=/sys/devices/platform/power-test-media2
if [ -e $t/state ]; then
	echo "media2 before: $(cat $t/state)"
	echo enabled > $t/state; echo "media2 after enable: $(cat $t/state)"
	sleep 1
	echo disabled > $t/state; echo "media2 after disable: $(cat $t/state)"
else
	echo "no test node"
fi
echo "== cpuidle"
cat /sys/devices/system/cpu/cpuidle/current_driver 2>&1
for c in 0 3 4 5 6 7; do
	l=""
	for s in /sys/devices/system/cpu/cpu$c/cpuidle/state*; do
		[ -e "$s" ] && l="$l $(cat $s/name)=$(cat $s/usage)/$(cat $s/time)us"
	done
	echo "cpu$c:$l"
done
