#!/bin/bash
# L410 quick self-check for the 6.18 kernel on Debian 13 (docs/testing/quick-suite.md).
# Unattended, non-destructive, about 2 minutes (--fast: about 30 s). Safe on a running
# desktop and over the WiFi ssh link: it never takes the network down, never stops the
# display manager, never suspends or reboots, never writes a block device, never touches
# MMIO, and puts back everything it changes (cpufreq, devfreq, thermal emulation,
# mixer, backlight, power mode) when it ends or is interrupted.
#
#   sudo bash tests/quick.sh [options]
#   ssh <l410> 'sudo bash -s -- [options]' < tests/quick.sh
#   dev/l410-harness.sh test <bundle> --script tests/quick.sh
#   dev/quick-remote.sh [options]                  (from the Windows/WSL host)
#
# Options:
#   --fast            skip the slower checks (load, I/O, playback, rendering, scans)
#   --only a,b        run only these modules      --skip a,b   skip these modules
#   --profile P       dev (default) or prod: in prod, test leftovers and debug knobs FAIL
#   --risky           also run checks that were never tried on this machine (CPU hotplug)
#   --out DIR         result directory (default /var/log/l410-quick/<time>)
#   --list            list the modules and exit
# Environment: L410Q_COUNTRY (expected WiFi country, default CN),
#   L410Q_IPERF (iperf3 server for WiFi/Ethernet throughput, optional)
#
# Output: one "<RES> <check-id> <message>" line per check, RES is one of
#   PASS FAIL WARN SKIP INFO, plus XFAIL (a FAIL listed in KNOWN below) and
#   XPASS (a check listed in KNOWN that now passes: take it off the list).
# Last lines: "RESULT: PASS" or "RESULT: FAIL (n)", then "SUMMARY: ..." and "OUT: <dir>".
# Exit status = number of unexpected FAILs. Files in <dir>: log.txt, results.tsv,
# results.jsonl, summary.json, klog-boot.txt, klog-run.txt, dt-unbound.txt.

if [ "$(id -u)" != 0 ]; then
	# bash reads a piped script byte by byte, so sudo's shell continues right after this line
	if [ -f "$0" ]; then exec sudo -n bash "$0" "$@"; else exec sudo -n bash -s -- "$@"; fi
fi

# Known failures: "<check-id glob> <plan-id> <reason>". A FAIL on one of these is
# reported as XFAIL and does not count; a PASS is reported as XPASS.
KNOWN='
dsp.edid-size          DSP-08  connector reports 0x0 mm (EDID not read through the bridge)
'

MODULES="env sys klog cpu mem soc pmic thermal ufs usb pcie wifi bt display gpu audio input ec perf sec img"
declare -A BUDGET=([env]=10 [sys]=20 [klog]=20 [cpu]=40 [mem]=25 [soc]=20 [pmic]=20 [thermal]=30
	[ufs]=40 [usb]=35 [pcie]=25 [wifi]=35 [bt]=35 [display]=20 [gpu]=45 [audio]=40 [input]=15
	[ec]=15 [perf]=25 [sec]=10 [img]=10)
declare -A DESC=([env]="machine, versions, power state" [sys]="systemd, boot, rootfs, time, taint, crashes"
	[klog]="kernel log since boot" [cpu]="topology, cpufreq, schedutil, cpuidle, EAS, CPU bugs"
	[mem]="size, CMA, memory stress" [soc]="clocks, IPC/LPM3, buses, DMA, DT bindings"
	[pmic]="SPMI/PMIC, regulators, power domains, RTC, power key" [thermal]="zones, trips, cooling, emulated 95 C"
	[ufs]="link, LUNs, write protection, health, I/O verify, hibern8" [usb]="PHY, hub, camera, NIC"
	[pcie]="root complexes, RTL8168, Hi1103 link" [wifi]="link, NetworkManager, regulatory, latency"
	[bt]="controller, HCI round trip, scan" [display]="DSS, eDP, vblank rate, backlight, PWM"
	[gpu]="Panfrost, EGL, DVFS read-back, rendering" [audio]="card, amps, playback, microphones, PipeWire"
	[input]="keyboard, touchpad, hotkeys, lid" [ec]="EC traffic, battery, AC, mute LED"
	[perf]="l410-perf modes and boosts, tuned, DDR" [sec]="kernel config audit, hardening"
	[img]="test leftovers in the installed system")

# ---------------------------------------------------------------- helpers
rd() { cat "$1" 2> /dev/null; }
has() { command -v "$1" > /dev/null 2>&1; }
drv_of() { local l; l=$(readlink "$1/driver" 2> /dev/null) && echo "${l##*/}"; }
in_range() { awk -v v="$1" -v a="$2" -v b="$3" 'BEGIN { exit !(v >= a && v <= b) }'; }
reg_by_name() { local r; for r in /sys/class/regulator/regulator.*; do [ "$(rd $r/name)" = "$1" ] && { echo $r; return 0; }; done; return 1; }
zone_by_type() { local z; for z in /sys/class/thermal/thermal_zone*; do [ "$(rd $z/type)" = "$1" ] && { echo $z; return 0; }; done; return 1; }
usbdev() { # sysfs dir of the first USB device with VID:PID $1
	local d
	for d in /sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] && [ "$(rd $d/idVendor):$(rd $d/idProduct)" = "$1" ] && { echo "$d"; return 0; }
	done
	return 1
}
klog() { cat "$OUT/klog-boot.txt"; }	# kernel log of this boot, as of the start of the run
killtree() { local c; for c in $(pgrep -P "$1"); do killtree "$c"; done; kill -KILL "$1" 2> /dev/null; }
dsec() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
now() { date +%s.%N; }

# results (modules run in subshells: everything goes through files)
known_of() {
	local pat plan reason
	while read -r pat plan reason; do
		[ -n "$pat" ] || continue
		# shellcheck disable=SC2053
		[[ $1 == $pat ]] && { echo "$plan $reason"; return 0; }
	done <<< "$KNOWN"
	return 1
}
_r() {
	local res=$1 id=$2 k
	shift 2
	local msg="$*"
	if k=$(known_of "$id"); then
		case $res in
		FAIL) res=XFAIL; msg="$msg  [known: $k]" ;;
		PASS) res=XPASS; msg="$msg  [listed as known: $k]" ;;
		esac
	fi
	printf '%-5s %-26s %s\n' "$res" "$id" "$msg"
	printf '%s\t%s\t%s\t%s\n' "$res" "$id" "${PLAN:--}" "${msg//$'\t'/ }" >> "$RES"
}
pass() { _r PASS "$@"; }
fail() { _r FAIL "$@"; }
warn() { _r WARN "$@"; }
skip() { _r SKIP "$@"; }
info() { _r INFO "$@"; }
hyg() { if [ "$PROFILE" = prod ]; then fail "$@"; else info "$@"; fi; }	# leftovers: FAIL only in prod
chk() { local id=$1 msg=$2; shift 2; if "$@" > /dev/null 2>&1; then pass "$id" "$msg"; else fail "$id" "$msg"; fi; }
slow() { [ "$FAST" != 1 ]; }

# undo list, run after every module and on exit
on_restore() { printf '%s\n' "$*" >> "$OUT/restore.sh"; }
do_restore() {
	[ -s "$OUT/restore.sh" ] || return 0
	tac "$OUT/restore.sh" > "$OUT/restore.run"
	: > "$OUT/restore.sh"
	bash "$OUT/restore.run" > /dev/null 2>&1
}
# systemd timer that undoes a change even if this script dies
guard_arm() { systemd-run --quiet --collect --unit="l410q-$1" --on-active="$2" /bin/sh -c "$3" 2> /dev/null; }
guard_disarm() { systemctl stop "l410q-$1.timer" 2> /dev/null; }

# processes holding a file, and whether an interface carries our ssh session / default route
holders() { fuser "$@" 2> /dev/null | tr -s ' ' | sed 's/^ //'; }
iface_in_use() {
	local peer
	ip route show default 2> /dev/null | grep -q "dev $1 " && return 0
	for peer in $(ss -Htn state established 2> /dev/null | awk '{ print $4 }' | sed 's/:[0-9]*$//; s/^\[//; s/\]$//' | sort -u); do
		ip route get "$peer" 2> /dev/null | grep -q "dev $1 " && return 0
	done
	return 1
}
# desktop / PipeWire user
pw_user() { ps -o user= -C pipewire 2> /dev/null | head -1; }
wl_session() { # prints "user uid WAYLAND_DISPLAY" of a running Wayland session
	local s u t uid
	for s in $(loginctl list-sessions --no-legend 2> /dev/null | awk '{ print $1 }'); do
		t=$(loginctl show-session "$s" -p Type --value 2> /dev/null)
		[ "$t" = wayland ] || continue
		u=$(loginctl show-session "$s" -p Name --value); uid=$(id -u "$u")
		for w in /run/user/$uid/wayland-*; do [ -S "$w" ] && { echo "$u $uid ${w##*/}"; return 0; }; done
	done
	return 1
}
as_user() { # $1 user, rest: command in that user's session environment
	local u=$1 uid
	shift
	uid=$(id -u "$u")
	runuser -u "$u" -- env XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
		${WL_DISPLAY:+WAYLAND_DISPLAY=$WL_DISPLAY} "$@"
}

# ---------------------------------------------------------------- env
m_env() {
	PLAN=SVC-04
	local p=/sys/class/dmi/id
	info env.kernel "$(uname -r), $(uname -v)"
	info env.cmdline "$(rd /proc/cmdline)"
	if [ "$(rd $p/product_name)" = "L410 KLVU-WDU0B" ]; then
		pass env.dmi "$(rd $p/sys_vendor) $(rd $p/product_name), serial $(rd $p/product_serial), BIOS $(rd $p/bios_version) ($(rd $p/bios_date)), EC $(rd $p/ec_firmware_release)"
	else
		fail env.dmi "product '$(rd $p/product_name)', want 'L410 KLVU-WDU0B' (SMBIOS not parsed?)"
	fi
	local b=/sys/class/power_supply/echub-battery t="" z
	info env.power "AC online=$(rd /sys/class/power_supply/echub-ac/online), battery $(rd $b/capacity)% $(rd $b/status), l410_perf $(rd /sys/kernel/l410_perf/mode), tuned $(tuned-adm active 2> /dev/null | sed 's/.*: //')"
	for z in /sys/class/thermal/thermal_zone*; do t="$t $(rd $z/type)=$(($(rd $z/temp) / 1000))"; done
	info env.temps "${t# } C"
	info env.uptime "$(cut -d' ' -f1 /proc/uptime) s since boot, load $(cut -d' ' -f1-3 /proc/loadavg)"
}

# ---------------------------------------------------------------- sys
m_sys() {
	local c x miss="" tst="" st u
	PLAN=BLD-06
	uname -r | grep -qE '^6\.18\.[0-9]+-l410' && pass sys.kernel "$(uname -r)" || fail sys.kernel "$(uname -r) is not a 6.18 l410 kernel"
	c=" $(rd /proc/cmdline) "
	PLAN=INS-02
	for x in efi=noruntime regulator_ignore_unused log_buf_len=; do [[ $c == *" $x"* ]] || miss="$miss $x"; done
	[ -z "$miss" ] && pass sys.cmdline-required "efi=noruntime regulator_ignore_unused log_buf_len present" ||
		fail sys.cmdline-required "missing:$miss"
	for x in l410_deadman= l410.mode= systemd.unit= nokaslr ignore_loglevel clk_ignore_unused pd_ignore_unused l410.ufstest l410.gfxtest cpuidle.off; do
		[[ $c == *" $x"* ]] && tst="$tst $x"
	done
	[ -z "$tst" ] && pass sys.cmdline-test-args "no test/bring-up arguments" || hyg sys.cmdline-test-args "test/bring-up arguments on the command line:$tst"

	PLAN=INS-07
	st=$(systemctl is-system-running 2> /dev/null)
	case $st in
	running) pass sys.state "systemd: running, no failed units" ;;
	starting) warn sys.state "systemd still starting" ;;
	*) fail sys.state "systemd: $st, failed: $(systemctl --failed --no-legend --plain 2> /dev/null | awk '{ print $1 }' | tr '\n' ' ')" ;;
	esac
	# a unit ordering cycle makes systemd drop a job from the boot transaction (10-01: mem-tune
	# Before=swap.target dropped tmp.mount, the late tmpfs hid /tmp/.X11-unix, Xwayland failed)
	x=$(journalctl -b --no-pager -o cat 2> /dev/null | grep -E "deleted to break ordering cycle" | sed 's/.*Job //' | sort -u | tr '\n' ' ')
	[ -z "$x" ] && pass sys.ordering-cycles "no jobs dropped for ordering cycles" || fail sys.ordering-cycles "dropped: $x"
	if pgrep -x kwin_wayland > /dev/null; then
		[ -d /tmp/.X11-unix ] && pass sys.x11-socket-dir "/tmp/.X11-unix present (Xwayland)" || fail sys.x11-socket-dir "/tmp/.X11-unix missing: Xwayland and X11 clients fail"
		u=$(stat -c %U /proc/$(pgrep -x kwin_wayland | head -1) 2> /dev/null)
		x=$(sudo -u "$u" XDG_RUNTIME_DIR=/run/user/$(id -u "$u") systemctl --user --failed --no-legend --plain 2> /dev/null | awk '{ print $1 }' | tr '\n' ' ')
		[ -z "$x" ] && pass sys.user-units "no failed units in $u's session" || fail sys.user-units "failed in $u's session: $x"
	fi
	PLAN=BOOT-07
	x=$(systemd-analyze 2> /dev/null | head -1)
	if [[ $x =~ =\ ([0-9.]+)(min|s) ]]; then
		u=${BASH_REMATCH[1]}; [ "${BASH_REMATCH[2]}" = min ] && u=$(awk -v m="$u" 'BEGIN { print m * 60 }')
		in_range "$u" 0 30 && pass sys.boot-time "${x#Startup finished in }" || warn sys.boot-time "${x#Startup finished in } (> 30 s)"
	else
		info sys.boot-time "systemd-analyze: ${x:-n/a}"
	fi
	PLAN=UX-01
	[ "$(systemctl is-active display-manager.service 2> /dev/null)" = active ] &&
		pass sys.graphical "display manager $(systemctl show -p Id --value display-manager.service) active" ||
		fail sys.graphical "no display manager running (sddm enabled: $(systemctl is-enabled sddm 2> /dev/null), default target $(systemctl get-default))"
	PLAN=BOOT-10
	x=$(rd /sys/kernel/debug/devices_deferred)
	[ -z "$x" ] && pass sys.deferred "no deferred probes" || fail sys.deferred "deferred: $(echo "$x" | awk '{ print $1 }' | tr '\n' ' ')"
	x=$(klog | grep -o "last reset reason 0x.." | head -1)
	info sys.reset-reason "PMIC ${x:-reason not logged} (0xff: set by firmware at boot)"

	PLAN=FLT-01
	x=$(coredumpctl list --no-pager --no-legend --since "$(uptime -s)" 2> /dev/null)
	[ -z "$x" ] && pass sys.coredumps "no user-space crash since boot" ||
		fail sys.coredumps "crashes since boot: $(echo "$x" | grep -oE '/[^ ]+' | sort | uniq -c | awk '{ printf "%s x%s ", $2, $1 }')"
	x=$(ls /sys/fs/pstore/dmesg-* 2> /dev/null)
	[ -z "$x" ] && pass sys.pstore "no crash record in pstore" ||
		warn sys.pstore "pstore holds a crash record: $(for f in $x; do printf '%s (%s) ' "${f##*/}" "$(date -r "$f" '+%F %T')"; done)"
	PLAN=BLD-07
	local t bad="" all="" i
	t=$(rd /proc/sys/kernel/tainted)
	local L=(P F S R M B U D A W C I O E L K X T N J)
	for i in "${!L[@]}"; do (( t >> i & 1 )) && all="$all${L[$i]}"; done
	for x in M B D W L; do [[ $all == *$x* ]] && bad="$bad$x"; done
	if [ -n "$bad" ]; then fail sys.taint "tainted $t ($all): $bad = machine check/bad page/oops/warning/soft lockup happened"
	elif [ -z "$all" ]; then pass sys.taint "not tainted"
	else pass sys.taint "tainted $t ($all: C staging, O out-of-tree, E unsigned module are expected in dev builds)"; fi

	PLAN=UX-10
	if [ "$(timedatectl show -p NTPSynchronized --value 2> /dev/null)" = yes ]; then pass sys.ntp "system clock NTP-synchronized"
	else warn sys.ntp "system clock not NTP-synchronized (NTP service: $(timedatectl show -p NTP --value 2> /dev/null), no timesyncd/chrony?)"; fi
	PLAN=SVC-02
	[ -d /var/log/journal ] && pass sys.journal "persistent journal, $(journalctl --disk-usage 2> /dev/null | grep -oE '[0-9.]+[KMGT]')" ||
		warn sys.journal "journal is not persistent"
	PLAN=UFS-04
	x=$(findmnt -no SOURCE,FSTYPE,OPTIONS /)
	# the Debian root: a partition of the user LUN (sdd), ext4, read-write
	ROOTDEV=$(findmnt -n -o SOURCE /)
	[[ $x == /dev/sdd[0-9]*\ ext4\ rw,* ]] && pass sys.rootfs "/ = $x" || fail sys.rootfs "/ = $x (want /dev/sddN ext4 rw)"
	x=$(tune2fs -l "$ROOTDEV" 2> /dev/null)
	if echo "$x" | grep -q "FS Error count"; then fail sys.rootfs-errors "ext4 recorded errors: $(echo "$x" | grep -E 'FS Error count|First error|Last error' | tr -s ' ' | tr '\n' ';')"
	elif echo "$x" | grep -q "Filesystem state: *clean"; then pass sys.rootfs-errors "ext4 state clean, no recorded errors"
	else warn sys.rootfs-errors "ext4 state: $(echo "$x" | grep 'Filesystem state' | tr -s ' ')"; fi
	u=$(df --output=pcent / | tail -1 | tr -dc 0-9)
	[ "$u" -le 90 ] && pass sys.rootfs-space "/ ${u}% used" || warn sys.rootfs-space "/ ${u}% used"
	PLAN=UFS-09
	[ "$(systemctl is-enabled fstrim.timer 2> /dev/null)" = enabled ] && pass sys.fstrim "fstrim.timer enabled" || warn sys.fstrim "fstrim.timer $(systemctl is-enabled fstrim.timer 2> /dev/null)"
	PLAN=MEM-04
	[ "$(wc -l < /proc/swaps)" -gt 1 ] && pass sys.swap "swap: $(tail -n +2 /proc/swaps | awk '{ printf "%s %s KiB ", $1, $3 }')" ||
		warn sys.swap "no swap or zram: OOM is the only answer to memory pressure"
	PLAN=ETH-04
	[ "$(timeout 5 nmcli -t -f RUNNING general 2> /dev/null)" = running ] && pass sys.nm "NetworkManager answers on D-Bus" || fail sys.nm "NetworkManager not answering"
	x=$(ip route show default | head -1)
	[ -n "$x" ] && pass sys.route "default route: $x" || warn sys.route "no default route"
}

