#!/bin/bash
# T2 power: WSL side of the cpuidle/cpufreq soak (harness --host-script).
#   l410-harness.sh test <bundle> --name power-soak \
#       --host-script dev/bringup/power-soak-host.sh
# Runs tests/power-soak.sh on the L410 (as root) and meanwhile moves ~40 MB over the USB
# network every ~15 s, so the idle-state residency is regularly broken by network and USB
# interrupts. Exit code = soak failures, +1 if the L410 stopped answering.
# POWER_SOAK_SECS overrides the soak length (default 1800 s).

SSHO=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3)
DUR=${POWER_SOAK_SECS:-1800}
SOAK=$(dirname "$(readlink -f "$0")")/power-soak.sh
OUT=$(mktemp)

ssh "${SSHO[@]}" "$L410_HOST" "sudo bash -s $DUR" < "$SOAK" > "$OUT" 2>&1 &
pid=$!

bursts=0; failed=0; mb=0
while kill -0 $pid 2>/dev/null; do
	sleep 15
	kill -0 $pid 2>/dev/null || break
	# L410 -> host, then host -> L410
	n=$(timeout 60 ssh "${SSHO[@]}" "$L410_HOST" 'head -c 20000000 /dev/zero' 2>/dev/null | wc -c)
	if head -c 20000000 /dev/zero | timeout 60 ssh "${SSHO[@]}" "$L410_HOST" 'cat > /dev/null' 2> /dev/null &&
	   [ "$n" = 20000000 ]; then
		bursts=$((bursts + 1)); mb=$((mb + 40))
	else
		failed=$((failed + 1))
	fi
done
wait $pid
rc=$?

cat "$OUT"
rm -f "$OUT"
echo "INFO network: $bursts bursts ok (${mb} MB), $failed failed"
if [ $rc = 255 ]; then
	echo "FAIL soak: lost the ssh connection to the L410 (hang, reboot or network loss)"
	rc=1
fi
[ $failed -gt 2 ] && { echo "FAIL network: $failed failed transfers"; rc=$((rc + 1)); }
exit $rc
