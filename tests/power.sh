#!/bin/bash
# Power: repeatable checks on the 6.18 test kernel (Debian on the L410).
#   sudo bash tests/power.sh
#   dev/l410-harness.sh test <bundle> --script tests/power.sh   (fed to `bash -s`)
# Prints one PASS/FAIL/SKIP/INFO line per check and a summary; exit code = number of FAILs.
# Expected values are the vendor kernel's (4.19.71-23-kr990) as read on 2026-09-29.
# Nothing in here reads stdin: when fed through `bash -s` the rest of the script is stdin.

# not root: continue the same script as root (bash reads a piped script byte by byte,
# so the new shell picks up right after this line; works for a file argument too)
if [ "$(id -u)" != 0 ]; then
	if [ -f "$0" ]; then exec sudo -n bash "$0" "$@"; else exec sudo -n bash -s -- "$@"; fi
fi

fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
skip() { echo "SKIP $*"; }
info() { echo "INFO $*"; }
info "kernel $(uname -r), $(date -u '+%F %T') UTC"
dmesg | grep -o "last reset reason 0x.." | head -1 | sed 's/^/INFO pmic: /'
# the cpufreq and cpuidle checks need the balanced mode: on AC the desktop runs the
# performance profile (PowerDevil), whose l410_perf mode pins every policy at its maximum
PM=/sys/kernel/l410_perf/mode
if [ -w $PM ]; then
	oldmode=$(sed 's/.*\[\(.*\)\].*/\1/' $PM)
	if [ "$oldmode" != balanced ]; then
		echo balanced > $PM; info "l410_perf mode $oldmode -> balanced for the test (restored at exit)"
		trap 'echo "$oldmode" > $PM' EXIT
	fi
fi

# --- SPMI + PMIC -------------------------------------------------------------
if ls /sys/bus/spmi/devices/ 2>/dev/null | grep -q .; then
	pass "spmi: $(ls /sys/bus/spmi/devices | tr '\n' ' ')"
else
	fail "spmi: no SPMI devices"
fi
if dmesg | grep -q "hisi-spmi-pmic.*PMIC at SPMI usid 9"; then pass "pmic: probed (usid 9)"; else fail "pmic: not probed"; fi
dmesg | grep -i "secure read.*failed\|secure write.*failed" | head -3 | sed 's/^/INFO spmi error: /'

# --- PMIC regulators: name expected-uV [must-be-enabled] ----------------------
reg_by_name() { for r in /sys/class/regulator/regulator.*; do [ "$(cat $r/name)" = "$1" ] && echo $r && return; done; }
while read -r name uv on; do
	r=$(reg_by_name "$name")
	if [ -z "$r" ]; then fail "regulator $name: not registered"; continue; fi
	got=$(cat $r/microvolts 2>/dev/null); st=$(cat $r/state 2>/dev/null)
	if [ "$got" != "$uv" ]; then fail "regulator $name: ${got}uV, vendor ${uv}uV"; continue; fi
	if [ "$on" = on ] && [ "$st" != enabled ]; then fail "regulator $name: $st, vendor always-on"; continue; fi
	pass "regulator $name: ${got}uV $st"
done << 'EOF'
buck10 700000
ldo4 1800000
ldo9 1800000 on
ldo15 2550000 on
ldo16 1800000
ldo17 2500000
ldo21 1500000
ldo23 3200000
ldo24 2800000 on
ldo25 1100000
ldo29 1100000
ldo32 1000000
ldo38 1220000 on
EOF

# --- IP power domains --------------------------------------------------------
n=0; missing=""
for ip in media1_subsys media2_subsys npu g3d asp isp_r8 vdec hiface vdec_fake venc_fake mmbuf fp_csi_fake \
	vivobus vcodecsubsys dsssubsys ispsubsys ivp venc venc2; do
	if [ -n "$(reg_by_name $ip)" ]; then n=$((n + 1)); else missing="$missing $ip"; fi
done
if [ -z "$missing" ]; then pass "ip regulators: all 19 registered"
else fail "ip regulators: $n/19, missing:$missing"; fi
for ip in vivobus dsssubsys media1_subsys asp g3d; do
	r=$(reg_by_name $ip); [ -n "$r" ] && info "ip $ip: $(cat $r/state) users=$(cat $r/num_users)"