# ---------------------------------------------------------------- klog
KLOG_ALLOW='OF: /(pddevice|fastboot): could not get #gpio-cells|lacks a native systemd unit file|include a native systemd unit file|This compatibility logic is deprecated|cs[0-9]+ >= max 1|spi_device register error /amba/spi@fa89f000/spi_dev3|Failed to create SPI device for /amba/spi@fa89f000/spi_dev3|[iv]mon-slot-no is missing|bridge window \[io|BAR [0-9]+ \[io|module is from the staging directory|^start mode=root|^root device /dev/|supply .* not found, using dummy regulator|DMA mask not set|Not disabling unused|L410INIT:|systemd-sysv-generator|loading out-of-tree module taints kernel|device has no listeners, quitting|get_board_dts_node_hi1105|get_board_dts_gpio_prop_hi1105|wlan_wakeup_host_have_reverser|buck_param_init|sdio driver don.t support|ps_get_core_reference_hi1105 pdev is NULL|readme.txt|plat_parse_readme|plat_read_changid|plat_cust_init failed|ram_reg_test_cfg|firmware_get_cfg_hi1105\]read cfg error|already suspended by the endpoint|pm_control\(2\) failed: -22|bfgx_(dev|uart)_state_set|No LED Child node|Hi6405 version 0x0, chip id 00 ff'
SPLAT='Internal error:|Unable to handle kernel|SError Interrupt|Asynchronous SError|(^|[^[:alnum:]_])BUG: |WARNING: CPU|Oops[: ]|Kernel panic|detected stalls|self-detected stall|soft lockup|hard LOCKUP|blocked for more than [0-9]+ seconds'
klog_lvl() {	# klog_lvl 0..3: kernel lines of this boot at those levels, like -o cat, minus what a
	# test provoked on purpose: ufs.sh's host reset step (its "reset" marker up to the next marker)
	local w
	w=$(journalctl -k -b -o short-monotonic --no-pager 2> /dev/null | awk '
		match($0, /^\[ *[0-9.]+\]/) { t = substr($0, RSTART + 1, RLENGTH - 2) + 0 }
		/l410-ufs-test: [^ ]+ reset$/ { s = t; open = 1; next }
		open && /l410-ufs-test: / { print s, t; open = 0 }
		END { if (open) print s, t }')
	journalctl -k -b -p "$1" -o short-monotonic --no-pager 2> /dev/null | awk -v w="$w" '
		BEGIN { n = split(w, a, " ") }
		{ if (!match($0, /^\[ *[0-9.]+\]/)) next
		  t = substr($0, RSTART + 1, RLENGTH - 2) + 0
		  for (i = 1; i < n; i += 2) if (t >= a[i] && t <= a[i + 1]) next
		  sub(/^\[ *[0-9.]+\] [^ ]+ [^ :]+: /, ""); print }'
}
m_klog() {
	local x n
	PLAN=BOOT-10
	x=$(klog | grep -E "$SPLAT" | grep -v ramoops)
	[ -z "$x" ] && pass klog.splat "no oops/BUG/WARNING/SError/stall/lockup since boot" ||
		fail klog.splat "$(echo "$x" | wc -l) line(s): $(echo "$x" | head -3 | cut -c1-160 | tr '\n' '|')"
	x=$(klog_lvl 0..3 | grep -vE "$KLOG_ALLOW")
	[ -z "$x" ] && pass klog.errors "no unexpected error-level kernel messages" ||
		fail klog.errors "$(echo "$x" | wc -l) unexpected error line(s): $(echo "$x" | sort | uniq -c | sort -rn | head -6 | awk '{ $1 = $1 "x"; print }' | cut -c1-140 | tr '\n' '|')"
	x=$(klog_lvl 4..4 | grep -vE "$KLOG_ALLOW")
	[ -z "$x" ] && pass klog.warnings "no unexpected warning-level kernel messages" ||
		warn klog.warnings "$(echo "$x" | wc -l) warning line(s): $(echo "$x" | sort | uniq -c | sort -rn | head -6 | awk '{ $1 = $1 "x"; print }' | cut -c1-140 | tr '\n' '|')"
	PLAN=WLAN-15
	n=$(klog | awk 'match($0, /^\[ *[0-9.]+\]/) && substr($0, RSTART + 1, RLENGTH - 2) + 0 <= 120' | grep -cE 'hi110x|HI11XX|\[PCIE|hwifi|hmac_|wal_|plat_init')
	[ "$n" -le 100 ] && pass klog.wifi-volume "$n WiFi/BT driver lines in the first 120 s" || fail klog.wifi-volume "$n WiFi/BT driver lines in the first 120 s (> 100)"
	PLAN=BOOT-10
	local pat id
	while IFS='|' read -r id pat; do
		n=$(klog | grep -cE "$pat")
		[ "$n" = 0 ] && pass "klog.$id" "none since boot" || fail "klog.$id" "$n since boot: $(klog | grep -E "$pat" | tail -1 | cut -c1-140)"
	done << 'EOF'
dss-underflow|LDI underflow
pcie-timeout|[Cc]ompletion [Tt]imeout|cpl_timeout|pcie-kport.*link down
usb-errors|xhci.*(HC died|halt failed|Timeout while waiting)|device descriptor read.*error|device not accepting address|unable to enumerate|kirin990-usb-phy.*(timeout|failed)
ufs-errors|ufshcd.*(error|Error|fail|abort|timed out)|I/O error, dev sd
i2c-errors|i2c_designware.*(timeout|timed out|lost arbitration)|controller timed out
gpu-errors|panfrost.*(job timeout|MMU fault|[Uu]nhandled|reset)
thermal-critical|critical temperature reached|thermal.*shutdown
ipc-timeouts|kirin-ipc.*(timeout|no ack)
EOF
	n=$(klog | grep -c "Out of memory: Killed process")
	[ "$n" = 0 ] && pass klog.oom "no OOM kills since boot" || warn klog.oom "$n OOM kills since boot"
}

# ---------------------------------------------------------------- cpu
m_cpu() {
	local x p c n bad="" f
	PLAN=SOC-01
	[ "$(nproc --all)" = 8 ] && [ "$(rd /sys/devices/system/cpu/online)" = 0-7 ] && pass cpu.online "8 CPUs online" ||
		fail cpu.online "online $(rd /sys/devices/system/cpu/online) of $(nproc --all)"
	x=""; for c in 0 1 2 3 4 5 6 7; do x="$x$(rd /sys/devices/system/cpu/cpu$c/regs/identification/midr_el1 | sed 's/^0x00000000//') "; done
	[ "$x" = "411fd050 411fd050 411fd050 411fd050 483fd400 483fd400 483fd400 483fd400 " ] &&
		pass cpu.midr "4x Cortex-A55 r1p0 + 4x HiSilicon 0xd40" || fail cpu.midr "MIDR: $x"
	x=""; for c in 0 1 2 3 4 5 6 7; do x="$x$(rd /sys/devices/system/cpu/cpu$c/cpu_capacity) "; done
	[ "$x" = "283 283 283 283 767 767 1024 1024 " ] && pass cpu.capacity "capacities $x" || warn cpu.capacity "capacities $x (expected 283x4 767x2 1024x2)"

	PLAN=SOC-03
	local w pol cpus lo hi want
	for w in policy0:0_1_2_3:554000:1863000 policy4:4_5:826000:2088000 policy6:6_7:1536000:2861000; do
		IFS=: read -r pol cpus lo hi <<< "$w"
		p=/sys/devices/system/cpu/cpufreq/$pol
		if [ ! -d $p ]; then fail cpu.freq-$pol "missing"; continue; fi
		n=$(rd $p/scaling_available_frequencies | wc -w)
		if [ "$(rd $p/related_cpus)" = "${cpus//_/ }" ] && [ "$(rd $p/cpuinfo_min_freq)" = $lo ] && [ "$(rd $p/cpuinfo_max_freq)" = $hi ] &&
			[ "$n" = 13 ] && [ "$(rd $p/scaling_driver)" = hisi-hwvote ]; then
			pass cpu.freq-$pol "cpus ${cpus//_/ }, $((lo / 1000))-$((hi / 1000)) MHz, 13 OPPs, hisi-hwvote, $(rd $p/scaling_governor)"
		else
			fail cpu.freq-$pol "cpus $(rd $p/related_cpus), $(rd $p/cpuinfo_min_freq)-$(rd $p/cpuinfo_max_freq), $n OPPs, $(rd $p/scaling_driver)"
		fi
		# LPM3 grants exactly what is voted: set min/mid/max with the userspace governor, read back
		if [ "$(rd $p/scaling_min_freq)" != "$(rd $p/cpuinfo_min_freq)" ] || [ "$(rd $p/scaling_max_freq)" != "$(rd $p/cpuinfo_max_freq)" ]; then
			skip cpu.vote-$pol "range narrowed to $(rd $p/scaling_min_freq)-$(rd $p/scaling_max_freq) (power mode/thermal)"
			continue
		fi
		local old seen="" ok=1 i cur
		old=$(rd $p/scaling_governor)
		on_restore "echo $old > $p/scaling_governor"
		if ! echo userspace > $p/scaling_governor 2> /dev/null; then skip cpu.vote-$pol "no userspace governor"; continue; fi
		for f in $(rd $p/scaling_available_frequencies | awk '{ print $1, $(int(NF / 2) + 1), $NF, $1 }'); do
			echo $f > $p/scaling_setspeed
			for i in 1 2 3 4 5 6 7 8 9 10; do cur=$(rd $p/cpuinfo_cur_freq); [ "$cur" = $f ] && break; sleep 0.05; done
			seen="$seen $((f / 1000))->$((cur / 1000))"; [ "$cur" = $f ] || ok=0
		done
		echo $old > $p/scaling_governor
		[ $ok = 1 ] && pass cpu.vote-$pol "voted->granted MHz:$seen" || fail cpu.vote-$pol "voted->granted MHz:$seen"
	done

	PLAN=PERF-08
	if slow && has stress-ng; then
		local gov_ok=1
		for p in /sys/devices/system/cpu/cpufreq/policy*; do [ "$(rd $p/scaling_governor)" = schedutil ] || gov_ok=0; done
		if [ $gov_ok = 1 ]; then
			stress-ng --cpu 8 --timeout 4 --quiet > /dev/null 2>&1 &
			local sp=$!
			sleep 2.5
			x=""; bad=""
			for p in /sys/devices/system/cpu/cpufreq/policy*; do
				f=$(rd $p/cpuinfo_cur_freq); x="$x ${p##*/}=$((f / 1000))"
				awk -v f=$f -v m=$(rd $p/scaling_max_freq) 'BEGIN { exit !(f >= 0.9 * m) }' || bad="$bad ${p##*/}"
			done
			wait $sp
			[ -z "$bad" ] && pass cpu.schedutil-load "under load (MHz):$x" || fail cpu.schedutil-load "under load (MHz):$x, not at max:$bad"
			local k
			for k in $(seq 1 16); do	# up to 4 s for the frequencies to come down
				sleep 0.25
				x=""; bad=""
				for p in /sys/devices/system/cpu/cpufreq/policy*; do
					f=$(rd $p/cpuinfo_cur_freq); x="$x ${p##*/}=$((f / 1000))"
					awk -v f=$f -v a=$(rd $p/scaling_min_freq) -v b=$(rd $p/scaling_max_freq) 'BEGIN { exit !(f <= a + (b - a) / 2) }' || bad="$bad ${p##*/}"
				done
				[ -z "$bad" ] && break
			done
			[ -z "$bad" ] && pass cpu.schedutil-idle "idle again after $(awk -v k=$k 'BEGIN { print k / 4 }') s (MHz):$x" ||
				warn cpu.schedutil-idle "4 s after the load (MHz):$x, still high:$bad ($(ps -eo pcpu,psr,comm --sort=-pcpu | awk 'NR > 1 && NR <= 4 { printf "%s%%@cpu%s %s, ", $1, $2, $3 }'))"
		else
			skip cpu.schedutil-load "governor is not schedutil everywhere"
		fi
	fi

	PLAN=SOC-04
	x=$(rd /sys/devices/system/cpu/cpuidle/current_driver)
	if [ "$x" != psci_idle ]; then fail cpu.idle "cpuidle driver '$x'"; else
		local s0 s1 names="" dis="" deep qos=""
		declare -A u0
		# performance mode holds a CPU latency QoS (l410_perf perf_latency_us, 100 us): states
		# with a longer exit latency (cluster off) are not entered, by design
		[ "$(sed 's/.*\[\(.*\)\].*/\1/' /sys/kernel/l410_perf/mode 2> /dev/null)" = performance ] &&
			qos=$(rd /sys/kernel/l410_perf/perf_latency_us)
		deepest() { local s best=""; for s in $(ls -d /sys/devices/system/cpu/cpu$1/cpuidle/state* | sort -V); do
			{ [ -z "$qos" ] || [ "$(rd $s/latency)" -le "$qos" ]; } && best=$s; done; echo $best; }
		for c in 0 4 6; do
			deep=$(deepest $c)
			u0[$c]=$(rd $deep/usage); names="$names cpu$c:$(rd $deep/name)"
			for s0 in /sys/devices/system/cpu/cpu$c/cpuidle/state*; do [ "$(rd $s0/disable)" = 0 ] || dis="$dis cpu$c/$(rd $s0/name)"; done
		done
		sleep 1.5
		bad=""
		for c in 0 4 6; do
			deep=$(deepest $c)
			s1=$(rd $deep/usage); [ "$s1" -gt "${u0[$c]}" ] || bad="$bad cpu$c"
		done
		[ -n "$qos" ] && names="$names (performance mode, latency QoS $qos us)"
		if [ -n "$dis" ]; then fail cpu.idle "idle states disabled:$dis"
		elif [ -z "$bad" ]; then pass cpu.idle "psci_idle, deepest states entered in 1.5 s:$names"
		else warn cpu.idle "deepest state not entered in 1.5 s on:$bad (busy system?)"; fi
	fi

	PLAN=PERF-08
	n=$(klog | grep -c "energy model, 13 states")
	[ "$n" = 3 ] && [ "$(rd /proc/sys/kernel/sched_energy_aware)" = 1 ] && pass cpu.eas "energy model on 3 clusters, sched_energy_aware=1" ||
		fail cpu.eas "energy model on $n clusters, sched_energy_aware=$(rd /proc/sys/kernel/sched_energy_aware)"
	[ -e /proc/sys/kernel/sched_util_clamp_min_rt_default ] && pass cpu.uclamp "uclamp sysctls present (rt default $(rd /proc/sys/kernel/sched_util_clamp_min_rt_default))" || fail cpu.uclamp "no uclamp"
	x=/proc/sys/kernel/sched_pelt_multiplier
	if [ -e $x ]; then
		local old ok=1 m; old=$(rd $x)
		on_restore "echo $old > $x"
		for m in 2 4 1; do echo $m > $x 2> /dev/null && [ "$(rd $x)" = $m ] || ok=0; done
		echo 3 > $x 2> /dev/null && ok=0
		echo $old > $x
		[ $ok = 1 ] && pass cpu.pelt "PELT multiplier switches 1/2/4, rejects 3 (now $old)" || fail cpu.pelt "PELT multiplier sysctl misbehaves"
	else
		fail cpu.pelt "no sched_pelt_multiplier"
	fi
	x=$(rd /sys/devices/system/cpu/cpufreq/policy0/schedutil/rate_limit_us)
	[ -n "$x" ] || x=$(rd /sys/devices/system/cpu/cpufreq/schedutil/rate_limit_us)
	local mode; mode=$(sed 's/.*\[\(.*\)\].*/\1/' /sys/kernel/l410_perf/mode 2> /dev/null)
	if [ "$mode" = powersave ]; then want=3000; else want=500; fi
	if [ -z "$x" ]; then info cpu.rate-limit "schedutil rate_limit_us not readable"
	elif [ "$x" = $want ]; then pass cpu.rate-limit "schedutil rate_limit_us $x ($mode)"
	else warn cpu.rate-limit "schedutil rate_limit_us $x, want $want for $mode"; fi

	PLAN=SEC-01
	bad=""; local wv=""
	for f in /sys/devices/system/cpu/vulnerabilities/*; do
		x=$(rd $f)
		case $x in
		Vulnerable*) bad="$bad ${f##*/}" ;;
		*"not BHB"* | Unknown*) wv="$wv ${f##*/}='$x'" ;;
		esac
	done
	if [ -n "$bad" ]; then fail cpu.vulnerabilities "vulnerable:$bad"
	elif [ -n "$wv" ]; then warn cpu.vulnerabilities "partly mitigated:$wv (0xd40 core not in the kernel's Spectre-BHB lists)"
	else pass cpu.vulnerabilities "all Not affected/Mitigation"; fi
	PLAN=SOC-16
	x=$(rd /sys/bus/event_source/devices/armv8_pmuv3/cpus)
	[ -z "$x" ] && x=$(ls /sys/bus/event_source/devices | grep -E '^armv8' | tr '\n' ' ')
	[ -n "$x" ] && pass cpu.pmu "CPU PMU on cpus $x, DSU PMU $([ -d /sys/bus/event_source/devices/arm_dsu_0 ] && echo yes || echo no)" || fail cpu.pmu "no CPU PMU"

	PLAN=SOC-02
	if [ "$RISKY" = 1 ]; then
		echo 0 > /sys/devices/system/cpu/cpu7/online 2> /dev/null; x=$(rd /sys/devices/system/cpu/online)
		echo 1 > /sys/devices/system/cpu/cpu7/online 2> /dev/null; sleep 0.3
		[ "$x" = 0-6 ] && [ "$(rd /sys/devices/system/cpu/online)" = 0-7 ] && pass cpu.hotplug "cpu7 offline/online" || fail cpu.hotplug "offline -> $x, online -> $(rd /sys/devices/system/cpu/online)"
	fi
}

