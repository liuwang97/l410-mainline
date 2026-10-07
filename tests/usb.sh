#!/bin/bash
# USB test: run on the 6.18 test kernel's Debian (harness: --script tests/usb.sh).
# Checks the Kirin 990 DWC3/PHY stack, the on-board RTS5411 hub, the RTL8153 NIC
# (link, DHCP address, sustained traffic) and the built-in UVC camera.
# Prints PASS/FAIL/WARN lines; last line "RESULT: PASS" or "RESULT: FAIL (n)".
# Exit code = number of failures.

# the USB Ethernet adapter: the first enx* interface, or NIC=<name>
NIC=${NIC:-$(ls /sys/class/net | grep -m1 "^enx")}
# the address the USB NIC is expected to get (DHCP); empty: not checked
NIC_IP=${NIC_IP:-}
fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
warn() { echo "WARN $*"; }
S() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo -n "$@"; fi; }

# /sys/bus/usb/devices entry for VID:PID (first match)
usbdev() {
	local d
	for d in /sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] || continue
		[ "$(cat "$d/idVendor"):$(cat "$d/idProduct")" = "$1" ] && { echo "$d"; return 0; }
	done
	return 1
}
drv_of() { basename "$(readlink "$1/driver" 2>/dev/null)" 2>/dev/null; }
# kernel log of this boot: the journal keeps all of it (other drivers can push
# the early USB messages out of the dmesg ring buffer)
klog() { S journalctl -k -b -o short-monotonic --no-pager 2>/dev/null | grep -q . && S journalctl -k -b -o short-monotonic --no-pager || S dmesg; }
KLOG=$(klog 2>/dev/null)

echo "== kernel $(uname -r)"

# ---- controller / PHY ----
bound() { ls "/sys/bus/platform/drivers/$1" 2>/dev/null | grep -q "$2"; }
bound kirin990-usb-phy usb_phy && pass "PHY driver bound (kirin990-usb-phy)" || fail "PHY driver not bound"
bound dwc3-kirin990 hisi_usb && pass "glue bound (dwc3-kirin990)" || fail "glue not bound"
bound dwc3 f8400000 && pass "dwc3 core bound" || fail "dwc3 core not bound"
bound xhci-hcd xhci && pass "xhci-hcd bound" || fail "xhci-hcd not bound"
phyup=$(echo "$KLOG" | grep "kirin990-usb-phy.*up:" | head -1)
case $phyup in
*"fw loaded, mux 3"*) pass "combo PHY up, SRAM firmware, USB+DP2 mux (${phyup#*up: })" ;;
"") fail "no combo PHY bring-up message" ;;
*) fail "combo PHY: ${phyup#*up: }" ;;
esac
S cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | grep -Ei "usb3otg|usb2phy|usb_tcxo|abb_usb|mmc_usbdp" | sed 's/^/  clk: /'

