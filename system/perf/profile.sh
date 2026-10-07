#!/bin/sh
# L410 power profile, applied by tuned: /etc/tuned/profiles/l410-<mode>/script.sh start
# (docs/tuning/perf-power.md). Runs as root. Per-user parts (KWin / application uclamp,
# launch detection) are l410-perfd's; it follows /sys/kernel/l410_perf/mode.
#
#   profile.sh powersave|balanced|performance start|stop|verify
mode=$1
P=/sys/kernel/l410_perf

w() { [ -e "$1" ] && echo "$2" > "$1" 2>/dev/null; return 0; }

case "$mode" in
powersave)	rl=3000 pelt=1 gpoll=50 boost=0 ddr=powersave  ah8=5000   rpm=auto wifips=on ;;
balanced)	rl=500  pelt=2 gpoll=20 boost=2 ddr=powersave  ah8=20000  rpm=auto wifips=on ;;
performance)	rl=500  pelt=4 gpoll=20 boost=2 ddr=performance ah8=150000 rpm=on  wifips=off ;;
*)		echo "usage: $0 powersave|balanced|performance start|stop" >&2; exit 2 ;;
esac
[ "$2" = start ] || exit 0

w $P/mode "$mode"
# l410-perfd runs as the desktop user (group l410, system/perf/install.sh) and kicks the launch boost
chgrp l410 $P/launch 2>/dev/null && chmod 0664 $P/launch

# schedutil: LPM3 switches in 0.4-0.8 ms; 3 ms (the firmware's claim x 1.5) in powersave
w /sys/devices/system/cpu/cpufreq/schedutil/rate_limit_us $rl
# PELT half-life 32 / 16 / 8 ms
w /proc/sys/kernel/sched_pelt_multiplier $pelt
# RT tasks don't get the big cores by default (WiFi, PipeWire); KWin gets them by cgroup
w /proc/sys/kernel/sched_util_clamp_min_rt_default 0

# GPU: msm-style idle / deadline / wait boosts, faster sampling
for p in idle_boost deadline_boost wait_boost; do
	w /sys/module/panfrost/parameters/$p $boost
done
for g in /sys/class/devfreq/*.mali; do w "$g/polling_interval" $gpoll; done

# DDR: lowest OPP that satisfies l410-perf's requests (mode, boosts, CPU/GPU load);
# UEFI leaves it at 2133 MHz. Performance keeps the fastest OPP.
for d in /sys/class/devfreq/*.ddr_devfreq; do w "$d/governor" $ddr; done

# GPU and display interrupts on the middle cores: off CPU0 (little, deepest idle) and off
# the big cores KWin runs on
for n in panfrost-job panfrost-mmu panfrost-gpu kirin-dss; do
	for i in $(awk -v n="$n" '$NF == n { sub(":", "", $1); print $1 }' /proc/interrupts); do
		w /proc/irq/$i/smp_affinity_list 4-5
	done
done

# devices
# UFS: auto-hibern8 after 5 / 20 / 150 ms idle; LUs runtime-suspend after 2 s (the
# host follows once all LUs are idle: link in hibern8, clocks gated)
for u in /sys/bus/platform/devices/*.ufs; do w "$u/auto_hibern8" $ah8; done
for s in /sys/class/scsi_disk/*/device/power; do
	w "$s/autosuspend_delay_ms" 2000
	w "$s/control" $rpm
done
# on-board RTL8168 without a cable: D3hot (r8169 runtime PM); not the WiFi (vendor driver)
for d in /sys/bus/pci/drivers/r8169/0*; do w "$d/power/control" $rpm; done
# WiFi power save: stable on the Hi1103; incoming packets after idle wait up to ~130 ms
# (outgoing ones are not delayed), so performance mode turns it off
for i in /sys/class/net/wl*; do
	[ -e "$i" ] && /usr/sbin/iw dev "${i##*/}" set power_save $wifips 2> /dev/null
done

# thermal: power allocator (PID on the energy models) for the CPU and GPU zones instead of
# step_wise's 90 C on/off; sustainable power about each zone's full-load power, so nothing
# is throttled below the 90 C control temperature
for z in /sys/class/thermal/thermal_zone*; do
	case $(cat $z/type) in
	cluster0) sp=600 ;;
	cluster1) sp=1100 ;;
	cluster2) sp=2300 ;;
	gpu) sp=2400 ;;
	*) continue ;;
	esac
	w $z/sustainable_power $sp
	w $z/policy power_allocator
done

# cgroup ancestors of the user sessions let uclamp.min through (a child's effective
# minimum can't exceed its parent's); l410-perfd sets the leaves
for c in /sys/fs/cgroup/user.slice /sys/fs/cgroup/user.slice/user-*.slice \
	 /sys/fs/cgroup/user.slice/user-*.slice/user@*.service; do
	w "$c/cpu.uclamp.min" max
done

# a running sched_ext scheduler takes the mode's options (scx-run reads the mode at start)
if systemctl is-active -q scx-lavd.service 2> /dev/null; then
	systemctl --no-block restart scx-lavd.service
fi
exit 0
