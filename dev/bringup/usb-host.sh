#!/bin/bash
# T4 USB: WSL-side bulk transfer test over ssh (harness --host-script).
# Moves random data both ways through the RTL8153 and checks SHA-256.
# The path goes through ssh (and any forwarder in front of the L410), so the rates are a lower bound, not the NIC's capability.
#   USB_BULK_MB  size per direction (default 256)
N=${USB_BULK_MB:-256}
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 ${L410_SSH:-l410})
fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
now() { date +%s.%N; }
rate() { awk -v n="$N" -v a="$1" -v b="$2" 'BEGIN { t = b - a; printf "%d MiB in %.1f s = %.1f MiB/s (%.0f Mbit/s)", n, t, n / t, n * 8.388608 / t }'; }

echo "== target $("${SSH[@]}" 'uname -r; cat /sys/class/net/enx*/speed' 2>&1 | tr '\n' ' ')"

src=$(mktemp)
trap 'rm -f "$src"' EXIT
head -c "${N}M" /dev/urandom > "$src"
want=$(sha256sum < "$src" | cut -d' ' -f1)

# host -> target
t0=$(now)
got=$("${SSH[@]}" 'sha256sum' < "$src" 2>&1 | cut -d' ' -f1)
t1=$(now)
if [ "$got" = "$want" ]; then pass "host->target $(rate "$t0" "$t1"), sha256 ok"
else fail "host->target sha256 mismatch ($got)"; fi

# target -> host
"${SSH[@]}" "head -c ${N}M /dev/urandom > /tmp/usb-bulk.bin && sha256sum < /tmp/usb-bulk.bin" > "$src.sum" 2>&1
want=$(cut -d' ' -f1 < "$src.sum")
t0=$(now)
got=$("${SSH[@]}" 'cat /tmp/usb-bulk.bin' | sha256sum | cut -d' ' -f1)
t1=$(now)
"${SSH[@]}" 'rm -f /tmp/usb-bulk.bin'
rm -f "$src.sum"
if [ -n "$want" ] && [ "$got" = "$want" ]; then pass "target->host $(rate "$t0" "$t1"), sha256 ok"
else fail "target->host sha256 mismatch ($got vs $want)"; fi

echo "== target NIC counters: $("${SSH[@]}" 'cd /sys/class/net/enx*/statistics && echo rx_packets=$(cat rx_packets) tx_packets=$(cat tx_packets) rx_errors=$(cat rx_errors) tx_errors=$(cat tx_errors) rx_dropped=$(cat rx_dropped)')"

# ---- controller re-plug: unbind/bind the glue = PHY exit/init, xHCI and
# hub power cycle, RTL8153 re-enumeration. Runs detached on the target because
# this ssh path uses the same NIC. Two guards keep a failure from wedging the
# shared test machine: the hardware deadman is shortened to 300 s (panics at
# half, then SP805 reset -> Kylin) for the duration of each cycle, and a
# separate systemd timer reboots if the network is not back after 150 s (the
# bind itself may die, e.g. an oops in the driver kills the writer).
CYCLES=${USB_REPLUG_CYCLES:-3}
"${SSH[@]}" 'cat > /tmp/l410-usb-replug.sh' << 'EOF'
G=/sys/bus/platform/drivers/dwc3-kirin990
D=/sys/kernel/l410_deadman/timeout
[ -w $D ] && echo 300 > $D
systemd-run --quiet --collect --unit=l410-usb-replug-guard --on-active=150 \
	sh -c 'echo "l410-usb-replug: network not back after 150 s, rebooting" > /dev/kmsg; systemctl reboot --force'
d=$(basename "$(ls -d $G/*hisi_usb* | head -1)")
sleep 1
echo "$d" > $G/unbind
sleep 3
echo "$d" > $G/bind
i=0
while [ $i -lt 120 ]; do
	gw=$(ip -4 route show default | awk '{print $3; exit}')
	if [ -n "$gw" ] && ping -c 1 -W 1 "$gw" > /dev/null 2>&1; then
		systemctl stop l410-usb-replug-guard.timer 2> /dev/null
		[ -w $D ] && echo 3600 > $D
		exit 0
	fi
	sleep 1
	i=$((i + 1))
done
EOF
ups0=$("${SSH[@]}" 'sudo journalctl -k -b -o cat --no-pager | grep -c "kirin990-usb-phy.*up:"')
for c in $(seq 1 "$CYCLES"); do
	"${SSH[@]}" "sudo systemd-run --quiet --collect --unit=l410-usb-replug-$c sh /tmp/l410-usb-replug.sh" ||
		{ fail "re-plug $c: could not start"; break; }
	t0=$(now)
	sleep 8
	back=0
	for i in $(seq 1 20); do
		"${SSH[@]}" true 2> /dev/null && { back=1; break; }
		sleep 5
	done
	t1=$(now)
	if [ $back = 0 ]; then fail "re-plug $c: target not reachable again"; break; fi
	st=$("${SSH[@]}" 'for d in /sys/bus/usb/devices/*; do [ -f $d/idVendor ] && [ "$(cat $d/idVendor):$(cat $d/idProduct)" = 0bda:8153 ] && echo "$(basename $d) $(cat $d/speed)"; done; sudo journalctl -k -b -o cat --no-pager | grep -c "kirin990-usb-phy.*up:"' | tr '\n' ' ')
	set -- $st
	if [ "$2" = 5000 ] && [ "$3" = $((ups0 + c)) ]; then
		pass "re-plug $c: back after $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.0f", b-a}') s, RTL8153 at $1 ${2}M, PHY init #$3"
	else
		fail "re-plug $c: state '$st' (want RTL8153 at 5000M and PHY init #$((ups0 + c)))"
	fi
done
"${SSH[@]}" 'sudo dmesg | grep -E "kirin990-usb-phy|dwc3|xhci.*(error|fail|died)|r8152.*(fail|timeout)|onboard" | tail -20' | sed 's/^/  | /'
echo
if [ $fails = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL ($fails)"; fi
exit $fails