# ---------------------------------------------------------------- mem
m_mem() {
	local t f
	PLAN=MEM-01
	t=$(awk '/^MemTotal/ { print $2 }' /proc/meminfo)
	[ "$t" -ge 7700000 ] && pass mem.total "MemTotal $((t / 1024)) MiB" || fail mem.total "MemTotal $((t / 1024)) MiB (want about 7683 MiB)"
	t=$(awk '/^CmaTotal/ { print $2 }' /proc/meminfo); f=$(awk '/^CmaFree/ { print $2 }' /proc/meminfo)
	[ "$t" = 131072 ] && [ "$f" -ge 16384 ] && pass mem.cma "CMA 128 MiB, $((f / 1024)) MiB free" || warn mem.cma "CMA total ${t} KiB, free ${f} KiB"
	PLAN=SVC-02
	[ "$(drv_of /sys/bus/platform/devices/26e00000.pstore-mem)" = ramoops ] && mountpoint -q /sys/fs/pstore &&
		pass mem.ramoops "ramoops at 0x26e00000 bound, pstore mounted ($(ls /sys/fs/pstore | tr '\n' ' '))" || fail mem.ramoops "ramoops not bound to 26e00000.pstore-mem or pstore not mounted"
	PLAN=MEM-05
	info mem.slab "$(awk '/^(Slab|SUnreclaim|KernelStack|PageTables|VmallocUsed)/ { printf "%s %d MiB  ", $1, $2 / 1024 }' /proc/meminfo)"
	PLAN=MEM-02
	if slow && has stress-ng; then
		if stress-ng --vm 2 --vm-bytes 256M --vm-method all --verify --timeout 5 --quiet > "$OUT/mem-stress.txt" 2>&1; then
			pass mem.stress "2x256 MiB, all vm methods, 5 s, verified"
		else
			fail mem.stress "stress-ng --vm --verify failed: $(tail -2 "$OUT/mem-stress.txt" | tr '\n' ' ')"
		fi
	fi
}

# ---------------------------------------------------------------- soc
m_soc() {
	local D=/sys/kernel/debug x n c want got bad=""
	PLAN=SOC-05
	x=$(klog | grep -o "kirin-clk: [0-9]* clock nodes.*" | tail -1)
	[[ $x == *" 0 without provider, 0 orphans"* ]] && pass soc.clk-report "${x#kirin-clk: }" || fail soc.clk-report "${x:-no kirin-clk report}"
	x=$(klog | grep -o "kirin-clk: gating .*" | tail -1)
	[ -n "$x" ] && info soc.clk-gating "${x#kirin-clk: }" || info soc.clk-gating "no gating report (keep-on mode?)"
	n=$(awk 'NR > 3 && NF' $D/clk/clk_orphan_summary 2> /dev/null | wc -l)
	[ "$n" = 0 ] && pass soc.clk-orphans "no orphan clocks" || fail soc.clk-orphans "$n orphan clocks"
	while read -r c want; do
		got=$(rd $D/clk/$c/clk_rate)
		{ [ -n "$got" ] && [ $((got - want)) -ge -2 ] && [ $((got - want)) -le 2 ]; } || bad="$bad $c=${got:-none}(want $want)"
	done << 'EOF'
clkin_sys 38400000
clk_ppll0 1660000000
clk_ap_ppll2 1920000000
clk_ap_ppll6 1720000000
sc_div_aobus 37449142
clkmux_i2c 110666666
clk_i2c7 110666666
clk_uart4 166000000
uart6clk 19200000
clk_pmu32kb 32764
clk_pmuaudioclk 19200000
EOF
	[ -z "$bad" ] && pass soc.clk-rates "11 key clock rates match the vendor kernel" || fail soc.clk-rates "mismatch:$bad"

	PLAN=SOC-06
	n=$(ls /sys/bus/platform/drivers/kirin-ipc-mailbox 2> /dev/null | grep -c '\.ipc$')
	[ "$n" = 3 ] && pass soc.ipc-bound "3 IPC mailbox blocks" || fail soc.ipc-bound "$n IPC blocks (want 3)"
	n=$(awk 'NR > 1 { t += $9 } END { print t + 0 }' $D/kirin-ipc/channels 2> /dev/null)
	[ "$n" = 0 ] && pass soc.ipc-timeouts "no mailbox ACK timeouts since boot" || fail soc.ipc-timeouts "$n mailbox ACK timeouts"
	if [ -w $D/kirin-ipc/xfer ]; then
		# the "keep PPLL0 on" vote the vendor clock driver also sends: harmless
		local a0 a1; a0=$(awk '$2 == "mailbox-13" { print $7 }' $D/kirin-ipc/channels)
		echo "HISI_ACPU_LPM3_MBX_1 0xd0002 0x0" > $D/kirin-ipc/xfer 2> /dev/null
		x=$(rd $D/kirin-ipc/xfer); a1=$(awk '$2 == "mailbox-13" { print $7 }' $D/kirin-ipc/channels)
		[ "${x%% *}" = 0 ] && [ "${a1:-0}" -gt "${a0:-0}" ] && pass soc.ipc-lpm3 "LPM3 round trip, ACK: ${x#* }" || fail soc.ipc-lpm3 "LPM3 round trip: '$x' acked $a0->$a1"
	else
		skip soc.ipc-lpm3 "no debugfs xfer interface"
	fi

	PLAN=SOC-12
	bound() { local n; n=$(ls /sys/bus/$1/drivers/$2 2> /dev/null | grep -cvE '^(bind|unbind|uevent|module|new_id|remove_id)$'); [ "$n" -ge "$3" ] && pass "soc.bound-$4" "$2 x$n" || fail "soc.bound-$4" "$2 x$n (want >= $3)"; }
	bound platform kirin-hwspinlock 1 hwspinlock
	bound platform hisi-dma64 1 dma
	bound platform pinctrl-single 8 pinctrl
	bound amba pl061_gpio 37 gpio
	bound amba uart-pl011 4 uart
	bound amba ssp-pl022 1 spi
	bound platform i2c_designware 4 i2c
	n=0; for c in 3 4 6 7; do [ -e /sys/bus/i2c/devices/i2c-$c ] && n=$((n + 1)); done
	[ $n = 4 ] && pass soc.i2c-buses "i2c-3/4/6/7 present" || fail soc.i2c-buses "$n of i2c-3/4/6/7"
	if has i2ctransfer; then
		x=$(i2ctransfer -f -y 4 w1@0x2c 0x00 r8@0x2c 2> /dev/null)
		[ "$x" = "0x36 0x38 0x49 0x53 0x44 0x20 0x20 0x20" ] && pass soc.sn65dsi86 "i2c4 0x2c eDP bridge ID '68ISD'" || fail soc.sn65dsi86 "i2c4 0x2c ID: ${x:-no answer}"
	fi
	PLAN=SOC-13
	local M=/sys/module/dmatest/parameters
	if slow && [ -w $M/run ] && [ -e /sys/class/dma/dma0chan0 ]; then
		n=$(dmesg | grep -c "dmatest: dma0chan0-copy0: summary")
		echo 2000 > $M/timeout; echo 20 > $M/iterations; echo 4096 > $M/test_buf_size
		echo dma0chan0 > $M/channel; echo 1 > $M/run; cat $M/wait > /dev/null
		x=$(dmesg | grep "dmatest: dma0chan0-copy0: summary" | tail -1)
		[ "$(dmesg | grep -c "dmatest: dma0chan0-copy0: summary")" -gt "$n" ] && [[ $x == *" 0 failures"* ]] &&
			pass soc.dmatest "20 memcpy on dma0chan0: ${x#*summary }" || fail soc.dmatest "${x:-no summary}"
	fi

	PLAN=SOC-15
	# devices this machine needs, with the driver that must hold them
	bad=""
	while read -r bus dev drv; do
		[ -n "$bus" ] || continue
		local d; d=$(ls -d /sys/bus/$bus/devices/$dev 2> /dev/null | head -1)
		[ -n "$d" ] && [ "$(drv_of "$d")" = "$drv" ] || bad="$bad $dev(${d:+$(drv_of "$d")}${d:-absent})"
	done << 'EOF'
platform f8200000.ufs ufshcd-kirin
platform f8480000.usb_phy kirin990-usb-phy
platform hisi_usb@f8480000 dwc3-kirin990
platform f8400000.dwc3 dwc3
platform f8400000.dwc3:hub@1 onboard-usb-dev
platform xhci-hcd.*.auto xhci-hcd
platform f0000000.pcie_kport_rc pcie-kport
platform f4000000.pcie_kport_rc pcie-kport
platform e8400000.dpe kirin990-dss
platform fe140000.mali panfrost
platform fa875000.panel_blpwm hisi-blpwm
platform backlight pwm-backlight
platform fe104000.codec_controller hi6405-ctrl
platform fe104000.codec_controller:hi64xx_irq@0 hi64xx_irq
platform fe104000.codec_controller:hi64xx_irq@0:hi6405_codec@0 DA_combine_v5
platform fa550000.slimbusmisc hisilicon,slimbus
platform fa54b000.hi64xx_asp_dmac hisi-asp-pcm
platform sound_hi6405 hi6405-card
platform fa890000.spmi hisi_spmi_controller
platform fa890000.spmi:pmic@0:pmic_rtc@a0 hisi-spmi-rtc
platform fa890000.spmi:pmic@0:ponkey@b1 hi65xx-powerkey
platform hisi-spmi-pmic-irq.*.auto hisi-spmi-pmic-irq
platform e8601000.regulator_ip hisi-ip-regulator-core
platform fe101000.ipc kirin-ipc-mailbox
platform fa899000.ipc kirin-ipc-mailbox
platform e5e01000.ipc kirin-ipc-mailbox
platform hwspinlock kirin-hwspinlock
platform fa000000.dma hisi-dma64
platform fff01000.hw_vote kirin-hw-vote
platform fff01000.peri_dvfs kirin-peri-dvfs
platform hisi-hwvote-cpufreq hisi-hwvote-cpufreq
platform fffc0000.ddr_devfreq kirin990-ddr-devfreq
platform tsens@0 hisi-tsens-smc
platform 26e00000.pstore-mem ramoops
platform hi110x hi110x_board
platform hisi_bfgx hisi_bfgx
platform echub_state huawei-echub-sync
platform huawei-echub-battery.*.auto huawei-echub-battery
platform huawei-echub-led.*.auto huawei-echub-led
platform pmu armv8-pmu
amba fa041000.uart uart-pl011
amba fa89f000.spi ssp-pl022
i2c 3-004c tas2562
i2c 3-004e tas2562
i2c 6-005d i2c_hid_of
i2c 7-0038 huawei-echub
i2c 7-003a i2c_hid_of
spmi 0-09 hisi-spmi-pmic
serial serial0-0 hi110x-bfgx-uart
pci 0000:00:00.0 pcieport
pci 0000:01:00.0 r8169
pci 0001:00:00.0 pcieport
pci 0001:01:00.0 hi110x_pci
EOF
	[ -z "$bad" ] && pass soc.dt-core-bound "all 53 devices this machine needs are bound to the right driver" || fail soc.dt-core-bound "not bound:$bad"
	# DT devices nobody drives (phone leftovers, intentionally unsupported blocks): record the list
	for x in platform amba i2c spi; do
		for c in /sys/bus/$x/devices/*; do [ -e "$c/of_node" ] && [ ! -e "$c/driver" ] && echo "$x ${c##*/}"; done
	done > "$OUT/dt-unbound.txt"
	info soc.dt-unbound "$(wc -l < "$OUT/dt-unbound.txt") DT devices without a driver (list in dt-unbound.txt; see test-plan SOC-15)"
}

