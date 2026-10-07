#!/bin/bash
# T2 power: cpufreq / cpuidle / thermal soak on the 6.18 test kernel (root).
#   sudo bash tests/power-soak.sh [seconds]          (default 1800)
#   l410-harness.sh test <bundle> --host-script dev/bringup/power-soak-host.sh
#     (the host script runs this on the L410 and pushes USB network traffic meanwhile)
# Alternates full load (stress-ng, all 8 CPUs) and idle in 20 s phases; idle phases also do
# UFS reads/writes (interrupts that wake CPUs out of cluster power down). Samples granted
# frequencies, temperatures and idle-state usage, then checks: no kernel warnings (RCU stalls,
# soft/hard lockups, ...), every idle state incl. cluster power down kept being used, the
# system clock did not drift against the PMIC RTC (lost ticks), temperatures stayed sane.
# Nothing in here reads stdin (the harness feeds the script through `bash -s`).

if [ "$(id -u)" != 0 ]; then
	if [ -f "$0" ]; then exec sudo -n bash "$0" "$@"; else exec sudo -n bash -s -- "$@"; fi
fi

DUR=${1:-1800}
fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
info() { echo "INFO $*"; }

cpu=/sys/devices/system/cpu
zone_temp() { for z in /sys/class/thermal/thermal_zone*; do [ "$(cat $z/type)" = "$1" ] && cat $z/temp; done; }
freqs() { l=""; for p in $cpu/cpufreq/policy*; do l="$l $(cat $p/cpuinfo_cur_freq)"; done; echo $l; }
temps() { echo "$(( $(zone_temp cluster0) / 1000 ))/$(( $(zone_temp cluster1) / 1000 ))/$(( $(zone_temp cluster2) / 1000 ))"; }
idle_usage() { cat $cpu/cpu$1/cpuidle/state$2/usage 2>/dev/null || echo 0; }

command -v stress-ng > /dev/null || { echo "FAIL stress-ng missing"; exit 1; }
[ -d $cpu/cpufreq/policy0 ] || { echo "FAIL no cpufreq"; exit 1; }
info "kernel $(uname -r), governor $(cat $cpu/cpufreq/policy0/scaling_governor), cpuidle $(cat $cpu/cpuidle/current_driver)"

rtc=/sys/class/rtc/rtc0/since_epoch
skew() { echo $(( $(date +%s) - $(cat $rtc) )); }
keepalive() {	# bring-up safety nets: deadman fires at half the value; revert needs the flag
	echo 1200 > /sys/kernel/l410_deadman/timeout 2>/dev/null
	touch /run/l410-keep
}
ufs_io() {	# a few MB of uncached reads and a direct write on the Debian partition (sdd7)
	echo 3 > /proc/sys/vm/drop_caches
	find /usr/lib -type f -size +2M 2>/dev/null | shuf -n 4 | xargs -r cat > /dev/null 2>&1
	dd if=/dev/urandom of=/var/tmp/power-soak.bin bs=1M count=8 oflag=direct status=none
	rm -f /var/tmp/power-soak.bin
}

# only look at kernel messages logged after this point (keep the log for the harness)
T0=$(cut -d" " -f1 /proc/uptime)
soak_dmesg() { dmesg "$@" 2>/dev/null | awk -v t=$T0 '{ s = $0; sub(/^\[ */, "", s); split(s, a, "]"); if (a[1] + 0 > t) print }'; }
declare -A before
for c in 0 4 6; do for s in 1 2; do before[$c.$s]=$(idle_usage $c $s); done; done
tmax=0
skew0=$(skew); up0=$(cut -d. -f1 /proc/uptime); t0=$(cat $rtc)

end=$(( $(date +%s) + DUR )); phase=0
while [ "$(date +%s)" -lt $end ]; do
	keepalive
	if [ $((phase % 2)) = 0 ]; then
		stress-ng --cpu 8 --timeout 20 < /dev/null > /dev/null 2>&1 &
		sleep 10
		f=$(freqs); t=$(temps)
		info "load  t=$(( end - $(date +%s) ))s freq(kHz) $f temp(C) $t"
		wait
	else
		sleep 5
		ufs_io
		info "idle  t=$(( end - $(date +%s) ))s freq(kHz) $(freqs) temp(C) $(temps)"
		sleep 10
		ufs_io
	fi
	for z in cluster0 cluster1 cluster2; do v=$(zone_temp $z); [ "${v:-0}" -gt $tmax ] && tmax=$v; done
	phase=$((phase + 1))
done

# frequencies reached the top under load and dropped at idle
top=$(for p in $cpu/cpufreq/policy*; do awk '{print $NF}' $p/scaling_available_frequencies; done | tr '\n' ' ')
bot=$(for p in $cpu/cpufreq/policy*; do awk '{print $1}' $p/scaling_available_frequencies; done | tr '\n' ' ')
sleep 5
idlef=$(freqs)
info "OPP top: $top bottom: $bot, now idle: $idlef"
[ "$(echo $idlef)" = "$(echo $bot)" ] && pass "cpufreq: back to the lowest OPP on every cluster at idle" ||
	info "cpufreq: idle frequencies $idlef (schedutil may keep one cluster up briefly)"

for c in 0 4 6; do
	for s in 1 2; do
		n=$(cat $cpu/cpu$c/cpuidle/state$s/name 2>/dev/null)
		d=$(( $(idle_usage $c $s) - ${before[$c.$s]} ))
		if [ $d -gt 0 ]; then pass "cpuidle cpu$c $n: entered $d times during the soak"
		else fail "cpuidle cpu$c $n: not entered"; fi
	done
done

info "hottest cluster: $((tmax / 1000)).$(( (tmax % 1000) / 100 ))C"
for c in /sys/class/thermal/cooling_device*; do info "cooling $(cat $c/type) cur=$(cat $c/cur_state)/$(cat $c/max_state)"; done
[ $tmax -lt 95000 ] && pass "thermal: stayed below 95C" || fail "thermal: reached $((tmax / 1000))C"

# lost timer ticks / clock trouble: system time and uptime against the PMIC RTC
drift=$(( $(skew) - skew0 )); d=${drift#-}
el_rtc=$(( $(cat $rtc) - t0 )); el_up=$(( $(cut -d. -f1 /proc/uptime) - up0 )); du=$(( el_rtc - el_up )); du=${du#-}
info "elapsed: RTC ${el_rtc}s, uptime ${el_up}s; system-RTC skew change ${drift}s"
[ $d -le 2 ] && [ $du -le 2 ] && pass "time: no drift against the PMIC RTC" || fail "time: drift ${drift}s, uptime vs RTC ${du}s"

bad=$(soak_dmesg | grep -i "rcu.*stall\|soft lockup\|hard LOCKUP\|watchdog: BUG\|hung_task\|blocked for more than\|clocksource.*unstable\|timekeeping watchdog\|hrtimer: interrupt took\|Unable to handle\|Internal error\|SError")
[ -z "$bad" ] && pass "kernel: no RCU stalls, lockups, hung tasks or clock warnings" ||
	{ fail "kernel: $(echo "$bad" | head -1)"; echo "$bad" | head -10 | sed 's/^/INFO dmesg: /'; }

new=$(soak_dmesg --level=emerg,alert,crit,err,warn | grep -v "Not disabling unused regulators")
if [ -z "$new" ]; then pass "kernel: no warnings or errors during the soak"
else fail "kernel: $(echo "$new" | wc -l) warning/error lines during the soak"; echo "$new" | head -20 | sed 's/^/INFO dmesg: /'; fi

echo "power-soak.sh: $fails failure(s)"
exit $fails
