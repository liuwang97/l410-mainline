#!/bin/bash
# Warm-reboot cycle that runs on the DUT by itself (docs/testing/test-plan.md BOOT-03, BOOT-07, BOOT-11,
# "常驻 Debian"): state in /var/lib/l410-test/cycle, a boot service continues the loop.
# Every boot: same kernel, WiFi back, no oops/SError/lockup, no deferred devices, UFS error
# counters unchanged, reset reason, stable device names, boot time. Then next_entry=l410-test
# is written to the SYSBOOT grubenv and the machine reboots, until COUNT boots or a failure.
# A boot that does not come back lands on the grubenv fallback (Kylin 2403): the loop stops.
#
#   sudo bash tests/cycle.sh start <count>     install and reboot into the first cycle
#   sudo bash tests/cycle.sh status            progress and per-boot results
#   sudo bash tests/cycle.sh stop              remove the boot service (no reboot)
set -u
S=/var/lib/l410-test/cycle
SELF=/usr/local/lib/l410-test/cycle.sh
UNIT=l410-cycle.service

mark_next() {
	mkdir -p /mnt/sysboot
	mountpoint -q /mnt/sysboot || mount LABEL=SYSBOOT /mnt/sysboot || return 1
	/usr/local/sbin/grubenv-set /mnt/sysboot/grub/grubenv next_entry=l410-test || { umount /mnt/sysboot; return 1; }
	sync; umount /mnt/sysboot
}
names() {	# device names that must not move between boots
	{
		ls /sys/class/net | grep -v '^lo$'
		cat /proc/asound/cards 2> /dev/null | awk '/^ *[0-9]/ { print "snd", $1, $2 }'
		for c in /sys/class/drm/card[0-9]; do echo "$(basename $c) $(basename "$(readlink $c/device/driver)")"; done
		ls /sys/class/bluetooth 2> /dev/null
		for e in /sys/class/input/event*; do echo "$(basename $e) $(cat $e/device/name)"; done
	} | sort
}
check_boot() {
	local n=$1 k fails="" x
	touch /run/l410-keep; echo 0 > /sys/kernel/l410_deadman/timeout 2> /dev/null
	k=$(uname -r)
	[ "$k" = "$(cat $S/kver)" ] || fails="$fails kernel=$k"
	for i in $(seq 1 90); do nmcli -t -f STATE general 2> /dev/null | grep -q '^connected' && break; sleep 1; done
	nmcli -t -f STATE general | grep -q '^connected' || fails="$fails wifi-down"
	x=$(journalctl -k -b --no-pager -o cat | grep -cE "Internal error|Unable to handle|SError|BUG:|WARNING: CPU|Oops|rcu.*stall|soft lockup|hard LOCKUP|blocked for more than|underflow")
	[ "$x" = 0 ] || fails="$fails klog=$x"
	x=$(cat /sys/kernel/debug/devices_deferred 2> /dev/null | wc -l)
	[ "$x" = 0 ] || fails="$fails deferred=$x"
	x=$(journalctl -k -b --no-pager -o cat | grep -ciE "ufshcd.*(error|abort|reset)")
	[ "$x" = 0 ] || fails="$fails ufs-errors=$x"
	names > $S/names.$n
	[ $n = 1 ] || cmp -s $S/names.1 $S/names.$n || fails="$fails names-changed"
	local bt; bt=$(systemd-analyze 2> /dev/null | head -1 | sed 's/^Startup finished in //')
	local rr; rr=$(journalctl -k -b --no-pager -o cat | grep -m1 -ioE 'reboot.?reason[^,]*' | head -1)
	echo "boot $n $(date -Is) $k ${fails:-OK} | $bt | $rr" >> $S/log
	[ -z "$fails" ]
}

case ${1:-} in
start)
	N=${2:?count}
	mkdir -p $S /usr/local/lib/l410-test
	install -m 755 "$(readlink -f "$0")" $SELF
	echo "$N" > $S/count; echo 0 > $S/done; uname -r > $S/kver; : > $S/log; rm -f $S/names.*
	cat > /etc/systemd/system/$UNIT << EOF
[Unit]
Description=L410 reboot cycle (tests/cycle.sh)
After=network-online.target NetworkManager.service
Wants=network-online.target
ConditionPathExists=$S/count

[Service]
Type=oneshot
ExecStart=$SELF boot
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload; systemctl enable $UNIT
	names > $S/names.0
	mark_next && { echo "cycle of $N boots starting"; systemctl reboot; }
	;;
boot)
	d=$(( $(cat $S/done) + 1 )); echo $d > $S/done
	sleep 20	# let the session and WiFi settle
	if ! check_boot $d; then
		echo "cycle stopped at boot $d: $(tail -1 $S/log)" >> $S/log
		systemctl disable $UNIT; rm -f $S/count; exit 0
	fi
	if [ $d -ge "$(cat $S/count)" ]; then
		echo "cycle finished: $d boots OK" >> $S/log
		systemctl disable $UNIT; rm -f $S/count; exit 0
	fi
	mark_next || { echo "cannot write grubenv, stopping" >> $S/log; systemctl disable $UNIT; rm -f $S/count; exit 0; }
	systemctl --no-block reboot
	;;
status)
	echo "done $(cat $S/done 2> /dev/null) of $(cat $S/count 2> /dev/null || echo '(not running)')"; cat $S/log 2> /dev/null
	;;
stop)
	systemctl disable $UNIT 2> /dev/null; rm -f $S/count; echo stopped
	;;
*)
	sed -n '2,13p' "$0"; exit 2 ;;
esac