# ---------------------------------------------------------------- pmic
m_pmic() {
	local x r name uv on got st bad="" n=0 miss=""
	PLAN=SOC-08
	klog | grep -q "PMIC at SPMI usid 9" && pass pmic.probe "PMIC on SPMI usid 9 (via ATF SMC)" || fail pmic.probe "PMIC not probed"
	while read -r name uv on; do
		r=$(reg_by_name "$name") || { bad="$bad $name(missing)"; continue; }
		got=$(rd $r/microvolts); st=$(rd $r/state)
		[ "$got" = "$uv" ] || bad="$bad $name=${got}uV"
		[ "$on" = on ] && [ "$st" != enabled ] && bad="$bad $name:$st"
	done << 'EOF'
buck10 700000
ldo4 1800000
ldo9 1800000 on
ldo15 2550000 on
ldo16 1800000
ldo17 2500000
ldo21 1500000
ldo23 3200000 on
ldo24 2800000 on
ldo25 1100000
ldo29 1100000
ldo32 1000000
ldo38 1220000 on
EOF
	[ -z "$bad" ] && pass pmic.regulators "13 LDO/BUCK voltages as on the vendor kernel, UFS/USB/always-on supplies enabled" || fail pmic.regulators "$bad"
	for x in media1_subsys media2_subsys npu g3d asp isp_r8 vdec hiface vdec_fake venc_fake mmbuf fp_csi_fake \
		vivobus vcodecsubsys dsssubsys ispsubsys ivp venc venc2; do
		reg_by_name $x > /dev/null && n=$((n + 1)) || miss="$miss $x"
	done
	[ -z "$miss" ] && pass pmic.ip-domains "19 IP power domains registered" || fail pmic.ip-domains "$n/19, missing:$miss"
	bad=""
	for x in dsssubsys media1_subsys vivobus; do r=$(reg_by_name $x) && [ "$(rd $r/state)" = enabled ] || bad="$bad $x"; done
	[ -z "$bad" ] && pass pmic.display-domains "dsssubsys, media1_subsys, vivobus on (display in use)" || fail pmic.display-domains "off:$bad"
	x=$(klog | grep -o "[0-9]* peripheral voltage voters" | head -1)
	[ -n "$x" ] && pass pmic.peri-dvfs "$x" || fail pmic.peri-dvfs "peri-dvfs not probed"
	PLAN=SOC-09
	local rtc=""
	for r in /sys/class/rtc/rtc*; do [[ $(rd $r/name) == hisi-spmi-rtc* ]] && rtc=$r; done
	if [ -z "$rtc" ]; then fail pmic.rtc "hisi-spmi-rtc not registered"; else
		local off=0 e z d
		if grep -qx LOCAL /etc/adjtime 2> /dev/null; then z=$(date +%z); off=$(((10#${z:1:2} * 3600 + 10#${z:3:2} * 60) * ${z:0:1}1)); fi
		e=$(rd $rtc/since_epoch); d=$((e - $(date +%s) - off)); d=${d#-}
		[ "$d" -le 5 ] && pass pmic.rtc "${rtc##*/} $(rd $rtc/date) $(rd $rtc/time), $d s from system time ($(grep -qx LOCAL /etc/adjtime && echo LOCAL || echo UTC))" ||
			fail pmic.rtc "${rtc##*/} is $d s away from system time"
		if slow && [ -e $rtc/wakealarm ] && [ -z "$(rd $rtc/wakealarm)" ]; then
			local i0 i1
			irqs() { grep hisi-pmic-rtc /proc/interrupts | awk '{ s = 0; for (i = 2; i <= 9; i++) s += $i; print s }'; }
			i0=$(irqs); echo +2 > $rtc/wakealarm; sleep 3.2; i1=$(irqs)
			echo 0 > $rtc/wakealarm
			[ "${i1:-0}" -gt "${i0:-0}" ] && pass pmic.rtc-alarm "alarm interrupt fired" || fail pmic.rtc-alarm "alarm interrupt did not fire ($i0 -> $i1)"
		fi
	fi
	PLAN=BOOT-15
	grep -q "HISI 65xx PowerOn Key" /proc/bus/input/devices && pass pmic.powerkey "power key input device" || fail pmic.powerkey "no power key input device"
	PLAN=SOC-08
	x=$(rd /sys/kernel/debug/clk/clk_pmu32kb/clk_enable_count)
	[ "${x:-0}" -ge 1 ] && pass pmic.clk32k "clk_pmu32kb (Hi1103) enabled x$x" || fail pmic.clk32k "clk_pmu32kb enable_count ${x:-?}"
}

# ---------------------------------------------------------------- thermal
m_thermal() {
	local t z v bad="" x c
	PLAN=THM-01
	for t in cluster0 cluster1 cluster2 gpu modem npu peri hisec echub-battery; do
		z=$(zone_by_type $t) || { bad="$bad $t(missing)"; continue; }
		v=$(rd $z/temp); { [ -n "$v" ] && [ "$v" -ge 10000 ] && [ "$v" -le 85000 ]; } || bad="$bad $t=$v"
	done
	[ -z "$bad" ] && pass thm.zones "9 zones, all 10-85 C" || fail thm.zones "$bad"
	bad=""
	for t in cluster0 cluster1 cluster2 gpu; do
		z=$(zone_by_type $t) || continue
		x=""; for c in $z/trip_point_*_type; do x="$x $(rd $c):$(rd ${c%_type}_temp)"; done
		[[ $x == *"passive:90000"* && $x == *"critical:105000"* ]] || bad="$bad $t:$x"
		[ "$(rd $z/policy)" = power_allocator ] || bad="$bad $t:policy=$(rd $z/policy)"
		ls -d $z/cdev[0-9]* > /dev/null 2>&1 || bad="$bad $t:no-cdev"
	done
	PLAN=THM-02
	[ -z "$bad" ] && pass thm.trips "cluster0-2, gpu: passive 90 C, critical 105 C, power_allocator, cooling bound" || fail thm.trips "$bad"
	x=""; bad=""
	for c in /sys/class/thermal/cooling_device*; do
		x="$x $(rd $c/type)"; [ "$(rd $c/cur_state)" = 0 ] || bad="$bad $(rd $c/type)=$(rd $c/cur_state)"
	done
	[[ $x == *cpufreq-cpu0* && $x == *cpufreq-cpu4* && $x == *cpufreq-cpu6* && $x == *devfreq-fe140000.mali* ]] &&
		pass thm.cooling "cooling devices:$x" || fail thm.cooling "cooling devices:$x (want cpufreq-cpu0/4/6 + devfreq mali)"
	[ -z "$bad" ] && pass thm.not-throttling "no cooling device active at the moment" || warn thm.not-throttling "throttling now:$bad"

	# emulate 95 C on the big-core zone (between the 90 C control and the 105 C critical trip)
	z=$(zone_by_type cluster2)
	if slow && [ -w "$z/emul_temp" ]; then
		local p=/sys/devices/system/cpu/cpufreq/policy6 cd="" i hit="" back=""
		for c in /sys/class/thermal/cooling_device*; do [ "$(rd $c/type)" = cpufreq-cpu6 ] && cd=$c; done
		[ -n "$cd" ] || { fail thm.emul-throttle "no cpufreq-cpu6 cooling device"; return; }
		guard_arm emul 30 "echo 0 > $z/emul_temp"
		on_restore "echo 0 > $z/emul_temp"
		has stress-ng && { stress-ng --cpu 2 --taskset 6,7 --timeout 4 --quiet > /dev/null 2>&1 & }
		echo 95000 > $z/emul_temp
		for i in $(seq 1 20); do
			sleep 0.15
			if [ "$(rd $cd/cur_state)" != 0 ] || [ "$(rd $p/scaling_max_freq)" != "$(rd $p/cpuinfo_max_freq)" ]; then hit="state $(rd $cd/cur_state), max $(($(rd $p/scaling_max_freq) / 1000)) MHz after $(awk -v i=$i 'BEGIN { print i * 0.15 }') s"; break; fi
		done
		echo 0 > $z/emul_temp
		for i in $(seq 1 25); do
			sleep 0.2
			[ "$(rd $cd/cur_state)" = 0 ] && [ "$(rd $p/scaling_max_freq)" = "$(rd $p/cpuinfo_max_freq)" ] && { back=yes; break; }
		done
		wait 2> /dev/null
		guard_disarm emul
		[ -n "$hit" ] && pass thm.emul-throttle "cluster2 at emulated 95 C: $hit" || fail thm.emul-throttle "cluster2 at emulated 95 C: no throttling in 3 s"
		[ -n "$back" ] && pass thm.emul-recover "throttling released after emulation ended" || fail thm.emul-recover "still throttled 5 s after emulation ended (state $(rd $cd/cur_state))"
	fi
}

# ---------------------------------------------------------------- ufs
m_ufs() {
	local U=/sys/bus/platform/devices/f8200000.ufs DBG=/sys/kernel/debug/ufshcd/f8200000.ufs x lun d blk bad="" T=/var/tmp/l410-quick
	PLAN=UFS-01
	[ "$(drv_of $U)" = ufshcd-kirin ] && pass ufs.driver "ufshcd-kirin" || fail ufs.driver "driver '$(drv_of $U)'"
	x="$(rd $U/power_info/gear) x$(rd $U/power_info/lane) $(rd $U/power_info/mode) $(rd $U/power_info/rate)"
	[ "$x" = "HS_GEAR4 x2 FAST_MODE HS_RATE_B" ] && pass ufs.link "$x" || fail ufs.link "$x (want HS_GEAR4 x2 FAST_MODE HS_RATE_B)"
	declare -A want=([0]=8192 [1]=131072 [2]=2621440 [3]=997433344)
	for lun in 0 1 2 3; do
		d=/sys/bus/scsi/devices/0:0:0:$lun; blk=$(ls $d/block 2> /dev/null)
		[ -n "$blk" ] && [ "$(rd /sys/block/$blk/size)" = "${want[$lun]}" ] && [ "$(rd $d/model | tr -d ' ')" = SDINFDO4-512G ] || bad="$bad LUN$lun=${blk:-none}/$(rd /sys/block/$blk/size)"
	done
	[ -z "$bad" ] && pass ufs.luns "4 LUNs sda-sdd, WDC SDINFDO4-512G, sizes as on the vendor kernel" || fail ufs.luns "$bad"
	PLAN=UFS-02
	bad=""
	for blk in sda sdb sdc; do
		klog | grep -q "\[$blk\] Write Protect is on" || bad="$bad $blk:device-wp-off"
		for x in /sys/block/$blk/ro /sys/block/$blk/$blk*/ro; do [ -e "$x" ] && [ "$(rd $x)" != 1 ] && bad="$bad ${x#/sys/block/}"; done
	done
	[ -z "$bad" ] && pass ufs.fw-lun-protect "sda/sdb/sdc: device power-on write protect + read-only in the kernel (all partitions)" || fail ufs.fw-lun-protect "$bad"
	PLAN=UFS-12
	x=$(awk '$1 ~ /^\/dev\/sd[abc]|^\/dev\/sdd[1-6]$/ && $4 ~ /(^|,)rw(,|$)/ { print $1 " on " $2 }' /proc/mounts)
	[ -z "$x" ] && pass ufs.other-os-parts "no firmware LUN or Kylin partition mounted read-write" || fail ufs.other-os-parts "mounted rw: $x"
	PLAN=UFS-06
	x=$(rd $U/auto_hibern8)
	[ "${x:-0}" -gt 0 ] && pass ufs.ah8 "auto-hibern8 ${x} us, rpm_lvl $(rd $U/rpm_lvl), spm_lvl $(rd $U/spm_lvl)" || fail ufs.ah8 "auto-hibern8 '$x'"
	[ "$(rd $U/rpm_lvl)" = 1 ] && [ "$(rd $U/spm_lvl)" = 3 ] || warn ufs.pm-levels "rpm_lvl $(rd $U/rpm_lvl) spm_lvl $(rd $U/spm_lvl) (defaults 1/3; 5 has the known AH8 exit failure)"
	PLAN=UFS-05
	errs() { awk -F': ' '!/Resets/ { s += $2 } END { print s + 0 }' $DBG/stats 2> /dev/null; }
	x=$(errs)
	[ "$x" = 0 ] && pass ufs.error-counters "all UFS error event counters 0" || fail ufs.error-counters "$x error events: $(grep -v ': 0$' $DBG/stats | grep -v Resets | tr '\n' ';')"
	PLAN=UFS-10
	local e a b; e=$(rd $U/health_descriptor/eol_info); a=$(rd $U/health_descriptor/life_time_estimation_a); b=$(rd $U/health_descriptor/life_time_estimation_b)
	if [ -z "$e" ]; then fail ufs.health "no health descriptor"
	elif [ $((e)) -le 1 ] && [ $((a)) -le 5 ] && [ $((b)) -le 5 ]; then pass ufs.health "pre-EOL $e (normal), life used A $a B $b (0x01 = 0-10%)"
	elif [ $((e)) -ge 3 ] || [ $((a)) -ge 10 ] || [ $((b)) -ge 10 ]; then fail ufs.health "pre-EOL $e, life A $a B $b: device worn out"
	else warn ufs.health "pre-EOL $e, life A $a B $b"; fi
	info ufs.writebooster "wb_on=$(rd $U/wb_on)"

	if slow; then
		PLAN=UFS-04
		mkdir -p $T && on_restore "rm -rf $T"
		local e0 rc
		e0=$(errs)
		if has fio; then
			fio --name=quick --filename=$T/fio.bin --size=128M --rw=randwrite --bsrange=4k-256k --direct=1 --ioengine=libaio \
				--iodepth=16 --verify=crc32c --verify_fatal=1 --do_verify=1 --output-format=json --output=$T/fio.json > /dev/null 2>&1
			rc=$?
			x=$(jq -r '.jobs[0] | "write \(.write.bw / 1024 | floor) MiB/s, verify read \(.read.bw / 1024 | floor) MiB/s"' $T/fio.json 2> /dev/null)
			[ $rc = 0 ] && pass ufs.io-verify "128 MiB random 4k-256k O_DIRECT write + crc32c verify: ${x:-ok}" || fail ufs.io-verify "fio rc $rc: $x"
			x=$(dd if=$T/fio.bin of=/dev/null bs=4M iflag=direct 2>&1 | tail -1)
			local mb; mb=$(echo "$x" | grep -oE '[0-9.]+ [GM]B/s' | awk '{ print ($2 == "GB/s") ? $1 * 1000 : $1 }')
			PLAN=UFS-03
			in_range "${mb:-0}" 500 100000 && pass ufs.read-rate "O_DIRECT sequential read ${mb} MB/s" || warn ufs.read-rate "O_DIRECT sequential read ${mb:-?} MB/s (< 500)"
		fi
		# auto-hibern8 exits: short direct reads separated by idle gaps longer than the timer
		PLAN=UFS-05
		local us gap i f=0 h0 h1
		us=$(rd $U/auto_hibern8)
		if [ "${us:-0}" -gt 0 ]; then
			gap=$(awk -v u=$us 'BEGIN { printf "%.3f", u / 1e6 + 0.03 }')
			h0=$(awk -F': ' '/Auto-hibernate/ { print $2 + 0 }' $DBG/stats)
			for i in $(seq 1 25); do dd if="$(findmnt -n -o SOURCE /)" of=/dev/null bs=4k count=1 skip=$((RANDOM * 64 + i)) iflag=direct 2> /dev/null || f=$((f + 1)); sleep $gap; done
			h1=$(awk -F': ' '/Auto-hibernate/ { print $2 + 0 }' $DBG/stats)
			[ $f = 0 ] && [ "$h1" = "$h0" ] && pass ufs.ah8-exits "25 reads after ${gap}s idle each: no errors" || fail ufs.ah8-exits "$f failed reads, AH8 errors $h0 -> $h1"
		fi
		[ "$(errs)" = "$e0" ] && pass ufs.no-new-errors "no UFS error events during the I/O checks" || fail ufs.no-new-errors "UFS error events $e0 -> $(errs)"
		rm -rf $T
	fi
}

# ---------------------------------------------------------------- usb
m_usb() {
	local x d v bad="" dev want sp path drv
	PLAN=USB-01
	for x in "kirin990-usb-phy f8480000.usb_phy" "dwc3-kirin990 hisi_usb@f8480000" "dwc3 f8400000.dwc3" "xhci-hcd xhci-hcd" "onboard-usb-dev f8400000.dwc3:hub@1"; do
		ls /sys/bus/platform/drivers/${x% *} 2> /dev/null | grep -q "${x#* }" || bad="$bad ${x% *}"
	done
	[ -z "$bad" ] && pass usb.drivers "PHY, glue, dwc3, xhci, onboard hub bound" || fail usb.drivers "not bound:$bad"
	x=$(klog | grep -o "kirin990-usb-phy.*up: .*" | head -1)
	[[ $x == *"fw loaded, mux 3"* ]] && pass usb.phy "combo PHY ${x#*up: }" || fail usb.phy "${x:-no PHY bring-up message}"
	bad=""
	while read -r dev path sp; do
		d=$(usbdev $dev) || { bad="$bad $dev(missing)"; continue; }
		[ "${d##*/}" = "$path" ] && [ "$(rd $d/speed)" = "$sp" ] || bad="$bad $dev@${d##*/}:$(rd $d/speed)M"
	done << 'EOF'
1d6b:0002 usb1 480
1d6b:0003 usb2 10000
0bda:5411 1-1 480
0bda:0411 2-1 5000
3196:0203 1-1.4 480
EOF
	[ -z "$bad" ] && pass usb.topology "root hubs 480M/10G, RTS5411 hub 480M+5G at 1-1/2-1, camera at 1-1.4" || fail usb.topology "$bad"
	x=""; for d in /sys/bus/usb/devices/*; do
		[ -f $d/idVendor ] || continue
		case "$(rd $d/idVendor):$(rd $d/idProduct)" in 1d6b:*|0bda:5411|0bda:0411|3196:0203) ;; *) x="$x ${d##*/}:$(rd $d/idVendor):$(rd $d/idProduct)@$(rd $d/speed)M($(rd $d/product))" ;; esac
	done
	info usb.external "${x:- none}"
	if d=$(usbdev 0bda:8153); then
		[ "$(rd $d/speed)" = 5000 ] && [ "$(drv_of $d:1.0)" = r8152 ] && pass usb.rtl8153 "RTL8153 at ${d##*/} 5000M, r8152" || fail usb.rtl8153 "RTL8153 $(rd $d/speed)M driver $(drv_of $d:1.0)"
	fi
	PLAN=CAM-01
	if d=$(usbdev 3196:0203); then
		v=""; for x in /sys/class/video4linux/video*; do [[ $(readlink -f $x/device) == $(readlink -f $d)/* ]] && { v=/dev/${x##*/}; break; }; done
		drv=""; for x in $d:1.*; do [ "$(drv_of $x)" = uvcvideo ] && drv=uvcvideo; done
		[ -n "$v" ] && [ -n "$drv" ] && pass usb.camera "HD Camera, uvcvideo, $v" || fail usb.camera "uvcvideo '${drv}', node '${v}'"
		if slow && [ -n "$v" ] && has v4l2-ctl; then
			if [ -n "$(holders $v)" ]; then skip usb.camera-grab "$v in use by pid $(holders $v)"
			else
				rm -f "$OUT/cam.raw"
				timeout 10 v4l2-ctl -d $v --stream-mmap --stream-count=5 --stream-to="$OUT/cam.raw" > /dev/null 2>&1
				[ -s "$OUT/cam.raw" ] && pass usb.camera-grab "5 frames, $(stat -c %s "$OUT/cam.raw") bytes" || fail usb.camera-grab "no frames from $v"
				rm -f "$OUT/cam.raw"
				# re-plug through the hub: disable/enable the camera's downstream port
				local port=/sys/bus/usb/devices/1-1:1.0/1-1-port4/disable gone=0 back=0 i
				if [ -w $port ]; then
					on_restore "echo 0 > $port"
					echo 1 > $port; sleep 1.5; usbdev 3196:0203 > /dev/null || gone=1
					echo 0 > $port
					for i in $(seq 1 30); do x=$(usbdev 3196:0203) && [ "$(drv_of $x:1.0)" = uvcvideo ] && { back=1; break; }; sleep 0.3; done
					[ $gone = 1 ] && [ $back = 1 ] && pass usb.camera-replug "hub port 4 off/on: gone, back, uvcvideo re-bound" || fail usb.camera-replug "gone=$gone back=$back"
				fi
			fi
		fi
	else
		fail usb.camera "3196:0203 not enumerated"
	fi
	PLAN=USB-04
	x=$(klog | grep -cE "usb [0-9.-]+: reset (high|super|full|low)")
	[ "$x" -le 2 ] && pass usb.resets "$x USB bus resets since boot" || warn usb.resets "$x USB bus resets since boot"
}

# ---------------------------------------------------------------- pcie / ethernet
m_pcie() {
	local d x ifc rp
	PLAN=ETH-01
	for x in f0000000 f4000000; do
		[ "$(drv_of /sys/bus/platform/devices/$x.pcie_kport_rc)" = pcie-kport ] && pass pcie.rc-$x "bound to pcie-kport" || fail pcie.rc-$x "driver '$(drv_of /sys/bus/platform/devices/$x.pcie_kport_rc)'"
	done
	d=/sys/bus/pci/devices/0000:01:00.0
	if [ -d $d ]; then
		x="$(rd $d/vendor):$(rd $d/device) $(drv_of $d) $(rd $d/current_link_speed) x$(rd $d/current_link_width)"
		[ "$x" = "0x10ec:0x8168 r8169 2.5 GT/s PCIe x1" ] && pass pcie.rc0-nic "RTL8168 $x" || fail pcie.rc0-nic "$x (want 0x10ec:0x8168 r8169 2.5 GT/s PCIe x1)"
		ifc=$(ls $d/net 2> /dev/null | head -1)
		if [ -n "$ifc" ]; then
			x=$(ethtool -P $ifc 2> /dev/null | awk '{ print $NF }')
			[ "$x" = "$(rd /sys/class/net/$ifc/address)" ] && [[ $x == 24:81:c7:* ]] && pass pcie.rc0-mac "$ifc $x (eFuse, Huawei OUI)" || fail pcie.rc0-mac "$ifc address $(rd /sys/class/net/$ifc/address), permanent '$x'"
			PLAN=ETH-02
			if [ "$(rd /sys/class/net/$ifc/carrier)" = 1 ]; then
				x="$(rd /sys/class/net/$ifc/speed) Mb/s $(rd /sys/class/net/$ifc/duplex)"
				[ "$(rd /sys/class/net/$ifc/speed)" = 1000 ] && pass pcie.eth-link "$ifc $x" || warn pcie.eth-link "$ifc $x (want 1000 full)"
				local gw i0 i1
				irqsum() { grep -E "$ifc|0000:01:00.0" /proc/interrupts | awk '{ for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i } END { print s + 0 }'; }
				gw=$(ip route show default dev $ifc 2> /dev/null | awk '{ print $3; exit }')
				if [ -n "$gw" ]; then
					i0=$(irqsum); x=$(ping -q -c 20 -i 0.05 -W 1 -I $ifc $gw 2>&1 | grep -oE '[0-9.]+% packet loss'); i1=$(irqsum)
					[ "$x" = "0% packet loss" ] && [ "$i1" -gt "$i0" ] && pass pcie.eth-ping "20 pings to $gw, 0 loss, MSI-X interrupts $i0 -> $i1" || fail pcie.eth-ping "$x, interrupts $i0 -> $i1"
				else
					skip pcie.eth-ping "no gateway on $ifc"
				fi
			else
				skip pcie.eth-link "no cable on $ifc"
				PLAN=PM-09
				[ "$(rd $d/power_state)" = D3hot ] && pass pcie.rc0-d3 "RTL8168 in D3hot without a cable" || warn pcie.rc0-d3 "RTL8168 power state $(rd $d/power_state) without a cable"
			fi
			PLAN=REL-07
			if slow && ! iface_in_use $ifc; then
				local up; up=$(ip -br link show $ifc | awk '{ print $2 }')
				echo 0000:01:00.0 > /sys/bus/pci/drivers/r8169/unbind; sleep 0.5
				echo 0000:01:00.0 > /sys/bus/pci/drivers/r8169/bind; sleep 1.5
				x=$(ls $d/net 2> /dev/null | head -1)
				[ -n "$x" ] && [ "$(ethtool -P $x 2> /dev/null | awk '{ print $NF }')" = "$(rd /sys/class/net/$x/address)" ] && pass pcie.rc0-rebind "r8169 unbind/bind: $x back, MAC intact" || fail pcie.rc0-rebind "r8169 rebind: netdev '$x'"
				[ "$up" = DOWN ] && ip link set ${x:-$ifc} down 2> /dev/null
			elif slow; then
				skip pcie.rc0-rebind "$ifc carries the default route or this ssh session"
			fi
		else
			fail pcie.rc0-mac "no netdev on 0000:01:00.0"
		fi
	else
		fail pcie.rc0-nic "0000:01:00.0 not enumerated"
	fi
	PLAN=WLAN-10
	d=/sys/bus/pci/devices/0001:01:00.0
	if [ -d $d ]; then
		x="$(rd $d/vendor):$(rd $d/device) $(drv_of $d) $(rd $d/current_link_speed) x$(rd $d/current_link_width)"
		[ "$x" = "0x19e5:0x1103 hi110x_pci 5.0 GT/s PCIe x1" ] && pass pcie.rc1-wifi "Hi1103 $x" || fail pcie.rc1-wifi "$x (want 0x19e5:0x1103 hi110x_pci 5.0 GT/s PCIe x1)"
	else
		fail pcie.rc1-wifi "0001:01:00.0 not enumerated (chip powered down or link lost)"
	fi
}

# ---------------------------------------------------------------- wifi
m_wifi() {
	local P=/sys/module/hi110x/parameters x l sig gw
	PLAN=WLAN-01
	[ -d /sys/module/hi110x ] && pass wifi.module "hi110x loaded, verbose=$(rd $P/verbose) ssi_dump=$(rd $P/ssi_dump)" || { fail wifi.module "hi110x not loaded"; return; }
	[ "$(rd $P/verbose)" = 0 ] && [ "$(rd $P/ssi_dump)" = 0 ] || warn wifi.debug-params "verbose=$(rd $P/verbose) ssi_dump=$(rd $P/ssi_dump) (0 in normal use)"
	[ -e /sys/class/net/wlan0 ] || { fail wifi.netdev "no wlan0"; return; }
	x=$(ethtool -P wlan0 2> /dev/null | awk '{ print $NF }')
	PLAN=WLAN-13
	[[ $x == 24:81:c7:* ]] && pass wifi.netdev "wlan0, permanent MAC $x (EEPROM), current $(rd /sys/class/net/wlan0/address)" || fail wifi.netdev "wlan0 permanent MAC '$x'"
	x=$(rfkill -n -o TYPE,SOFT,HARD 2> /dev/null | awk '$1 == "wlan"')
	[[ $x == *unblocked*unblocked* ]] && pass wifi.rfkill "wlan not blocked" || fail wifi.rfkill "rfkill: $x"
	PLAN=WLAN-11
	x=$(iw reg get 2> /dev/null | awk '/^global/ { g = 1 } g && /^country/ { print $2; exit }' | tr -d :)
	[ "$x" = "${L410Q_COUNTRY:-CN}" ] && pass wifi.country "regulatory domain $x" || fail wifi.country "regulatory domain '$x', want ${L410Q_COUNTRY:-CN} (channels/power follow the world domain)"
	PLAN=WLAN-05
	l=$(timeout 5 iw dev wlan0 link 2> /dev/null)
	if [[ $l != Connected* ]]; then
		warn wifi.link "wlan0 not connected (nothing to check unattended)"
	else
		sig=$(echo "$l" | awk '/signal:/ { print $2 }')
		x="$(echo "$l" | awk -F': ' '/SSID/ { s = $2 } /freq/ { f = $2 } /tx bitrate/ { t = $2 } END { printf "%s %s MHz, tx %s", s, f, t }'), signal $sig dBm"
		[ "${sig:--100}" -ge -70 ] && pass wifi.link "$x" || warn wifi.link "$x (weak)"
		x=$(timeout 5 iw dev wlan0 station dump 2>&1); local rc=$?
		[ $rc = 0 ] && [ "$(echo "$x" | grep -c '^Station')" = 1 ] && pass wifi.station-dump "station dump ends, 1 entry (the AP)" || fail wifi.station-dump "rc $rc, $(echo "$x" | grep -c '^Station') entries (dump_station loop?)"
		info wifi.tx-stats "$(echo "$x" | awk -F':\t*' '/tx packets|tx retries|tx failed|rx drop misc/ { gsub(/^[ \t]+/, "", $1); printf "%s %s, ", $1, $2 }')"
		PLAN=WLAN-02
		x=$(timeout 5 nmcli -t -f STATE,CONNECTIVITY general 2> /dev/null)
		[[ $x == connected:full || $x == connected:limited ]] && pass wifi.nm "NetworkManager: $x" || fail wifi.nm "NetworkManager: '${x:-no answer}'"
		PLAN=PM-10
		local mode ps; mode=$(sed 's/.*\[\(.*\)\].*/\1/' /sys/kernel/l410_perf/mode 2> /dev/null); ps=$(iw dev wlan0 get power_save 2> /dev/null | awk '{ print $NF }')
		if [ "$mode" = performance ]; then [ "$ps" = off ]; else [ "$ps" = on ]; fi && pass wifi.power-save "power save $ps in $mode mode" || warn wifi.power-save "power save $ps in $mode mode (profile says on for powersave/balanced, off for performance)"
		PLAN=WLAN-04
		gw=$(ip route show default dev wlan0 | awk '{ print $3; exit }')
		if slow && [ -n "$gw" ]; then
			x=$(ping -q -c 20 -i 0.2 -W 1 $gw 2>&1)
			local loss avg max; loss=$(echo "$x" | grep -oE '[0-9.]+% packet loss' | cut -d% -f1)
			avg=$(echo "$x" | awk -F/ '/^rtt/ { print $5 }'); max=$(echo "$x" | awk -F/ '/^rtt/ { print $6 }')
			if [ "$loss" = 0 ] && in_range "${avg:-999}" 0 30; then pass wifi.ping "20 pings to $gw: 0 loss, avg $avg ms, max $max ms"
			elif [ "$loss" = 0 ]; then warn wifi.ping "20 pings to $gw: 0 loss, avg $avg ms (> 30), max $max ms"
			else fail wifi.ping "20 pings to $gw: ${loss:-?}% loss"; fi
			getent ahosts www.baidu.com > /dev/null 2>&1 && pass wifi.dns "name resolution works" || warn wifi.dns "cannot resolve www.baidu.com (no internet?)"
			if [ -n "$L410Q_IPERF" ] && has iperf3; then
				x=$(timeout 15 iperf3 -c "$L410Q_IPERF" -t 5 -J 2> /dev/null | jq -r '.end.sum_received.bits_per_second / 1e6 | floor' 2> /dev/null)
				[ "${x:-0}" -ge 100 ] && pass wifi.throughput "iperf3 to $L410Q_IPERF: $x Mbit/s" || warn wifi.throughput "iperf3 to $L410Q_IPERF: ${x:-?} Mbit/s"
			fi
		fi
	fi
	PLAN=WLAN-10
	local pat='SSI_ERR|hcc.*excp|DFR.*(fail|recovery)|BFG_WAKE_UP_FAIL|BFGX_OPEN_FAIL|PCI_COMMAND:0xffff|(hi110x|HI11XX|pcie-kport f4000000).*0xffffffff'
	x=$(klog | grep -cE "$pat")
	[ "$x" = 0 ] && pass wifi.chip-errors "no chip exception/DFR/wake failure since boot" || fail wifi.chip-errors "$x chip error lines: $(klog | grep -E "$pat" | tail -1 | cut -c1-140)"
}

# ---------------------------------------------------------------- bluetooth
m_bt() {
	local x n
	PLAN=BT-01
	[ -d /sys/class/bluetooth/hci0 ] || { fail bt.hci0 "no hci0"; return; }
	x=$(timeout 5 hciconfig hci0 2> /dev/null)
	[[ $x == *"Bus: UART"* && $x == *"BD Address: 24:81:C7"* ]] && pass bt.hci0 "hci0 on UART, BD address $(echo "$x" | awk '/BD Address/ { print $3 }') (EEPROM)" || fail bt.hci0 "$(echo "$x" | head -2 | tr '\n' ' ')"
	[ "$(echo "$x" | grep -oE 'errors:[0-9]+' | sort -u)" = "errors:0" ] && pass bt.hci-errors "RX/TX errors 0" || fail bt.hci-errors "$(echo "$x" | grep -oE '(RX|TX) bytes.*errors:[0-9]+' | tr '\n' ';')"
	[ "$(systemctl is-active bluetooth 2> /dev/null)" = active ] && pass bt.service "bluetoothd active" || fail bt.service "bluetoothd $(systemctl is-active bluetooth)"
	x=$(timeout 5 bluetoothctl show 2> /dev/null)
	[[ $x == *"Powered: yes"* ]] && pass bt.powered "controller powered" || fail bt.powered "controller not powered: $(echo "$x" | grep -E 'Powered|PowerState' | tr '\n' ' ')"
	# one HCI command/event round trip over BUART (Read Local Version Information)
	x=$(timeout 8 hciconfig hci0 version 2>&1)
	[[ $x == *"HCI Version"* ]] && pass bt.hci-roundtrip "HCI command answered: $(echo "$x" | grep -o 'HCI Version: [^ ]* [^ ]*')" || fail bt.hci-roundtrip "controller did not answer: $(echo "$x" | tail -1)"
	PLAN=BT-06
	n=$(journalctl -k --since "-300s" -o cat --no-pager 2> /dev/null | grep -ciE "heart ?beat.*time ?out|beat.*timeout")
	[ "$n" = 0 ] && pass bt.heartbeat "no bfgx heartbeat timeouts in the last 5 min" || fail bt.heartbeat "$n bfgx heartbeat timeouts in the last 5 min"
	n=$(klog | grep -c "hci0: command .* tx timeout")
	[ "$n" = 0 ] && pass bt.cmd-timeouts "no HCI command timeouts since boot" || warn bt.cmd-timeouts "$n HCI command timeouts since boot"
	PLAN=BT-01
	if slow && [[ $(timeout 5 bluetoothctl show 2> /dev/null) == *"Powered: yes"* ]]; then
		x=$(timeout 15 bluetoothctl --timeout 6 scan on 2> /dev/null)
		n=$(echo "$x" | grep -c "NEW.*Device")
		[ "$n" -gt 0 ] && pass bt.scan "6 s scan: $n devices" || warn bt.scan "6 s scan found nothing (no devices around?)"
	fi
}

# ---------------------------------------------------------------- display
m_display() {
	local c card="" con x bl=/sys/class/backlight/backlight dri=""
	PLAN=DSP-01
	for c in /sys/class/drm/card[0-9]*; do [[ ${c##*/} == *-* ]] && continue; [ "$(drv_of $c/device)" = kirin990-dss ] && card=${c##*/}; done
	[ -n "$card" ] || { fail dsp.kms "no DRM card on kirin990-dss"; return; }
	con=/sys/class/drm/$card-eDP-1
	x="$(rd $con/status) $(rd $con/enabled) $(rd $con/dpms) $(rd $con/modes | tr '\n' ' ')"
	[ "$x" = "connected enabled On 2160x1440 " ] && pass dsp.kms "$card eDP-1 connected, enabled, DPMS On, 2160x1440" || fail dsp.kms "$card eDP-1: $x"
	x=$(klog | grep -oE "measured frame period [0-9]+ ns \([0-9.]+ Hz\)" | tail -1)
	in_range "$(echo "$x" | grep -oE '[0-9.]+ Hz' | cut -d' ' -f1)" 60.3 60.7 && pass dsp.refresh "$x" || fail dsp.refresh "${x:-no measured frame period}"
	for c in /sys/kernel/debug/dri/*/name; do grep -q '^kirin' $c && dri=${c%/name}; done
	x=$(rd $dri/kirin_frames)
	[[ $x == *"underflows 0"* ]] && pass dsp.underflows "no LDI underflow ($(echo "$x" | head -1))" || fail dsp.underflows "$(echo "$x" | grep underflows)"
	info dsp.frames "$(echo "$x" | tr '\n' ';' | cut -c1-200)"
	PLAN=PERF-08
	x=$(ps -eo comm,cls,rtprio | awk '$1 == "kirin-commit" { print $2, $3 }')
	[ "$x" = "FF 50" ] && pass dsp.commit-thread "kirin-commit SCHED_FIFO 50" || fail dsp.commit-thread "kirin-commit: '${x:-missing}'"
	PLAN=DSP-01
	if slow && [ "$(rd $con/dpms)" = On ] && has python3; then
		x=$(timeout 5 python3 - /dev/dri/$card << 'PY' 2>&1
import fcntl, os, struct, sys
fd = os.open(sys.argv[1], os.O_RDWR)
def wait(n):   # DRM_IOCTL_WAIT_VBLANK, _DRM_VBLANK_RELATIVE: no DRM master needed
    r = fcntl.ioctl(fd, 0xc018643a, struct.pack("IIQ", 1, n, 0) + bytes(8))
    _, seq, s, us = struct.unpack("IIqq", r)
    return seq, s + us / 1e6
s0, t0 = wait(1)
s1, t1 = wait(60)
print("%.3f" % ((s1 - s0) / (t1 - t0)))
PY
)
		in_range "$x" 60.2 60.8 && pass dsp.vblank-rate "60 vblanks at $x Hz" || fail dsp.vblank-rate "vblank rate '$x' (want 60.51)"
	fi
	PLAN=DSP-08
	x=$(timeout 5 modetest -M kirin -c 2> /dev/null | awk '$4 == "eDP-1" { print $5 }')
	[ -n "$x" ] && [ "$x" != 0x0 ] && pass dsp.edid-size "eDP-1 ${x} mm" || fail dsp.edid-size "eDP-1 size '${x:-?}' mm"
	x=$(timeout 5 modetest -M kirin -p 2> /dev/null | awk '/^Planes:/ { p = 1; next } p && /^[0-9]+\t/ { n++ } END { print n + 0 }')
	info dsp.planes "$x planes (primary + cursor expected)"
	PLAN=DSP-02
	if [ -d $bl ]; then
		local b m; b=$(rd $bl/brightness); m=$(rd $bl/max_brightness)
		[ "$m" = 100 ] && [ "$b" -gt 0 ] && [ "$(rd $bl/bl_power)" = 0 ] && pass dsp.backlight "brightness $b/$m, bl_power 0" || fail dsp.backlight "brightness $b/$m, bl_power $(rd $bl/bl_power) (0 = black screen)"
		local t=$((b > 1 ? b - 1 : b + 1))
		on_restore "echo $b > $bl/brightness"
		echo $t > $bl/brightness; x=$(rd $bl/actual_brightness); echo $b > $bl/brightness
		[ "$x" = $t ] && [ "$(rd $bl/actual_brightness)" = $b ] && pass dsp.backlight-set "set $t, read back, restored $b" || fail dsp.backlight-set "set $t read $x"
		x=$(grep -A3 'panel_blpwm' /sys/kernel/debug/pwm 2> /dev/null | grep -oE 'actual configuration: +enabled, [0-9]+/[0-9]+' | grep -oE '[0-9]+/[0-9]+')
		in_range "${x#*/}" 492000 503000 && pass dsp.pwm "blpwm $x ns (2.0 kHz, vendor period)" || fail dsp.pwm "blpwm duty/period '${x:-?}' ns (want period 497778)"
	else
		fail dsp.backlight "no backlight device"
	fi
}

# ---------------------------------------------------------------- gpu
m_gpu() {
	local G=/sys/class/devfreq/fe140000.mali x f0 f1 lo hi cur clk
	PLAN=GPU-01
	[ "$(drv_of /sys/bus/platform/devices/fe140000.mali)" = panfrost ] && [ -e /dev/dri/renderD128 ] && klog | grep -q "mali-g76 id 0x7211" &&
		pass gpu.driver "panfrost, Mali-G76 id 0x7211, renderD128" || fail gpu.driver "panfrost/renderD128/GPU id missing"
	x=$(rd $G/available_frequencies | wc -w)
	# performance mode holds the GPU at its top OPP (l410-perf floor), the others let it scale from 166
	lo=166000000; [[ $(rd /sys/kernel/l410_perf/mode) == *"[performance]"* ]] && lo=600000000
	[ "$x" = 14 ] && [ "$(rd $G/min_freq)" = $lo ] && [ "$(rd $G/max_freq)" = 600000000 ] && [ "$(rd $G/governor)" = simple_ondemand ] &&
		pass gpu.devfreq "14 OPPs, $(($(rd $G/min_freq) / 1000000))-600 MHz for the mode, simple_ondemand, now $(($(rd $G/cur_freq) / 1000000)) MHz" || fail gpu.devfreq "$x OPPs $(rd $G/min_freq)-$(rd $G/max_freq) $(rd $G/governor)"
	if has eglinfo; then
		x=$(timeout 15 eglinfo -B -p surfaceless 2> /dev/null)
		# Mesa 26 names the core count: "Mali-G76 MC16 (Panfrost)"
		[[ $x =~ Mali-G76( MC[0-9]+)?\ \(Panfrost\) ]] && pass gpu.egl "$(echo "$x" | grep -m1 'OpenGL ES profile version' | sed 's/.*: //') on ${BASH_REMATCH[0]}" || fail gpu.egl "eglinfo surfaceless: $(echo "$x" | grep -m1 -i renderer)"
	fi
	PLAN=GPU-02
	if slow && [ -w $G/min_freq ]; then
		# restore by clearing the user limits (0 = none): min_freq/max_freq read back the
		# effective limits, which include l410-perf's QoS floor (600 MHz in performance mode);
		# writing those back pinned the GPU at 600 MHz in every mode afterwards
		on_restore "echo 0 > $G/min_freq; echo 0 > $G/max_freq"
		echo 600000000 > $G/min_freq; sleep 0.3; cur=$(rd $G/cur_freq); clk=$(rd /sys/kernel/debug/clk/clk_g3d/clk_rate)
		echo 166000000 > $G/min_freq; echo 166000000 > $G/max_freq; sleep 0.3; f0=$(rd $G/cur_freq); f1=$(rd /sys/kernel/debug/clk/clk_g3d/clk_rate)
		echo 0 > $G/max_freq; echo 0 > $G/min_freq
		[ "$cur" = 600000000 ] && [ "$clk" = 600000000 ] && [ "$f0" = 166000000 ] && [ "$f1" = 166000000 ] &&
			pass gpu.dvfs "600 MHz and 166 MHz requested, LPM3 granted the same (clk_g3d read-back)" || fail gpu.dvfs "600 -> devfreq $cur clk $clk; 166 -> devfreq $f0 clk $f1"
	fi
	PLAN=GPU-04
	if slow; then
		local wl g1 g2 score="" rc
		g1=$(awk 'END { print $0 }' $G/trans_stat 2> /dev/null | grep -oE '[0-9]+$')
		if wl=$(wl_session) && has glmark2-es2-wayland; then
			set -- $wl; WL_DISPLAY=$3
			x=$(as_user $1 timeout 20 glmark2-es2-wayland -b build:duration=2 -s 320x240 2>&1); rc=$?
		elif ! wl_session > /dev/null && [ -z "$(holders /dev/dri/$(ls /sys/bus/platform/devices/e8400000.dpe/drm | grep -m1 card))" ] && has glmark2-es2-drm; then
			x=$(timeout 20 glmark2-es2-drm --off-screen -b build:duration=2 2>&1); rc=$?
		else
			skip gpu.render "no Wayland session to draw in and the display is held by another client"; rc=skip
		fi
		if [ "$rc" != skip ]; then
			score=$(echo "$x" | awk '/glmark2 Score/ { print $3 }')
			[ $rc = 0 ] && [ "${score:-0}" -gt 0 ] && [[ $x == *Panfrost* || $x == *Mali* ]] && pass gpu.render "glmark2 build scene 2 s: score $score" ||
				fail gpu.render "glmark2 rc $rc score '${score}': $(echo "$x" | grep -iE 'error|fail' | head -2 | tr '\n' ' ')"
			g2=$(awk 'END { print $0 }' $G/trans_stat 2> /dev/null | grep -oE '[0-9]+$')
			info gpu.dvfs-activity "devfreq transitions $g1 -> $g2 during rendering"
		fi
	fi
	PLAN=GPU-02
	x=$(ps -eo comm,cls | awk '$1 == "panfrost-boost" { print $2 }')
	[ "$x" = FF ] && pass gpu.boost-thread "panfrost-boost SCHED_FIFO" || fail gpu.boost-thread "panfrost-boost: '${x:-missing}'"
	x=$(zone_by_type gpu) && ls $x/cdev0 > /dev/null 2>&1 && [ "$(rd $x/cdev0/type)" = devfreq-fe140000.mali ] &&
		pass gpu.cooling "GPU zone throttles devfreq-fe140000.mali" || fail gpu.cooling "GPU zone has no GPU cooling device"
}

# ---------------------------------------------------------------- audio
amps() { cat /sys/kernel/debug/hi6405-card/amps 2> /dev/null; }
amp_field() { echo "$1" | tr ' ' '\n' | awk -F= -v r="$2" '$1 == r { print $2 }'; }
amp_check() { # $1 = amps dump, $2 = want PWR_CTRL mode (0 active, 2 shutdown); prints problems
	local line dev pc v0 v1 out=""
	while read -r dev line; do
		pc=$(amp_field "$line" 02); v0=$(amp_field "$line" 1f); v1=$(amp_field "$line" 20)
		[ -n "$pc" ] || { out="$out $dev:unreadable"; continue; }
		[ $((0x$pc & 3)) = "$2" ] || out="$out $dev:PWR_CTRL=$pc"
		[ $((0x$v0 & 0x07)) = 0 ] && [ $((0x$v1 & 0x0e)) = 0 ] || out="$out $dev:live-fault(1f=$v0,20=$v1)"
	done <<< "$1"
	echo "$out"
}
m_audio() {
	local card x c bad="" D=/sys/kernel/debug u
	PLAN=AUD-01
	card=$(awk '/\[hi6405 *\]/ { print $1; exit }' /proc/asound/cards)
	[ -n "$card" ] || { fail aud.card "no hi6405 sound card"; return; }
	[ -e /dev/snd/pcmC${card}D0p ] && [ -e /dev/snd/pcmC${card}D0c ] && pass aud.card "card $card hi6405 ($(awk -v c=$card '$1 == c { getline; sub(/^ +/, ""); print }' /proc/asound/cards)), playback + capture" || fail aud.card "PCM devices missing"
	klog | grep -q "Hi6405 version 0x11, chip id 64 05 01 00" && pass aud.codec "Hi6405 version 0x11, chip id 64 05 01 00" || fail aud.codec "Hi6405 not identified"
	x=$(amixer -c $card controls 2> /dev/null)
	for c in "Speaker Playback Switch" "Headset Playback Switch" "Mic Capture Switch" "Headset Mic Capture Switch" "Speaker Switch" \
		"Left ASI1 Sel" "Right ASI1 Sel" "Left Digital Volume Control" "Right Digital Volume Control" "Headphone Jack" "Headset Mic Jack"; do
		[[ $x == *"'$c'"* ]] || bad="$bad '$c'"
	done
	[ -z "$bad" ] && pass aud.controls "11 required controls present" || fail aud.controls "missing:$bad"
	PLAN=AUD-05
	x="$(amixer -c $card cget name='Left Digital Volume Control' 2> /dev/null | awk -F= '/: values=/ { print $2 }') $(amixer -c $card cget name='Right Digital Volume Control' 2> /dev/null | awk -F= '/: values=/ { print $2 }')"
	[ "$x" = "110 110" ] && pass aud.amp-volume "TAS2562 digital volume 110/110 (0 dB) both amps" || fail aud.amp-volume "TAS2562 digital volume '$x' (0 = -110 dB = silent speakers)"
	if [ -r /var/lib/alsa/asound.state ]; then
		x=$(awk '/Digital Volume Control/ { f = 1 } f && /value/ { print $2; f = 0 }' /var/lib/alsa/asound.state | tr '\n' ' ')
		local z=0 v; for v in $x; do [ "$v" -gt 0 ] 2> /dev/null || z=1; done
		[ -n "$x" ] && [ $z = 0 ] && pass aud.state-file "asound.state keeps amp volume $x" || fail aud.state-file "asound.state stores amp volume '$x': alsa-restore will mute the speakers"
	fi
	x=$(amps)
	[ "$(echo "$x" | grep -c '^3-004')" = 2 ] || fail aud.amps "amps debugfs: '$x'"
	local playing; playing=$(grep -l RUNNING /proc/asound/card$card/pcm0p/sub0/status 2> /dev/null)
	if [ -z "$playing" ]; then
		bad=$(amp_check "$x" 2)
		[ -z "$bad" ] && pass aud.amps-idle "both TAS2562 shut down while idle, no live faults" || fail aud.amps-idle "$bad"
		PLAN=AUD-17
		[ "$(rd /sys/bus/platform/devices/fa550000.slimbusmisc/power/runtime_status)" = suspended ] && pass aud.idle-pm "SLIMbus runtime-suspended while idle" ||
			warn aud.idle-pm "SLIMbus $(rd /sys/bus/platform/devices/fa550000.slimbusmisc/power/runtime_status) while idle"
	else
		info aud.amps-idle "playback running, idle checks skipped"
	fi
	PLAN=AUD-07
	grep -q 'Name="hi6405 Headset Jack"' /proc/bus/input/devices && pass aud.jack "headset jack input device, headphone $(amixer -c $card cget iface=CARD,name='Headphone Jack' 2> /dev/null | awk -F= '/: values=/ { print $2 }')" || fail aud.jack "no headset jack input device"
	PLAN=AUD-08
	x=$(timeout 5 alsaucm -c hi6405 list _verbs 2>&1)
	[[ $x == *HiFi* ]] && pass aud.ucm "UCM2 verbs: $(echo "$x" | tr -s ' \n' ' ')" || fail aud.ucm "no UCM2 profile for hi6405: $(echo "$x" | tail -1)"
	u=$(pw_user)
	if [ -n "$u" ]; then
		# the sink's name is localised ("Built-in Audio"): identify it by its ALSA card properties
		x=$(as_user $u timeout 5 wpctl inspect @DEFAULT_AUDIO_SINK@ 2> /dev/null | grep -E 'alsa\.(card_name|long_card_name|id)|node\.description')
		[[ $x == *hi6405* || $x == *L410* ]] && pass aud.pipewire "PipeWire ($u) default sink is the hi6405 card ($(echo "$x" | grep -m1 node.description | sed 's/.*= //'))" ||
			fail aud.pipewire "PipeWire ($u) default sink: $(echo "${x:-none}" | tr -s ' \n' ' ' | cut -c1-160)"
	fi
	slow || return 0

	# ---- playback: 2 s of a -40 dBFS 1 kHz tone on the speakers
	PLAN=AUD-03
	has python3 || return 0
	python3 - "$OUT/tone.wav" "$OUT/rec.wav" << 'PY'
import math, struct, sys, wave
w = wave.open(sys.argv[1], "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
a = int(32767 * 10 ** (-40 / 20))
w.writeframes(b"".join(struct.pack("<hh", s, s) for s in (int(a * math.sin(2 * math.pi * 1000 * i / 48000)) for i in range(96000))))
w.close()
PY
	local sw_spk sw_hp sw_mic sw_hsm path
	sw_spk=$(amixer -c $card cget name='Speaker Playback Switch' | awk -F= '/: values=/ { print $2 }')
	sw_hp=$(amixer -c $card cget name='Headset Playback Switch' | awk -F= '/: values=/ { print $2 }')
	on_restore "amixer -c $card -q cset name='Speaker Playback Switch' $sw_spk; amixer -c $card -q cset name='Headset Playback Switch' $sw_hp"
	amixer -c $card -q cset name='Speaker Playback Switch' on; amixer -c $card -q cset name='Headset Playback Switch' off
	amixer -c $card -q cset name='Speaker Switch' on 2> /dev/null
	dma() { awk '/asp_dma_irq/ { s = 0; for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+$/) s += $i; print s }' /proc/interrupts; }
	local i0 i1 h1 h2 amp_run rc
	i0=$(dma)
	if [ -z "$(holders /dev/snd/pcmC${card}D0p)" ]; then
		path="aplay hw:$card,0"
		aplay -q -D hw:$card,0 --period-size=960 --buffer-size=3840 "$OUT/tone.wav" > "$OUT/aplay.log" 2>&1 &
	elif [ -n "$u" ]; then
		path="pw-play as $u"
		as_user $u pw-play "$OUT/tone.wav" > "$OUT/aplay.log" 2>&1 &
	else
		skip aud.play "PCM held by $(holders /dev/snd/pcmC${card}D0p) and no PipeWire user"; return 0
	fi
	local pp=$!
	sleep 1
	h1=$(awk '/^hw_ptr/ { print $3 }' /proc/asound/card$card/pcm0p/sub0/status 2> /dev/null); sleep 0.3
	h2=$(awk '/^hw_ptr/ { print $3 }' /proc/asound/card$card/pcm0p/sub0/status 2> /dev/null)
	amp_run=$(amps)
	wait $pp; rc=$?
	i1=$(dma)
	[ $rc = 0 ] && [ -n "$h2" ] && [ "$h2" -gt "${h1:-0}" ] && pass aud.play "$path, 2 s: hw_ptr $h1 -> $h2 in 0.3 s" || fail aud.play "$path rc $rc, hw_ptr '$h1' -> '$h2': $(tail -1 "$OUT/aplay.log")"
	[ $((i1 - i0)) -ge 60 ] && pass aud.dma "ASP DMA interrupts +$((i1 - i0)) (20 ms periods)" || fail aud.dma "ASP DMA interrupts +$((i1 - i0)) in 2 s"
	bad=$(amp_check "$amp_run" 0)
	[ -z "$bad" ] && pass aud.amps-play "both TAS2562 active, no faults, no live TDM clock error while playing" || fail aud.amps-play "while playing:$bad"
	sleep 0.6
	bad=$(amp_check "$(amps)" 2)
	[ -z "$bad" ] && pass aud.amps-stop "both amps shut down after the stream ended" || fail aud.amps-stop "after the stream:$bad"

	# ---- capture: 1 s from the internal microphones must not be silent
	PLAN=AUD-06
	sw_mic=$(amixer -c $card cget name='Mic Capture Switch' | awk -F= '/: values=/ { print $2 }')
	sw_hsm=$(amixer -c $card cget name='Headset Mic Capture Switch' | awk -F= '/: values=/ { print $2 }')
	on_restore "amixer -c $card -q cset name='Mic Capture Switch' $sw_mic; amixer -c $card -q cset name='Headset Mic Capture Switch' $sw_hsm"
	amixer -c $card -q cset name='Headset Mic Capture Switch' off; amixer -c $card -q cset name='Mic Capture Switch' on
	amixer -c $card -q cset name='Internal Mic Switch' on 2> /dev/null
	rm -f "$OUT/rec.wav"
	if [ -z "$(holders /dev/snd/pcmC${card}D0c)" ]; then
		timeout 5 arecord -q -D hw:$card,0 -f S16_LE -r 48000 -c 2 -d 1 "$OUT/rec.wav" 2> "$OUT/arecord.log"
	elif [ -n "$u" ]; then
		chmod 777 "$OUT"; as_user $u timeout -s INT 1.5 pw-record --channels 2 --rate 48000 "$OUT/rec.wav" 2> "$OUT/arecord.log"; chmod 755 "$OUT"
	fi
	x=$(python3 - "$OUT/rec.wav" << 'PY' 2>&1
import struct, sys, wave
w = wave.open(sys.argv[1]); n = w.getnframes(); d = w.readframes(n)
s = struct.unpack("<%dh" % (len(d) // 2), d)[4800:]   # skip the first 50 ms
print(max(abs(v) for v in s), len(set(s)), n)
PY
)
	set -- $x
	[ "${1:-0}" -ge 20 ] 2> /dev/null && [ "${2:-0}" -ge 20 ] && pass aud.mic "1 s DMIC capture: peak $1, $2 distinct values (not silent)" || fail aud.mic "DMIC capture: '$x' $(cat "$OUT/arecord.log" 2> /dev/null | tail -1)"
	rm -f "$OUT/tone.wav" "$OUT/rec.wav"
	PLAN=AUD-17
	sleep 2.5
	[ "$(rd /sys/bus/platform/devices/fa550000.slimbusmisc/power/runtime_status)" = suspended ] && pass aud.idle-after "SLIMbus runtime-suspended 2.5 s after the streams" ||
		warn aud.idle-after "SLIMbus $(rd /sys/bus/platform/devices/fa550000.slimbusmisc/power/runtime_status) 2.5 s after the streams"
}

# ---------------------------------------------------------------- input
key_bit() { # $1 KEY bitmap (hex words, most significant first), $2 key code
	echo "$1" | awk -v n="$2" '{ w = NF - int(n / 64); if (w < 1) { print 0; exit }
		s = $w; b = n % 64; d = int(b / 4); if (d >= length(s)) { print 0; exit }
		v = index("0123456789abcdef", substr(s, length(s) - d, 1)) - 1; print int(v / 2 ^ (b % 4)) % 2 }'
}
m_input() {
	local d x bad="" k c m found ev
	PLAN=INP-01
	for x in "0018:14F3:1400 hid-generic 0b59b50698d56868688aab18b8896682 keyboard" "0018:27C6:01E0 hid-multitouch 2492dad29546e2dd0b0a160dede71bf9 touchpad"; do
		set -- $x
		d=$(ls -d /sys/bus/hid/devices/$1.* 2> /dev/null | head -1)
		if [ -z "$d" ]; then fail inp.$4 "HID $1 missing"; continue; fi
		[ "$(drv_of $d)" = $2 ] && [ "$(md5sum < $d/report_descriptor | cut -d' ' -f1)" = $3 ] &&
			pass inp.$4 "HID $1 on $2, report descriptor identical to the vendor kernel" || fail inp.$4 "HID $1 driver $(drv_of $d), rdesc md5 $(md5sum < $d/report_descriptor | cut -c1-32)"
	done
	x=$(grep '^N: Name=' /proc/bus/input/devices)
	for c in "14F3:1400 Keyboard" "14F3:1400 Wireless Radio Control" "27C6:01E0 Touchpad" "HISI 65xx PowerOn Key" "echub_lid" "hi6405 Headset Jack"; do
		[[ $x == *"$c\""* ]] || bad="$bad '$c'"
	done
	[ -z "$bad" ] && pass inp.devices "keyboard, airplane key, touchpad, power key, lid, headset jack" || fail inp.devices "missing:$bad"
	PLAN=INP-03
	m=$(awk '/^N: Name="huawei-keyboard 14F3:1400/ { f = 1 } /^$/ { f = 0 } f && /^B: KEY=/ { sub(/^B: KEY=/, ""); print }' /proc/bus/input/devices)
	bad=""
	for k in "113 MUTE" "114 VOLUMEDOWN" "115 VOLUMEUP" "224 BRIGHTNESSDOWN" "225 BRIGHTNESSUP" "116 POWER" "142 SLEEP" "247 RFKILL" "248 MICMUTE"; do
		found=0
		while read -r c; do [ -n "$c" ] && [ "$(key_bit "$c" ${k% *})" = 1 ] && found=1; done <<< "$m"
		[ $found = 1 ] || bad="$bad ${k#* }"
	done
	[ -z "$bad" ] && pass inp.hotkeys "MUTE VOLUME+- BRIGHTNESS+- POWER SLEEP RFKILL MICMUTE mapped" || { [ "$bad" = " MICMUTE" ] && warn inp.hotkeys "no KEY_MICMUTE on the keyboard (mic-mute key unmapped?)" || fail inp.hotkeys "not mapped:$bad"; }
	PLAN=INP-08
	ev=$(awk '/^N: Name="echub_lid"/ { f = 1 } /^$/ { f = 0 } f && /^H:/ { match($0, /event[0-9]+/); print substr($0, RSTART, RLENGTH) }' /proc/bus/input/devices)
	if [ -n "$ev" ] && has evtest; then
		evtest --query /dev/input/$ev EV_SW SW_LID; c=$?
		case $c in 0) pass inp.lid "SW_LID open" ;; 10) warn inp.lid "SW_LID closed (lid shut during the test?)" ;; *) fail inp.lid "evtest query failed ($c)" ;; esac
	else
		skip inp.lid "no lid device or evtest"
	fi
	x=$(grep -E "huawei-keyboard|goodix-clickpad" /proc/interrupts | wc -l)
	[ "$x" -ge 2 ] && pass inp.irqs "keyboard and touchpad interrupts registered" || fail inp.irqs "$x keyboard/touchpad interrupt lines"
	if has libinput; then
		x=$(timeout 10 libinput list-devices 2> /dev/null | awk '/^Device:.*27C6:01E0 Touchpad/ { f = 1 } f && /^Capabilities:/ { print; exit }')
		[[ $x == *gesture* ]] && pass inp.libinput "libinput treats the touchpad as a touchpad ($x)" || fail inp.libinput "libinput touchpad capabilities: '$x'"
	fi
}

# ---------------------------------------------------------------- EC, battery
m_ec() {
	local S=/sys/kernel/debug/huawei-echub b=/sys/class/power_supply/echub-battery a=/sys/class/power_supply/echub-ac x e0 x0 e1 x1 v i
	PLAN=BAT-09
	[ "$(drv_of /sys/bus/i2c/devices/7-0038)" = huawei-echub ] && pass ec.bound "EC 7-0038 on huawei-echub" || fail ec.bound "EC driver '$(drv_of /sys/bus/i2c/devices/7-0038)'"
	x=$(rd $S/stats | tr '\n' ' ')
	[ -n "$x" ] && [ "$(awk -F': ' '/errors/ { s += $2 } END { print s + 0 }' $S/stats)" = 0 ] && pass ec.errors "since boot: $x" || fail ec.errors "${x:-no EC statistics}"
	if [ -w $S/read ]; then
		e0=$(awk '/^errors:/ { print $2 }' $S/stats); x0=$(awk '/^xfers:/ { print $2 }' $S/stats); v=""
		for i in 1 2 3 4 5; do echo "0x0280 0x90 1" > $S/read; v="$v $(rd $S/read)"; done
		e1=$(awk '/^errors:/ { print $2 }' $S/stats); x1=$(awk '/^xfers:/ { print $2 }' $S/stats)
		[ "$e1" = "$e0" ] && [ $((x1 - x0)) -ge 5 ] && pass ec.traffic "5 PEC-checked register reads, 0 errors (battery %:$v)" || fail ec.traffic "errors $e0 -> $e1, xfers $x0 -> $x1"
	fi
	PLAN=BAT-01
	[ -d $b ] || { fail bat.present "no echub-battery"; return; }
	local cap vol cur full des tmp cyc st h ac
	cap=$(rd $b/capacity); vol=$(rd $b/voltage_now); cur=$(rd $b/current_now); full=$(rd $b/charge_full); des=$(rd $b/charge_full_design)
	tmp=$(rd $b/temp); cyc=$(rd $b/cycle_count); st=$(rd $b/status); h=$(rd $b/health); ac=$(rd $a/online)
	[ "$(rd $b/present)" = 1 ] && pass bat.present "battery present, $st, $h" || fail bat.present "battery not present"
	x=""
	in_range "$cap" 1 100 || x="$x capacity=$cap"
	in_range "$vol" 6000000 8900000 || x="$x voltage=$vol"
	[ "$des" = 7230000 ] || x="$x design=$des"
	in_range "$tmp" 100 500 || x="$x temp=$tmp"
	in_range "$cyc" 1 2000 || x="$x cycles=$cyc"
	[ "$h" = Good ] || x="$x health=$h"
	[ -z "$x" ] && pass bat.values "$cap%, $((vol / 1000)) mV, $((cur / 1000)) mA, $(awk -v t=$tmp 'BEGIN { print t / 10 }') C, $cyc cycles" || fail bat.values "out of range:$x"
	PLAN=BAT-08
	x=$((full * 100 / des))
	[ $x -ge 80 ] && pass bat.health "full charge $((full / 1000)) of $((des / 1000)) mAh ($x%)" || warn bat.health "full charge $x% of design"
	PLAN=BAT-03
	case "$ac/$st" in
	1/Charging) [ "$cur" -gt 0 ] ;; 1/Full | "1/Not charging") [ "${cur#-}" -lt 300000 ] ;; 0/Discharging) [ "$cur" -lt 0 ] ;; *) false ;;
	esac && pass bat.consistent "AC $ac, $st, current $((cur / 1000)) mA" || fail bat.consistent "AC online=$ac but battery $st at $((cur / 1000)) mA"
	x=$(zone_by_type echub-battery) && [ $(($(rd $x/temp) / 100 - tmp)) -le 10 ] && [ $(($(rd $x/temp) / 100 - tmp)) -ge -10 ] &&
		pass bat.thermal-zone "battery thermal zone agrees ($(rd $x/temp) mC)" || warn bat.thermal-zone "battery thermal zone $(rd ${x:-/nonexistent}/temp) vs $tmp"
	PLAN=BAT-04
	if has upower; then
		x=$(upower -i /org/freedesktop/UPower/devices/battery_echub_battery 2> /dev/null | awk '/percentage/ { print int($2) }')
		[ -n "$x" ] && [ $((x - cap)) -le 1 ] && [ $((x - cap)) -ge -1 ] && pass bat.upower "UPower sees $x%" || fail bat.upower "UPower '$x' vs sysfs $cap%"
	fi
	PLAN=AUD-12
	local led=/sys/class/leds/platform::mute l0
	if [ -d $led ]; then
		l0=$(rd $led/brightness); e0=$(awk '/^errors:/ { print $2 }' $S/stats)
		on_restore "echo $l0 > $led/brightness"
		echo 1 > $led/brightness; echo 0 > $led/brightness; echo $l0 > $led/brightness
		e1=$(awk '/^errors:/ { print $2 }' $S/stats)
		[ "$e1" = "$e0" ] && pass ec.mute-led "mute LED on/off accepted by the EC (trigger $(grep -o '\[[^]]*\]' $led/trigger))" || fail ec.mute-led "EC errors $e0 -> $e1"
	else
		fail ec.mute-led "no platform::mute LED"
	fi
	PLAN=PM-02
	grep -E '\|sync +\) out hi' /sys/kernel/debug/gpio > /dev/null && pass ec.sync-gpio "EC state-sync GPIO driven high (running)" || fail ec.sync-gpio "$(grep sync /sys/kernel/debug/gpio)"
}