# ---- topology ----
echo "== lsusb -t"
if command -v lsusb > /dev/null; then lsusb -t 2>&1; lsusb 2>&1; fi
for d in /sys/bus/usb/devices/*; do
	[ -f "$d/idVendor" ] && echo "  $(basename "$d") $(cat "$d/idVendor"):$(cat "$d/idProduct") speed=$(cat "$d/speed") drv=$(drv_of "$d") $(cat "$d/product" 2>/dev/null)"
done

check_dev() { # VID:PID name expected-speed
	local d s
	if ! d=$(usbdev "$1"); then fail "$2 ($1) not enumerated"; return 1; fi
	s=$(cat "$d/speed")
	if [ "$s" = "$3" ]; then pass "$2 ($1) at $(basename "$d"), ${s}M"
	else fail "$2 ($1) at $(basename "$d") runs ${s}M, expected ${3}M"; fi
}
check_dev 1d6b:0002 "USB 2.0 root hub" 480
check_dev 1d6b:0003 "USB 3 root hub" 10000
check_dev 0bda:5411 "RTS5411 hub (USB 2.0 half)" 480
check_dev 0bda:0411 "RTS5411 hub (USB 3 half)" 5000
# the RTL8153 is the lab network (harness link); on the home WLAN it is not plugged in
if usbdev 0bda:8153 > /dev/null || [ "${USB_NIC_REQUIRED:-0}" = 1 ] || ! ip -4 route show default | grep -q "dev wl"; then
	NIC_LAB=1
	check_dev 0bda:8153 "RTL8153" 5000
else
	NIC_LAB=0
	warn "RTL8153 not attached and the default route is on WLAN: NIC checks skipped (USB_NIC_REQUIRED=1 forces them)"
fi
if d=$(usbdev 0bda:8153); then
	[ "$(drv_of "$d:1.0")" = r8152 ] && pass "r8152 bound" || fail "r8152 not bound to $(basename "$d"):1.0"
	case $(basename "$d") in 2-1.*) pass "RTL8153 behind the USB 3 hub";; *) fail "RTL8153 not at 2-1.x";; esac
fi

# ---- camera (hub port 1.4) ----
if d=$(usbdev 3196:0203); then
	pass "HD Camera (3196:0203) at $(basename "$d"), $(cat "$d/speed")M"
	uvc=0
	for i in "$d":1.*; do [ "$(drv_of "$i")" = uvcvideo ] && uvc=1; done
	[ $uvc = 1 ] && pass "uvcvideo bound" || fail "uvcvideo not bound (module missing?)"
	vdev=""
	for v in /sys/class/video4linux/video*; do
		[ -e "$v" ] || continue
		case $(readlink -f "$v/device") in "$(readlink -f "$d")"/*) vdev=${vdev:-/dev/$(basename "$v")};; esac
	done
	[ -n "$vdev" ] && pass "V4L2 node $vdev ($(cat /sys/class/video4linux/$(basename $vdev)/name))" || fail "no V4L2 node for the camera"
	if command -v v4l2-ctl > /dev/null; then
		lst=$(S v4l2-ctl --list-devices 2>&1)
		echo "$lst" | sed 's/^/  /'
		echo "$lst" | grep -qi "HD Camera" && pass "v4l2-ctl lists HD Camera" || fail "v4l2-ctl does not list HD Camera"
		if [ -n "$vdev" ]; then
			rm -f /tmp/usb-test-frame
			if S timeout 20 v4l2-ctl -d "$vdev" --stream-mmap --stream-count=3 --stream-to=/tmp/usb-test-frame > /dev/null 2>&1 &&
				[ -s /tmp/usb-test-frame ]; then
				pass "camera frame grab ($(stat -c %s /tmp/usb-test-frame) bytes for 3 frames)"
			else
				warn "camera frame grab failed"
			fi
		fi
	else
		warn "v4l2-ctl not installed, skipped --list-devices/frame grab"
	fi
	# re-plug through the hub: disable/enable the camera's downstream port
	port=/sys/bus/usb/devices/1-1:1.0/1-1-port4/disable
	if [ -w "$port" ] || S test -e "$port"; then
		echo 1 | S tee "$port" > /dev/null
		sleep 2
		gone=1; usbdev 3196:0203 > /dev/null && gone=0
		echo 0 | S tee "$port" > /dev/null
		back=0
		for i in $(seq 1 20); do
			d2=$(usbdev 3196:0203) && [ "$(drv_of "$d2:1.0")" = uvcvideo ] && { back=1; break; }
			sleep 0.5
		done
		[ $gone = 1 ] && [ $back = 1 ] && pass "camera re-plug via hub port 4 (gone, back, uvcvideo re-bound)" ||
			fail "camera re-plug via hub port 4 (gone=$gone back=$back)"
	else
		warn "no $port, camera re-plug skipped"
	fi
else
	fail "HD Camera (3196:0203) not enumerated"
fi

# ---- network ----
if [ $NIC_LAB = 0 ]; then
	:
elif [ -d /sys/class/net/$NIC ]; then
	pass "$NIC present"
	[ "$(cat /sys/class/net/$NIC/operstate)" = up ] && pass "$NIC up" || fail "$NIC operstate $(cat /sys/class/net/$NIC/operstate)"
	sp=$(cat /sys/class/net/$NIC/speed 2>/dev/null)
	[ "$sp" = 1000 ] && pass "$NIC link 1000 Mb/s" || warn "$NIC link speed '$sp'"
	if [ -n "$NIC_IP" ]; then ip -4 addr show dev $NIC | grep -q "inet $NIC_IP/" && pass "$NIC has $NIC_IP" || fail "$NIC has no $NIC_IP ($(ip -4 -br addr show dev $NIC))"; fi
	gw=$(ip -4 route show default dev $NIC | awk '{print $3; exit}')
	if [ -n "$gw" ]; then
		out=$(S ping -q -c 300 -i 0.02 -W 2 "$gw" 2>&1)
		loss=$(echo "$out" | grep -o '[0-9.]*% packet loss' | cut -d% -f1)
		echo "  ping $gw x300: $(echo "$out" | tail -2 | tr '\n' ' ')"
		[ "${loss:-100}" = 0 ] && pass "sustained ping to $gw, 0% loss" || fail "ping to $gw: ${loss:-?}% loss"
		# large frames at 50/s (the router rate-limits ICMP, so no flood ping)
		out=$(S ping -q -c 1000 -i 0.02 -s 1400 -W 2 "$gw" 2>&1)
		loss=$(echo "$out" | grep -o '[0-9.]*% packet loss' | cut -d% -f1)
		echo "  ping 1400 B x1000: $(echo "$out" | tail -2 | tr '\n' ' ')"
		awk "BEGIN{exit !(${loss:-100} < 1)}" && pass "1400 B ping loss ${loss}%" || fail "1400 B ping loss ${loss:-?}%"
	else
		fail "no default route via $NIC"
	fi
	st=/sys/class/net/$NIC/statistics
	echo "  stats: rx_packets=$(cat $st/rx_packets) tx_packets=$(cat $st/tx_packets) rx_errors=$(cat $st/rx_errors) tx_errors=$(cat $st/tx_errors) rx_dropped=$(cat $st/rx_dropped)"
	[ "$(cat $st/rx_errors)" = 0 ] && [ "$(cat $st/tx_errors)" = 0 ] && pass "no rx/tx errors" || fail "rx/tx errors on $NIC"
else
	fail "$NIC missing ($(ls /sys/class/net | tr '\n' ' '))"
fi

# ---- kernel log ----
log=$KLOG
bad=$(echo "$log" | grep -E "xhci.*(HC died|halt failed|Timeout while waiting|ERROR)|dwc3.*(error|failed)|kirin990-usb-phy.*(timeout|failed|no TCA)|r8152.*(Tx timeout|fail)|usb .*: (device descriptor read.*error|device not accepting address|unable to enumerate)")
if [ -z "$bad" ]; then pass "no USB errors in dmesg"; else fail "USB errors in dmesg:"; echo "$bad" | head -20 | sed 's/^/  /'; fi
# a system resume resets every device behind the hub (the controller lost power in s2idle):
# only resets outside "PM: suspend entry" .. "PM: suspend exit" count
resets=$(echo "$log" | awk '/PM: suspend entry/ { pm = 1 } /PM: suspend exit/ { pm = 0 }
	/usb [0-9.-]+: reset (high|super|full|low)/ { if (pm) r++; else n++ } END { print n + 0, r + 0 }')
set -- $resets
[ "$1" -le 2 ] && pass "USB resets: $1 (plus $2 during resume)" || fail "USB resets: $1 (plus $2 during resume)"
echo "$log" | grep -E "kirin990|dwc3|xhci|usb [0-9]|r8152|onboard" | tail -40 | sed 's/^/  | /'

echo
if [ $fails = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL ($fails)"; fi
exit $fails