done
# optional test-only switches ("regulator-output" nodes power-test-<domain> from a test DT
# fixup + CONFIG_REGULATOR_USERSPACE_CONSUMER, see tests/power-test.dtsi; never committed)
for t in /sys/devices/platform/power-test-*; do
	[ -e $t/state ] || continue
	n=${t##*/power-test-}
	echo enabled > $t/state 2>/dev/null; a=$(cat $t/state)
	sleep 1
	echo disabled > $t/state 2>/dev/null; b=$(cat $t/state)
	if [ "$a" = enabled ] && [ "$b" = disabled ]; then pass "ip $n: power on/off"
	else fail "ip $n: on -> $a, off -> $b"; fi
done
dmesg | grep -i "firmware power o\|LPM3 power o\|LPM3 refused" | head -3 | sed 's/^/INFO /'
if dmesg | grep -q "peripheral voltage voters"; then pass "peri-dvfs: $(dmesg | grep -o '[0-9]* peripheral voltage voters.*' | head -1)"
else fail "peri-dvfs: not probed"; fi
dmesg | grep -i "kirin-peri-dvfs\|level .* not applied" | grep -iv "voters" | head -3 | sed 's/^/INFO /'

# --- PMIC clocks (clk-pmu-gate, PMIC regmap handed over by the PMIC driver) --
for c in clk_pmu32kb clk_pmuaudioclk; do
	d=/sys/kernel/debug/clk/$c
	if [ -d $d ]; then info "clk $c: rate=$(cat $d/clk_rate) enable_count=$(cat $d/clk_enable_count) prepare_count=$(cat $d/clk_prepare_count)"
	else info "clk $c: not registered"; fi
done
if dmesg | grep -q "no PMIC access yet"; then info "pmu clocks: $(dmesg | grep -o 'no PMIC access yet.*' | head -1) (a consumer came before the PMIC)"
else pass "pmu clocks: never used before the PMIC regmap was handed over"; fi

# --- RTC ---------------------------------------------------------------------
rtc=""
for r in /sys/class/rtc/rtc*; do [ "$(cat $r/name 2>/dev/null | cut -d' ' -f1)" = "hisi-spmi-rtc" ] && rtc=$r; done
if [ -z "$rtc" ]; then
	fail "rtc: hisi-spmi-rtc not registered"
else
	# Kylin keeps the RTC in local time (/etc/adjtime LOCAL on both OSes): the kernel reads it
	# as UTC, so the raw RTC is ahead of UTC by the local offset
	off=0
	if grep -qx LOCAL /etc/adjtime 2> /dev/null; then z=$(date +%z); off=$(( (${z:1:2} * 3600 + ${z:3:2} * 60) * ${z:0:1}1 )); fi
	e=$(cat $rtc/since_epoch); now=$(date +%s); d=$((e - now - off)); d=${d#-}
	if [ "$e" -lt 1780000000 ]; then fail "rtc: $(basename $rtc) reads $(cat $rtc/date) $(cat $rtc/time)"
	elif [ $d -gt 300 ]; then fail "rtc: $(basename $rtc) off by ${d}s from system time"
	else pass "rtc: $(basename $rtc) $(cat $rtc/date) $(cat $rtc/time) UTC (delta ${d}s)"; fi
	if [ -e $rtc/wakealarm ]; then
		irqs() { grep hisi-pmic-rtc /proc/interrupts | awk '{s=0; for (i=2;i<=9;i++) s+=$i; print s}'; }
		echo 0 > $rtc/wakealarm; echo +3 > $rtc/wakealarm
		before=$(irqs)
		sleep 5
		after=$(irqs)
		if [ -n "$after" ] && [ "${after:-0}" -gt "${before:-0}" ]; then pass "rtc: alarm interrupt fired"
		else fail "rtc: alarm interrupt did not fire (before=$before after=$after)"; fi
	else
		skip "rtc: no alarm support"
	fi
fi

# --- power key ---------------------------------------------------------------
if grep -q "HISI 65xx PowerOn Key" /proc/bus/input/devices; then pass "powerkey: input device registered"
else fail "powerkey: no input device"; fi

# --- temperature sensors -----------------------------------------------------
for t in cluster0 cluster1 cluster2 gpu modem npu peri hisec; do
	z=""
	for zz in /sys/class/thermal/thermal_zone*; do [ "$(cat $zz/type)" = "$t" ] && z=$zz; done
	if [ -z "$z" ]; then fail "thermal $t: no zone"; continue; fi
	v=$(cat $z/temp 2>/dev/null)
	if [ -n "$v" ] && [ "$v" -gt 10000 ] && [ "$v" -lt 100000 ]; then pass "thermal $t: $((v / 1000)).$(( (v % 1000) / 100 ))C"
	else fail "thermal $t: '$v'"; fi
done

# --- cpufreq -----------------------------------------------------------------
if [ ! -d /sys/devices/system/cpu/cpufreq/policy0 ]; then
	skip "cpufreq: not enabled in this kernel"
else
	for p in /sys/devices/system/cpu/cpufreq/policy*; do
		name=$(basename $p); drv=$(cat $p/scaling_driver)
		freqs=$(cat $p/scaling_available_frequencies)
		old=$(cat $p/scaling_governor)
		echo userspace > $p/scaling_governor 2>/dev/null || { fail "cpufreq $name: no userspace governor"; continue; }
		ok=1; seen=""
		for f in $(echo $freqs | awk '{print $1, $(int(NF/2)+1), $NF, $1}'); do
			echo $f > $p/scaling_setspeed
			for i in 1 2 3 4 5 6 7 8 9 10; do	# LPM3 needs a few ms
				cur=$(cat $p/cpuinfo_cur_freq 2>/dev/null || cat $p/scaling_cur_freq)
				[ "$cur" = "$f" ] && break
				sleep 0.1
			done
			seen="$seen $f->$cur"
			[ "$cur" = "$f" ] || ok=0
		done
		echo $old > $p/scaling_governor
		if [ $ok = 1 ]; then pass "cpufreq $name ($drv, cpus $(cat $p/related_cpus)):$seen"
		else fail "cpufreq $name ($drv):$seen (requested->granted)"; fi
	done
	# schedutil under load (informational)
	if command -v stress-ng > /dev/null; then
		stress-ng --cpu 8 --timeout 5 < /dev/null > /dev/null 2>&1 &
		sleep 3
		l=""; for p in /sys/devices/system/cpu/cpufreq/policy*; do l="$l $(basename $p)=$(cat $p/cpuinfo_cur_freq)"; done
		wait
		info "cpufreq under stress-ng ($(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor)):$l"
		sleep 2
		l=""; for p in /sys/devices/system/cpu/cpufreq/policy*; do l="$l $(basename $p)=$(cat $p/cpuinfo_cur_freq)"; done
		info "cpufreq idle again:$l"
	fi
	for c in /sys/class/thermal/cooling_device*; do
		[ -e "$c" ] && info "cooling $(basename $c) $(cat $c/type) max=$(cat $c/max_state) cur=$(cat $c/cur_state)"
	done
fi

# --- cpuidle -----------------------------------------------------------------
drv=$(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null)
if [ -z "$drv" ] || [ "$drv" = none ]; then
	skip "cpuidle: no driver"
else
	for c in 0 4 6; do
		s=/sys/devices/system/cpu/cpu$c/cpuidle
		line=""
		for st in $s/state*; do line="$line $(cat $st/name)=$(cat $st/usage)"; done
		echo "INFO cpuidle cpu$c:$line"
	done
	u1=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state1/usage 2>/dev/null); sleep 3
	u2=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state1/usage 2>/dev/null)
	if [ -n "$u2" ] && [ "$u2" -gt "$u1" ]; then pass "cpuidle: $drv, cpu0 deeper state entered"
	else fail "cpuidle: $drv, cpu0 state1 usage not increasing"; fi
fi

dmesg --level=err,warn 2>/dev/null | grep -i "spmi\|pmic\|regulator\|rtc\|tsens\|thermal\|cpufreq\|cpuidle\|psci\|hwvote\|hw-vote\|peri" | head -15 | sed 's/^/INFO dmesg: /'

echo "power.sh: $fails failure(s)"
exit $fails
