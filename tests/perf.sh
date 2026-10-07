#!/bin/bash
# Performance / power features of the l410 kernel (docs/tuning/perf-power.md). Run as root on the L410.
#   energy model + EAS, uclamp and PELT multiplier interfaces, schedutil rate limit,
#   /sys/kernel/l410_perf modes and boosts (launch, input), GPU boosts and cooling,
#   kirin990-dss commit thread / cursor plane / frame statistics.
# Output: PASS/FAIL/INFO lines, then RESULT.
set -u
fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
info() { echo "INFO $*"; }
rd() { cat "$1" 2>/dev/null; }

P=/sys/kernel/l410_perf
GPU=$(ls -d /sys/class/devfreq/*.mali 2>/dev/null | head -1)
DBG=/sys/kernel/debug
DRI=$(grep -l '^kirin' $DBG/dri/*/name 2>/dev/null | head -1 | xargs -r dirname)
PFD=$(grep -l '^panfrost' $DBG/dri/*/name 2>/dev/null | head -1 | xargs -r dirname)

info "kernel $(uname -r)"
info "cmdline $(cat /proc/cmdline)"

# --- kernel log
if dmesg | grep -E 'BUG:|Oops|WARNING:|Call trace' | grep -v -i ramoops | head -5 | grep -q .; then
	dmesg | grep -E -A3 'BUG:|Oops|WARNING:' | head -30
	fail "kernel log has BUG/Oops/WARNING"
else
	pass "kernel log clean of BUG/Oops/WARNING"
fi
dmesg | grep -E 'energy model|l410-perf|no frequency boosts|no commit thread|hisi-hwvote' | sed 's/^/INFO dmesg: /'

# --- energy model / EAS
n=$(dmesg | grep -c 'energy model, .* states')
[ "$n" = 3 ] && pass "energy model on 3 CPU clusters" || fail "energy model on $n CPU clusters (want 3)"
ls $DBG/energy_model 2>/dev/null | sed 's/^/INFO em: /'
for pd in $DBG/energy_model/cpu*; do
	[ -d "$pd" ] || continue
	s=$(ls -d $pd/ps:* 2>/dev/null | sort -t: -k2 -n | tail -1)
	info "$(basename $pd) cpus $(rd $pd/cpus) top state $(basename $s): power $(rd $s/power) uW"
done
[ "$(rd /proc/sys/kernel/sched_energy_aware)" = 1 ] && pass "sched_energy_aware=1" || fail "sched_energy_aware=$(rd /proc/sys/kernel/sched_energy_aware)"
if [ -d $DBG/sched/domains ]; then
	grep -h . $DBG/sched/domains/cpu0/domain*/flags 2>/dev/null | head -3 | sed 's/^/INFO cpu0 domain flags: /'
fi
if [ -n "$GPU" ] && ls $DBG/energy_model | grep -q -v '^cpu'; then
	pass "GPU energy model: $(ls $DBG/energy_model | grep -v '^cpu' | tr '\n' ' ')"
else
	fail "no GPU energy model"
fi

# --- uclamp / PELT
[ -e /proc/sys/kernel/sched_util_clamp_min_rt_default ] && pass "uclamp: rt default $(rd /proc/sys/kernel/sched_util_clamp_min_rt_default)" || fail "no uclamp sysctls"
if [ -e /proc/sys/kernel/sched_pelt_multiplier ]; then
	old=$(rd /proc/sys/kernel/sched_pelt_multiplier)
	ok=1
	for m in 2 4 1; do
		echo $m > /proc/sys/kernel/sched_pelt_multiplier && [ "$(rd /proc/sys/kernel/sched_pelt_multiplier)" = $m ] || ok=0
	done
	echo 3 > /proc/sys/kernel/sched_pelt_multiplier 2>/dev/null && ok=0
	echo "$old" > /proc/sys/kernel/sched_pelt_multiplier
	[ $ok = 1 ] && pass "PELT multiplier switches 2/4/1, rejects 3" || fail "PELT multiplier sysctl"
else
	fail "no sched_pelt_multiplier"
fi

# --- cpufreq
info "cpufreq driver $(rd /sys/devices/system/cpu/cpufreq/policy0/scaling_driver), governor $(rd /sys/devices/system/cpu/cpufreq/policy0/scaling_governor)"
rl=$(rd /sys/devices/system/cpu/cpufreq/schedutil/rate_limit_us)
[ "$rl" = 500 ] && pass "schedutil rate_limit_us 500" || info "schedutil rate_limit_us $rl"

# --- l410_perf modes
pol_min() { for p in 0 4 6; do rd /sys/devices/system/cpu/cpufreq/policy$p/scaling_min_freq; done | tr '\n' ' '; }
pol_cmax() { for p in 0 4 6; do rd /sys/devices/system/cpu/cpufreq/policy$p/cpuinfo_max_freq; done | tr '\n' ' '; }
pol_cmin() { for p in 0 4 6; do rd /sys/devices/system/cpu/cpufreq/policy$p/cpuinfo_min_freq; done | tr '\n' ' '; }
if [ -d $P ]; then
	info "l410_perf mode: $(rd $P/mode)"
	rd $P/stats | sed 's/^/INFO stats: /'
	oldmode=$(sed 's/.*\[\(.*\)\].*/\1/' $P/mode)

	echo performance > $P/mode; sleep 0.3
	[ "$(pol_min)" = "$(pol_cmax)" ] && pass "performance: CPU minimum = maximum ($(pol_min))" || fail "performance: CPU min $(pol_min), max $(pol_cmax)"
	if [ -n "$GPU" ]; then
		g=$(rd $GPU/cur_freq)
		[ "$g" = "$(rd $GPU/max_freq)" ] && pass "performance: GPU at $g" || fail "performance: GPU at $g (max $(rd $GPU/max_freq))"
	fi
	echo balanced > $P/mode; sleep 0.3
	[ "$(pol_min)" = "$(pol_cmin)" ] && pass "balanced idle: no CPU floor" || fail "balanced idle: CPU min $(pol_min)"

	echo 800 > $P/launch; sleep 0.2
	[ "$(pol_min)" = "$(pol_cmax)" ] && pass "launch boost: CPU at maximum" || fail "launch boost: CPU min $(pol_min)"
	sleep 1
	[ "$(pol_min)" = "$(pol_cmin)" ] && pass "launch boost expired" || fail "launch boost did not expire: $(pol_min)"

	# input boost: a key press is a "heavy" event. The throw-away uinput device only has a
	# gamepad button (BTN_TRIGGER_HAPPY1): libinput ignores joysticks, the desktop sees nothing.
	out=$(python3 - <<'PY' 2>&1
import fcntl, os, struct, time
fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, 0x40045564, 1)          # UI_SET_EVBIT EV_KEY
fcntl.ioctl(fd, 0x40045565, 0x2c0)      # UI_SET_KEYBIT BTN_TRIGGER_HAPPY1
setup = struct.pack("HHHH80sI", 3, 0x1234, 0x5678, 1, b"l410-perf-test", 0)
fcntl.ioctl(fd, 0x405c5503, setup)      # UI_DEV_SETUP
fcntl.ioctl(fd, 0x5501)                 # UI_DEV_CREATE
time.sleep(0.3)
def ev(t, c, v):
    n = time.time(); s = int(n)
    return struct.pack("llHHi", s, int((n - s) * 1e6), t, c, v)
os.write(fd, ev(1, 0x2c0, 1) + ev(0, 0, 0) + ev(1, 0x2c0, 0) + ev(0, 0, 0))
time.sleep(0.03)
mins = []
for p in (0, 4, 6):
    mins.append(open(f"/sys/devices/system/cpu/cpufreq/policy{p}/scaling_min_freq").read().strip())
print(" ".join(mins))
fcntl.ioctl(fd, 0x5502)                 # UI_DEV_DESTROY
os.close(fd)
PY
)
	if echo "$out" | grep -qE '^[0-9]+ [0-9]+ [0-9]+$' && [ "$out " != "$(pol_cmin)" ]; then
		pass "input boost: CPU floors $out"
	else
		fail "input boost: CPU floors '$out' after a wheel event"
	fi
	sleep 0.5
	[ "$(pol_min)" = "$(pol_cmin)" ] && pass "input boost expired" || info "input boost still on after 0.5 s: $(pol_min)"
	echo "$oldmode" > $P/mode
	rd $P/stats | sed 's/^/INFO stats: /'