# ---------------------------------------------------------------- perf / power modes
pmin() { local p; for p in 0 4 6; do rd /sys/devices/system/cpu/cpufreq/policy$p/scaling_min_freq; done | tr '\n' ' '; }
cmin() { local p; for p in 0 4 6; do rd /sys/devices/system/cpu/cpufreq/policy$p/cpuinfo_min_freq; done | tr '\n' ' '; }
cmax() { local p; for p in 0 4 6; do rd /sys/devices/system/cpu/cpufreq/policy$p/cpuinfo_max_freq; done | tr '\n' ' '; }
m_perf() {
	local P=/sys/kernel/l410_perf G=/sys/class/devfreq/fe140000.mali R=/sys/class/devfreq/fffc0000.ddr_devfreq x mode tp
	PLAN=PM-10
	[ -d $P ] || { fail perf.l410 "no /sys/kernel/l410_perf"; return; }
	mode=$(sed 's/.*\[\(.*\)\].*/\1/' $P/mode)
	x=$(grep '^bound' $P/stats)
	[ "$x" = "bound cpufreq 1 1 1 gpu 1 ddr 1" ] && pass perf.l410 "mode $mode, all floors bound (cpufreq x3, gpu, ddr)" || fail perf.l410 "mode $mode, $x"
	tp=$(tuned-adm active 2> /dev/null | sed 's/.*: //')
	[ "$tp" = "l410-$mode" ] && [ "$(systemctl is-active tuned-ppd 2> /dev/null)" = active ] && pass perf.tuned "tuned profile $tp matches, tuned-ppd active" ||
		fail perf.tuned "tuned '$tp' vs l410_perf '$mode', tuned-ppd $(systemctl is-active tuned-ppd 2> /dev/null)"
	PLAN=PERF-08
	x="$(rd $R/governor) $(($(rd $R/cur_freq) / 1000000)) MHz ($(($(rd $R/min_freq) / 1000000))-$(($(rd $R/max_freq) / 1000000)))"
	if [ "$mode" = performance ]; then [ "$(rd $R/cur_freq)" = "$(rd $R/max_freq)" ]; else [ "$(rd $R/governor)" = powersave ]; fi &&
		pass perf.ddr "DDR devfreq $x in $mode" || fail perf.ddr "DDR devfreq $x in $mode"
	slow || return 0
	on_restore "echo $mode > $P/mode"
	echo performance > $P/mode; sleep 0.3
	[ "$(pmin)" = "$(cmax)" ] && [ "$(rd $G/cur_freq)" = "$(rd $G/max_freq)" ] && pass perf.mode-performance "performance: CPU min = max ($(cmax)), GPU $(($(rd $G/cur_freq) / 1000000)) MHz" ||
		fail perf.mode-performance "performance: CPU min $(pmin) (max $(cmax)), GPU $(rd $G/cur_freq)"
	echo balanced > $P/mode; sleep 0.3
	[ "$(pmin)" = "$(cmin)" ] && pass perf.mode-balanced "balanced idle: no CPU floor" || fail perf.mode-balanced "balanced: CPU min $(pmin)"
	echo 800 > $P/launch; sleep 0.2
	x=$(pmin); sleep 1
	[ "$x" = "$(cmax)" ] && [ "$(pmin)" = "$(cmin)" ] && pass perf.launch-boost "launch boost to max, expired after 800 ms" || fail perf.launch-boost "during: $x, after: $(pmin)"
	# input boost: a throw-away uinput gamepad button (libinput and the desktop ignore joysticks)
	x=$(python3 - << 'PY' 2>&1
import fcntl, os, struct, time
fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, 0x40045564, 1); fcntl.ioctl(fd, 0x40045565, 0x2c0)
fcntl.ioctl(fd, 0x405c5503, struct.pack("HHHH80sI", 3, 0x1234, 0x5678, 1, b"l410-quick-test", 0))
fcntl.ioctl(fd, 0x5501); time.sleep(0.3)
def ev(t, c, v):
    n = time.time(); s = int(n); return struct.pack("llHHi", s, int((n - s) * 1e6), t, c, v)
os.write(fd, ev(1, 0x2c0, 1) + ev(0, 0, 0) + ev(1, 0x2c0, 0) + ev(0, 0, 0)); time.sleep(0.03)
print(" ".join(open(f"/sys/devices/system/cpu/cpufreq/policy{p}/scaling_min_freq").read().strip() for p in (0, 4, 6)))
fcntl.ioctl(fd, 0x5502); os.close(fd)
PY
)
	[ "$x " != "$(cmin)" ] && [[ $x =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]] && pass perf.input-boost "key press raised CPU floors to $x" || fail perf.input-boost "CPU floors after a key press: '$x'"
	echo $mode > $P/mode
}

