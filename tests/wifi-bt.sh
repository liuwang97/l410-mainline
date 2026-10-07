#!/bin/bash
# WiFi/Bluetooth: Hi110x WiFi + Bluetooth check on the 6.18 test kernel (Debian).
# Run on the target as root, e.g. through the harness: --script tests/wifi-bt.sh
#
# Scan only. This never connects to any network or pairs any device, and never reads
# stored WiFi credentials. NetworkManager is told (at runtime only) to leave wlan0 alone.
#
# Every result line also goes to the journal (tag wifi-bt-test), so a run that wedges the
# network can still be read from the Debian journal afterwards. The WiFi part runs under a
# reboot guard (GUARD seconds, default 300) that is cancelled when it finishes.
#
# Env: WIFI_WAIT (s, default 150)  BT_SCAN (s, default 15)  GUARD (s)  SUSPEND=1
#      MIN_UPTIME (s): first idle until the system has been up this long (chip low-power test)
#      VERBOSE=1: full driver log (hi110x.verbose) while the test runs
PASS=0; FAIL=0
log() { echo "$*"; logger -t wifi-bt-test -- "$*" 2> /dev/null; }
pass() { log "PASS: $*"; PASS=$((PASS + 1)); }
fail() { log "FAIL: $*"; FAIL=$((FAIL + 1)); }
info() { log "INFO: $*"; }
S=""; [ "$(id -u)" = 0 ] || S=sudo
WIFI_WAIT=${WIFI_WAIT:-150}
BT_SCAN=${BT_SCAN:-15}
GUARD=${GUARD:-300}
MIN_UPTIME=${MIN_UPTIME:-0}
PARAM=/sys/module/hi110x/parameters

log "== kernel $(uname -r)"
up=$(cut -d. -f1 /proc/uptime)
if [ "$up" -lt "$MIN_UPTIME" ]; then
	info "idle until ${MIN_UPTIME}s of uptime (now ${up}s)"
	sleep $((MIN_UPTIME - up))
fi
info "uptime $(cut -d' ' -f1 /proc/uptime)s"

# ---- driver log volume: errors only unless hi110x.verbose is set
drvlog='hi110x|HI11XX|\[PCIE|INI_DRV|hwifi|HCC|\[BUART\]|wal_|hmac_|mac_vap|DFR|plat_init|sar_txpwr|gpio-ssi|st_share_mem'
n=$($S dmesg | grep -cE "$drvlog")
[ -r $PARAM/verbose ] && info "hi110x.verbose=$(cat $PARAM/verbose), ssi_dump=$(cat $PARAM/ssi_dump 2> /dev/null)"
[ "$n" -le 100 ] && pass "driver log since boot: $n lines" || fail "driver log since boot: $n lines (> 100)"
if [ "${VERBOSE:-0}" = 1 ] && [ -w $PARAM/verbose ]; then
	echo 1 > $PARAM/verbose
	info "verbose driver log for the rest of the test"
fi

# ---- driver / platform
if [ -d /sys/module/hi110x ] || $S modprobe hi110x 2>/dev/null; then
	pass "hi110x driver present"
else
	fail "hi110x driver not loaded (modprobe failed)"
fi
bound() { ls "$1" 2> /dev/null | grep -v -E '^(bind|unbind|uevent|module|new_id|remove_id)$' | grep -q .; }
for n in hi110x_board hisi_bfgx; do
	bound /sys/bus/platform/drivers/$n && pass "platform driver $n bound" || fail "platform driver $n not bound"
done
bound /sys/bus/serial/drivers/hi110x-bfgx-uart && pass "BUART serdev bound" || fail "BUART serdev not bound"

t=0
while [ ! -e /sys/class/net/wlan0 ] && [ $t -lt "$WIFI_WAIT" ]; do sleep 2; t=$((t + 2)); done
if [ -e /sys/class/net/wlan0 ]; then
	pass "wlan0 present after ${t}s ($(cat /sys/class/net/wlan0/address))"
else
	fail "wlan0 missing after ${WIFI_WAIT}s"
fi
pcidev=""
for d in /sys/bus/pci/devices/*; do
	[ "$(cat $d/vendor 2>/dev/null)" = 0x19e5 ] && [ "$(cat $d/device)" = 0x1103 ] && pcidev=$d
done
[ -n "$pcidev" ] && pass "PCIe 19e5:1103 at ${pcidev##*/}" || info "19e5:1103 not on the PCI bus right now (chip may be powered down)"

# ---- Bluetooth (first: it does not touch the RTNL)
log "== BUART state"
cat /proc/tty/driver/ttyAMA 2> /dev/null
# uart4 pins: mux fe102144..150 (pins 81-84, want 1), conf fe102950..95c (pins 84-87)
for d in /sys/kernel/debug/pinctrl/fe102000.pinmux* /sys/kernel/debug/pinctrl/fe102800.pinmux*; do
	grep -E "^pin 8[0-9] " "$d/pins" 2> /dev/null | sed "s|^|${d##*/}: |"
done
for c in clk_uart4 pclk_uart4 clk_pmu32kb; do
	[ -d /sys/kernel/debug/clk/$c ] && echo "$c rate $(cat /sys/kernel/debug/clk/$c/clk_rate) en $(cat /sys/kernel/debug/clk/$c/clk_enable_count) parent $(cat /sys/kernel/debug/clk/$c/clk_parent 2> /dev/null)"
