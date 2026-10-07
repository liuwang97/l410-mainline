#!/bin/bash
# Screen off/on through KWin with the kirin990-dss full modeset: the whole panel chain must
# really switch off (backlight, eDP bridge and panel supplies, DSI clocks, DSS power domain),
# come back with a picture (eDP link trained, panel lanes locked and in sync, vblanks, no LDI
# underflow), and the machine must draw less power with the screen off.
# Run as the desktop user inside the Plasma session (passwordless sudo). Power figures need
# the AC adapter unplugged (EC voltage x current, updated every 10 s):
#   ssh l410 'export XDG_RUNTIME_DIR=/run/user/${L410_UID:-1000} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${L410_UID:-1000}/bus;
#            bash ~/l410-bench/display-power.sh [cycles] [seconds per power measurement]'
# Prints PASS/FAIL/INFO lines and RESULT at the end; the screen is on again when it exits.
# LEVEL=0..4 sets kirin990_drm.power_off first (see kirin990_drv.c; default: leave it).
# Each off/on cycle runs with the l410 deadman armed (DEADMAN seconds, default 240): a hang
# reboots the machine, the pstore console log shows the last "display off/on" step.
CYCLES=${1:-3}
DUR=${2:-60}
DEADMAN=${DEADMAN:-240}
P=/sys/module/kirin990_drm/parameters/power_off
B=/sys/class/power_supply/echub-battery
A=/sys/class/power_supply/echub-ac
pass=0 fail=0
ok() { echo "PASS: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }
info() { echo "INFO: $*"; }

# debugfs is root-only: let root expand the glob
D=$(sudo sh -c 'grep -l "^kirin " /sys/kernel/debug/dri/*/name 2>/dev/null' | head -1)
D=${D%/name}
[ -n "$D" ] || { echo "FAIL: no kirin DRM device in debugfs"; exit 1; }

kstate() { sudo head -1 "$D/kirin_state"; }
ldi() { sudo sed -n 's/^ldi ctrl \(0x[0-9a-f]*\) .*/\1/p' "$D/kirin_state"; }
underflows() { sudo sed -n 's/.* underflows \([0-9]*\) .*/\1/p' "$D/kirin_state" | head -1; }
# the panel chain's GPIOs, and the backlight enable (pwm-backlight's "enable")
gpios() { sudo grep -E '\|(bridge-1v2|bridge-1v8|bridge-enable|panel-vdd|enable) *\)' /sys/kernel/debug/gpio | sed 's/  */ /g'; }
# use counts only: clk_summary recalculates rates, reading dividers in the media CRG,
# which may be powered off along with the display
clocks() {
	local c
	for c in clk_edc0 aclk_dss pclk_dss clk_dss_axi_mm clk_txdphy0_ref clk_txdphy0_cfg pclk_dsi0 clk_nfc; do
		echo "$c enable $(sudo cat /sys/kernel/debug/clk/$c/clk_enable_count 2>/dev/null) prepare $(sudo cat /sys/kernel/debug/clk/$c/clk_prepare_count 2>/dev/null)"
	done
}
edp() {	# the bridge and DPCD dump the driver writes to the log
	local mark="display-power $RANDOM"
	echo "$mark" | sudo tee /dev/kmsg > /dev/null
	sudo cat "$D/kirin_edp" > /dev/null
	sudo dmesg | sed -n "/$mark/,\$p" | grep -E 'SN65DSI86:|panel DPCD' | sed 's/.*\] //'
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
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}
export QT_QPA_PLATFORM=wayland
dpms() { kscreen-doctor --dpms "$1" > /dev/null 2>&1 || bad "kscreen-doctor --dpms $1 failed ($?)"; }
# keep PowerDevil from dimming or locking the screen while measuring
if [ -z "$DP_INHIBITED" ] && command -v kde-inhibit > /dev/null; then
	DP_INHIBITED=1 exec kde-inhibit --power --screenSaver bash "$0" "$@"
fi

on_battery=0
[ "$(cat $A/online 2>/dev/null)" = 0 ] && on_battery=1
[ -n "$LEVEL" ] && echo "$LEVEL" | sudo tee $P > /dev/null
echo 1 | sudo tee /proc/sys/kernel/panic_all_cpu_backtrace > /dev/null 2>&1
info "kernel $(uname -r), power_off level $(cat $P 2>/dev/null), $(kstate)"
info "battery $(cat $B/capacity)%, AC $(cat $A/online), backlight $(cat /sys/class/backlight/backlight/brightness)"
sudo dmesg | grep -E 'DSI [0-9]+ Mbps|panel power from UEFI|DSS core clock' | sed 's/.*\] /INFO: /'
edp | sed 's/^/INFO: at start: /'

on_mw=
[ $on_battery = 1 ] && on_mw=$(measure "$DUR") && info "screen on: $on_mw mW"

for c in $(seq 1 "$CYCLES"); do
	echo "== cycle $c"
	u0=$(underflows)
	echo "$DEADMAN" | sudo tee /sys/kernel/l410_deadman/timeout > /dev/null
	t0=$(date +%s%N)
	dpms off
	sleep 3
	s=$(kstate)
	case "$s" in
	"power off"*) ok "cycle $c off: $s ($(( ($(date +%s%N) - t0) / 1000000 - 3000 )) ms after the 3 s wait)" ;;
	*) bad "cycle $c off: kirin_state says '$s'" ;;
	esac
	g=$(gpios)
	echo "$g" | grep -E 'bridge|panel' | grep -q ' hi' && bad "cycle $c off: a bridge/panel GPIO is still high: $(echo $g)" \
		|| ok "cycle $c off: bridge/panel GPIOs low"
	echo "$g" | grep -E 'enable' | grep -v bridge | sed "s/^/INFO: cycle $c off: /"
	info "cycle $c off: bl_power $(cat /sys/class/backlight/backlight/bl_power), actual_brightness $(cat /sys/class/backlight/backlight/actual_brightness)"
	clocks | sed "s/^/INFO: cycle $c off: clock /"
	if [ $on_battery = 1 ] && [ "$c" = 1 ]; then
		off_mw=$(measure "$DUR")
		info "screen off: $off_mw mW (screen on $on_mw mW, saving $((on_mw - off_mw)) mW)"
	fi

	t0=$(date +%s%N)
	dpms on
	sleep 2
	s=$(kstate)
	case "$s" in
	"power on"*) ok "cycle $c on: $s" ;;
	*) bad "cycle $c on: kirin_state says '$s'" ;;
	esac
	l=$(ldi)
	[ $(( ${l:-0} & 1 )) = 1 ] && ok "cycle $c on: LDI scanning out (ctrl $l)" \
		|| bad "cycle $c on: LDI not running (ctrl '$l')"
	e=$(edp)
	echo "$e" | sed "s/^/INFO: cycle $c on: /"
	echo "$e" | grep -q 'lanes 77 77 align 01 sink 01' && ok "cycle $c on: panel lanes locked, aligned, in sync" \
		|| bad "cycle $c on: panel link status not 77 77 / 01 / 01"
	echo "$e" | grep -q ' 96=01' && ok "cycle $c on: bridge main link in normal mode" \
		|| bad "cycle $c on: bridge main link not in normal mode"
	u1=$(underflows)
	[ "$u0" = "$u1" ] && ok "cycle $c on: no LDI underflow" || bad "cycle $c on: underflows $u0 -> $u1"
	sleep 1
	[ "$(cat /sys/class/backlight/backlight/bl_power)" = 0 ] && ok "cycle $c on: backlight powered" \
		|| bad "cycle $c on: bl_power $(cat /sys/class/backlight/backlight/bl_power)"
	echo 0 | sudo tee /sys/kernel/l410_deadman/timeout > /dev/null
	sleep 2
done

sudo dmesg | grep -iE 'kirin|sn65|dsi|edp' | grep -iE 'error|fail|timeout|underflow|not locked|not in stop|differs' \
	| sed 's/.*\] /INFO: log: /' | tail -20
echo "RESULT: $([ $fail = 0 ] && echo PASS || echo FAIL) ($pass passed, $fail failed)"