# ---------------------------------------------------------------- security / config
m_sec() {
	local cfg x o miss grp
	PLAN=BLD-04
	if [ -r /proc/config.gz ]; then cfg=$(zcat /proc/config.gz); elif [ -r /boot/config-$(uname -r) ]; then cfg=$(cat /boot/config-$(uname -r)); else fail cfg.present "no kernel config (IKCONFIG_PROC)"; return; fi
	cfg_has() { echo "$cfg" | grep -qE "^CONFIG_$1=[ym]"; }
	while read -r grp x; do
		[ -n "$grp" ] || continue
		miss=""; for o in $x; do cfg_has $o || miss="$miss $o"; done
		[ -z "$miss" ] && pass cfg.$grp "all set: $x" || fail cfg.$grp "not set:$miss"
	done << 'EOF'
hardening STRICT_DEVMEM IO_STRICT_DEVMEM RANDOMIZE_BASE STACKPROTECTOR_STRONG FORTIFY_SOURCE HARDENED_USERCOPY STRICT_KERNEL_RWX SECCOMP SECURITY_YAMA
lsm SECURITY SECURITY_APPARMOR AUDIT
containers CGROUPS MEMCG CPUSETS NAMESPACES USER_NS NET_NS BPF_SYSCALL OVERLAY_FS VETH BRIDGE
netfilter NETFILTER NF_TABLES NFT_CT NFT_NAT NF_CONNTRACK
vpn TUN WIREGUARD XFRM_USER INET_ESP PPP L2TP
netfs CIFS NFS_FS
usbfs EXFAT_FS NTFS3_FS VFAT_FS UDF_FS ISO9660_FS JOLIET BLK_DEV_SR NLS_UTF8 NLS_CODEPAGE_936 NLS_CODEPAGE_437 FUSE_FS
usb USB_STORAGE USB_UAS USB_ACM USB_SERIAL USB_SERIAL_CH341 USB_SERIAL_PL2303 USB_PRINTER SND_USB_AUDIO USB_VIDEO_CLASS USB_NET_CDCETHER USB_NET_RNDIS_HOST
bluetooth BT_RFCOMM BT_BNEP BT_HIDP UHID
hid HIDRAW USB_HIDDEV HID_BATTERY_STRENGTH
wwan USB_NET_HUAWEI_CDC_NCM USB_NET_CDC_MBIM USB_NET_QMI_WWAN USB_WDM PPP
qdisc NET_SCH_FQ_CODEL
storage BLK_DEV_LOOP DM_CRYPT ZRAM SQUASHFS
system INPUT_UINPUT EFIVAR_FS DMI PSTORE_RAM WATCHDOG SOFTLOCKUP_DETECTOR HARDLOCKUP_DETECTOR DETECT_HUNG_TASK WQ_WATCHDOG
EOF
	PLAN=BLD-05
	cfg_has DMATEST && hyg cfg.debug-off "CONFIG_DMATEST=y (test code in a production kernel)" || pass cfg.debug-off "no DMATEST"
	PLAN=SEC-02
	[[ " $(rd /proc/cmdline) " == *" nokaslr "* ]] && hyg sec.kaslr "nokaslr on the command line" || pass sec.kaslr "KASLR not disabled"
	[ "$(rd /proc/sys/kernel/kptr_restrict)" -ge 1 ] && [ "$(rd /proc/sys/kernel/dmesg_restrict)" = 1 ] && pass sec.restrict "kptr_restrict $(rd /proc/sys/kernel/kptr_restrict), dmesg_restrict 1" ||
		hyg sec.restrict "kptr_restrict $(rd /proc/sys/kernel/kptr_restrict), dmesg_restrict $(rd /proc/sys/kernel/dmesg_restrict)"
	PLAN=SEC-03
	x=""; for o in kirin-ipc/xfer hi6405/registers huawei-echub/read; do [ -e /sys/kernel/debug/$o ] && x="$x $o"; done
	[ -z "$x" ] && pass sec.debugfs "no hardware-writing debugfs files" || hyg sec.debugfs "debugfs files that write hardware:$x"
	PLAN=SEC-13
	x=$(sshd -T 2> /dev/null | awk '$1 == "passwordauthentication" || $1 == "permitrootlogin" { printf "%s=%s ", $1, $2 }')
	[[ $x == *"passwordauthentication=no"* && $x == *"permitrootlogin=no"* ]] && pass sec.sshd "$x" || hyg sec.sshd "sshd: $x"
}