done
bt_power_on() {
	out=$($S timeout 30 bluetoothctl power on 2>&1)
	echo "$out" | grep -q "succeeded\|Changing power on"
}
# leave the controller as it was found (the desktop default is powered; quick.sh BT-01 checks it)
bt_was=$($S timeout 10 bluetoothctl show 2> /dev/null | awk '/Powered:/ { print $2; exit }')
if [ -d /sys/class/bluetooth/hci0 ]; then
	pass "hci0 registered"
	# state before the test touches it (after MIN_UPTIME: has it survived the idle time?)
	command -v hciconfig > /dev/null && $S timeout 10 hciconfig hci0 | grep -E "UP|DOWN" | head -1
	$S systemctl start bluetooth 2> /dev/null
	sleep 2
	if command -v bluetoothctl > /dev/null; then
		if bt_power_on; then
			pass "bluetoothctl power on"
		elif [ -w /sys/module/hi110x/parameters/buart_flowctl ] && command -v hciconfig > /dev/null; then
			info "power on failed ($(echo $out | tail -c 120)); retrying with BUART flow control off"
			echo 0 > /sys/module/hi110x/parameters/buart_flowctl
			$S timeout 30 hciconfig hci0 up; sleep 2
			if bt_power_on; then pass "bluetoothctl power on (no RTS/CTS)"; else fail "power on: $(echo $out | tail -c 200)"; fi
		else
			fail "power on: $(echo $out | tail -c 200)"
		fi
		cat /proc/tty/driver/ttyAMA 2> /dev/null | grep "^4:"
		$S timeout 10 bluetoothctl show | grep -E "Controller|Powered|Address" | head -5
		$S timeout $((BT_SCAN + 10)) bluetoothctl --timeout "$BT_SCAN" scan on > /tmp/bt-scan.txt 2>&1
		n=$(grep -c "NEW.*Device" /tmp/bt-scan.txt)
		[ "$n" -gt 0 ] && pass "BT scan: $n devices" || fail "BT scan found no device"
		[ "$bt_was" = yes ] || $S timeout 10 bluetoothctl power off > /dev/null 2>&1
	else
		fail "bluetoothctl missing"
	fi
else
	fail "no hci0"
fi

# ---- WiFi scan
# wlan0 carrying the session (home WLAN, the only link): scan while connected and leave
# NetworkManager and the interface alone; otherwise the old bring-up path below
if [ -e /sys/class/net/wlan0 ] && ip route show default 2> /dev/null | grep -q "dev wlan0 "; then
	info "wlan0 is the active link: scanning while connected"
	out=$($S timeout 90 iw dev wlan0 scan 2>&1); rc=$?
	n=$(echo "$out" | grep -c '^BSS ')
	[ $rc = 0 ] && [ "$n" -gt 0 ] && pass "iw scan (connected): $n BSS" || fail "iw scan rc=$rc bss=$n: $(echo "$out" | head -3)"
	echo "$out" | grep -E '^BSS |signal:|freq:' | head -30
elif [ -e /sys/class/net/wlan0 ]; then
	systemd-run --quiet --unit=wifibt-guard --on-active="$GUARD" /bin/systemctl reboot --force 2> /dev/null
	info "reboot guard armed (${GUARD}s)"
	command -v nmcli > /dev/null && $S timeout 20 nmcli device set wlan0 managed no 2> /dev/null
	info "wlan0 unmanaged, bringing it up"
	if $S timeout 60 ip link set wlan0 up; then pass "wlan0 up"; else fail "ip link set wlan0 up"; fi
	sleep 2
	if command -v iw > /dev/null; then
		info "iw scan"
		out=$($S timeout 90 iw dev wlan0 scan 2>&1); rc=$?
		n=$(echo "$out" | grep -c '^BSS ')
		[ $rc = 0 ] && [ "$n" -gt 0 ] && pass "iw scan: $n BSS" || fail "iw scan rc=$rc bss=$n: $(echo "$out" | head -3)"
		echo "$out" | grep -E '^BSS |signal:|freq:' | head -30
	else
		fail "iw missing"
	fi
	$S timeout 30 ip link set wlan0 down
	info "wlan0 down"
	systemctl stop wifibt-guard.timer 2> /dev/null
	info "reboot guard cancelled"
fi

# ---- optional: suspend/resume and WiFi still works
if [ "${SUSPEND:-0}" = 1 ] && [ -e /sys/class/net/wlan0 ] && ! ip route show default 2> /dev/null | grep -q "dev wlan0 "; then
	if grep -qw mem /sys/power/state; then
		$S rtcwake -m mem -s 20 && pass "suspend/resume" || fail "rtcwake"
		$S ip link set wlan0 up && sleep 2 &&
			{ $S timeout 90 iw dev wlan0 scan | grep -q '^BSS ' && pass "scan after resume" || fail "scan after resume"; }
		$S ip link set wlan0 down
	else
		info "no suspend-to-ram on this kernel, skipped"
	fi
fi

echo "== driver log"
$S dmesg | grep -E "pcie-kport f4000000|clk_pmu32kb|Bluetooth: Core" | head -20
# everything from the driver's first message on, minus unrelated noise
$S dmesg | sed -n '/hi110x/,$p' | grep -vE "audit|r8152|systemd|EXT4|usb [0-9]|NVRAM get fail|get_init_priv fail|bfgx ini init|fcc_txpwr|^\[[ 0-9.]*\] *\}?$" | tail -500
[ "${VERBOSE:-0}" = 1 ] && [ -w $PARAM/verbose ] && echo 0 > $PARAM/verbose

log "== wifi-bt: $PASS passed, $FAIL failed"
[ $FAIL = 0 ]