else
	fail "no /sys/kernel/l410_perf"
fi

# --- GPU
if [ -n "$GPU" ]; then
	info "GPU devfreq $GPU: $(rd $GPU/governor) $(rd $GPU/min_freq)-$(rd $GPU/max_freq), cur $(rd $GPU/cur_freq), polling $(rd $GPU/polling_interval) ms"
	[ -n "$PFD" ] && rd $PFD/devfreq_boost | sed 's/^/INFO panfrost: /'
	for p in idle_boost deadline_boost deadline_margin_us wait_boost compositor_priority highpri_submit; do
		info "panfrost.$p=$(rd /sys/module/panfrost/parameters/$p)"
	done
	ps -eo comm | grep -q '^pan_js' && info "submit workqueues: $(ps -eo comm | grep '^kworker.*pan_js' | head -3 | tr '\n' ' ')"
	pgrep -x panfrost-boost > /dev/null && pass "panfrost-boost worker ($(chrt -p $(pgrep -x panfrost-boost) | head -1 | sed 's/.*: //'))" || fail "no panfrost-boost worker"
	tz=$(grep -l '^gpu$' /sys/class/thermal/thermal_zone*/type | head -1 | xargs dirname)
	if ls $tz/cdev* > /dev/null 2>&1; then
		pass "GPU thermal zone has a cooling device ($(rd $tz/cdev0/type), trip $(rd $tz/trip_point_0_temp)/$(rd $tz/trip_point_1_temp))"
	else
		fail "GPU thermal zone has no cooling device"
	fi
fi

# --- display
if [ -n "$DRI" ]; then
	rd $DRI/kirin_frames | sed 's/^/INFO kirin: /'
	pgrep -x kirin-commit > /dev/null && pass "kirin-commit thread ($(chrt -p $(pgrep -x kirin-commit) | head -1 | sed 's/.*: //'))" || fail "no kirin-commit thread"
	if grep -q 'cursor' $DRI/state 2>/dev/null; then
		info "cursor plane: $(grep -A4 'plane\[.*cursor\|type=CURSOR' $DRI/state | tr '\n' ' ' | head -c 300)"
	fi
	grep -o 'underflows [0-9]*' $DRI/kirin_state | head -1 | sed 's/^/INFO /'
fi

echo "RESULT: $([ $fails = 0 ] && echo PASS || echo "FAIL ($fails)")"