# ---------------------------------------------------------------- image hygiene
m_img() {
	local x f
	PLAN=INS-07
	x=$(systemctl list-unit-files 'l410-*' --no-legend 2> /dev/null | awk '$2 != "masked" && $2 != "disabled" { print $1 }' | tr '\n' ' ')
	[ -z "$x" ] && pass img.test-units "no l410 test services" || hyg img.test-units "test services enabled: $x"
	x=$(grep -l NOPASSWD /etc/sudoers /etc/sudoers.d/* 2> /dev/null | tr '\n' ' ')
	[ -z "$x" ] && pass img.sudo "no NOPASSWD sudo rules" || hyg img.sudo "NOPASSWD in $x"
	x=$(grep -rhs '^User=.' /etc/sddm.conf /etc/sddm.conf.d/ | head -1)
	[ -z "$x" ] && pass img.autologin "no display-manager auto-login" || hyg img.autologin "sddm auto-login: $x"
	x=$(grep -l '128\.128\.' /etc/systemd/network/* 2> /dev/null | tr '\n' ' ')
	[ -z "$x" ] && pass img.networkd "no lab static-IP networkd files" || hyg img.networkd "lab networkd config: $x"
	[ "$(systemctl is-enabled systemd-pstore.service 2> /dev/null)" = masked ] && hyg img.pstore "systemd-pstore is masked (crash logs are not archived)" || pass img.pstore "systemd-pstore not masked"
	x=$(ls /home/*/.config/systemd/user/plasma-kwin_wayland.service.d/perf-log.conf /usr/local/bin/*.orig /root/hi110x.ko.* 2> /dev/null | tr '\n' ' ')
	[ -z "$x" ] && pass img.leftovers "no bench/backup leftovers" || hyg img.leftovers "leftovers: $x"
	[[ $(rd /proc/cmdline) == *"/boot/l410/Image"* ]] && hyg img.kernel-path "running the test-harness kernel from /boot/l410 (not a packaged kernel)" || pass img.kernel-path "packaged kernel"
	info img.identity "machine-id $(rd /etc/machine-id), ssh host key $(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2> /dev/null | awk '{ print $2 }') (must differ between machines)"
}

# ---------------------------------------------------------------- runner
run_module() {
	local m=$1 t0 pid b n=0
	b=${BUDGET[$m]:-30}
	echo "== $m: ${DESC[$m]}"
	t0=$(now)
	(m_$m) < /dev/null &
	pid=$!
	while kill -0 $pid 2> /dev/null; do
		if [ $n -ge $((b * 10)) ]; then
			killtree $pid
			PLAN=- _r FAIL "$m.timeout" "module did not finish in ${b} s, killed"
			break
		fi
		sleep 0.1; n=$((n + 1))
	done
	wait $pid 2> /dev/null
	do_restore
	echo "$m $(dsec $t0 $(now))" >> "$OUT/timing.txt"
}

summarize() {
	local k c
	declare -A n=()
	while IFS=$'\t' read -r k _; do n[$k]=$((${n[$k]:-0} + 1)); done < "$RES"
	echo
	echo "== failures"
	awk -F'\t' '$1 == "FAIL" { printf "FAIL  %-26s [%s] %s\n", $2, $3, $4 }' "$RES"
	awk -F'\t' '$1 == "XPASS" { printf "XPASS %-26s take it off the KNOWN list\n", $2 }' "$RES"
	c=${n[FAIL]:-0}
	if has python3; then
		python3 - "$RES" "$OUT" "$(uname -r)" "$(rd /sys/class/dmi/id/product_serial)" "$(dsec $T0 $(now))" "$PROFILE" "$FAST" << 'PY'
import json, sys
res, out, kernel, serial, secs, profile, fast = sys.argv[1:]
rows = [dict(zip(("result", "id", "plan", "message"), l.rstrip("\n").split("\t", 3))) for l in open(res)]
with open(out + "/results.jsonl", "w") as f:
    for r in rows: f.write(json.dumps(r, ensure_ascii=False) + "\n")
count = {}
for r in rows: count[r["result"]] = count.get(r["result"], 0) + 1
json.dump({"kernel": kernel, "serial": serial, "seconds": float(secs), "profile": profile, "fast": fast == "1",
           "result": "FAIL" if count.get("FAIL") else "PASS", "count": count,
           "failures": [r for r in rows if r["result"] == "FAIL"],
           "known_failures": [r for r in rows if r["result"] == "XFAIL"],
           "warnings": [r for r in rows if r["result"] == "WARN"],
           "xpass": [r["id"] for r in rows if r["result"] == "XPASS"]},
          open(out + "/summary.json", "w"), ensure_ascii=False, indent=1)
PY
	fi
	echo
	[ "$c" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL ($c)"
	echo "SUMMARY: pass=${n[PASS]:-0} fail=$c xfail=${n[XFAIL]:-0} xpass=${n[XPASS]:-0} warn=${n[WARN]:-0} skip=${n[SKIP]:-0} info=${n[INFO]:-0} time=$(dsec $T0 $(now))s profile=$PROFILE$([ "$FAST" = 1 ] && echo " fast")"
	echo "OUT: $OUT"
	return $((c > 100 ? 100 : c))
}

# The display powers down completely when it is off (kirin990-dss: backlight, panel, bridge,
# DSI, DSS domain), so the display/bridge/domain checks need it on: wake it through the
# Wayland session for the run and put it back to sleep at the end.
DISPLAY_SLEPT=""
display_wake() {
	local c d s
	for c in /sys/class/drm/card[0-9]*-eDP-1; do [ -e "$c/dpms" ] && d=$c; done
	[ -n "$d" ] && [ "$(rd $d/dpms)" != On ] || return 0
	s=$(wl_session) || { echo "   display is off and there is no Wayland session to wake it"; return 0; }
	set -- $s
	WL_DISPLAY=$3 as_user $1 env QT_QPA_PLATFORM=wayland kscreen-doctor --dpms on > /dev/null 2>&1
	for c in $(seq 1 20); do [ "$(rd $d/dpms)" = On ] && break; sleep 0.1; done
	if [ "$(rd $d/dpms)" = On ]; then
		DISPLAY_SLEPT="$1 $3"; echo "   display was off: woken for the display checks (put back to sleep at the end)"
		sleep 1	# bridge, panel and backlight come up about 300 ms after DPMS on
	else
		echo "   display is off and did not wake"
	fi
}
display_resleep() {
	[ -n "$DISPLAY_SLEPT" ] || return 0
	set -- $DISPLAY_SLEPT
	WL_DISPLAY=$2 as_user $1 env QT_QPA_PLATFORM=wayland kscreen-doctor --dpms off > /dev/null 2>&1
	DISPLAY_SLEPT=""
}

body() {
	local m up
	echo "== L410 quick self-check, $(date '+%F %T %z'), kernel $(uname -r), profile $PROFILE$([ "$FAST" = 1 ] && echo ', fast')"
	up=$(cut -d. -f1 /proc/uptime)
	if [ "$up" -lt 60 ]; then echo "   waiting $((60 - up)) s for the boot to settle"; sleep $((60 - up)); fi
	display_wake
	for m in $MODULES; do
		[ -n "$ONLY" ] && [[ ,$ONLY, != *",$m,"* ]] && continue
		[[ ,$SKIPM, == *",$m,"* ]] && continue
		run_module $m
	done
	# kernel messages produced while the checks ran
	journalctl -k --after-cursor="$CURSOR" -o short-monotonic --no-pager > "$OUT/klog-run.txt" 2> /dev/null
	PLAN=BOOT-10
	local x; x=$(grep -E "$SPLAT" "$OUT/klog-run.txt" | grep -v ramoops)
	[ -z "$x" ] && _r PASS run.klog "no oops/BUG/WARNING/SError/stall during the run ($(wc -l < "$OUT/klog-run.txt") kernel lines)" ||
		_r FAIL run.klog "during the run: $(echo "$x" | head -3 | cut -c1-160 | tr '\n' '|')"
	display_resleep
	summarize
}

main() {
	FAST=0 PROFILE=dev RISKY=0 ONLY="" SKIPM="" OUT=""
	while [ $# -gt 0 ]; do
		case $1 in
		--fast) FAST=1 ;;
		--risky) RISKY=1 ;;
		--profile) PROFILE=$2; shift ;;
		--only) ONLY=$2; shift ;;
		--skip) SKIPM=$2; shift ;;
		--out) OUT=$2; shift ;;
		--list) for m in $MODULES; do printf '%-8s %3s s  %s\n' $m ${BUDGET[$m]} "${DESC[$m]}"; done; return 0 ;;
		-h | --help) sed -n '2,32p' "$0" 2> /dev/null || echo "see docs/testing/quick-suite.md"; return 0 ;;
		*) echo "unknown option $1"; return 2 ;;
		esac
		shift
	done
	case $PROFILE in dev | prod) ;; *) echo "--profile dev|prod"; return 2 ;; esac
	OUT=${OUT:-/var/log/l410-quick/$(date +%Y%m%d-%H%M%S)}
	mkdir -p "$OUT" || return 2
	RES=$OUT/results.tsv
	: > "$RES"; : > "$OUT/restore.sh"; : > "$OUT/timing.txt"
	export LC_ALL=C PATH=$PATH:/usr/sbin:/sbin
	mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2> /dev/null
	T0=$(now)
	CURSOR=$(journalctl -k -n 0 --show-cursor --no-pager 2> /dev/null | sed -n 's/^-- cursor: //p')
	journalctl -k -b -o short-monotonic --no-pager > "$OUT/klog-boot.txt" 2> /dev/null || dmesg > "$OUT/klog-boot.txt"
	trap 'do_restore; guard_disarm emul; display_resleep' EXIT
	trap 'exit 130' INT TERM
	body 2>&1 | tee "$OUT/log.txt"
	return "${PIPESTATUS[0]}"
}

main "$@" < /dev/null
