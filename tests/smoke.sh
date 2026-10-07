#!/bin/bash
# L410 integration smoke test: runs on the test kernel (root mode, via harness --script).
# Checks that every merged subsystem is alive; prints PASS/FAIL per item and exits non-zero on failure.
fail=0
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }
chk() { local name=$1; shift; if "$@" > /dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }

echo "kernel: $(uname -r)"
[ "$(nproc)" = 8 ] && ok "cpus 8 online" || bad "cpus online=$(nproc)"
chk "root on the UFS user LUN" sh -c 'findmnt -no SOURCE / | grep -q "^/dev/sdd[0-9]"'
for d in sda sdb sdc; do
	[ "$(cat /sys/block/$d/ro 2>/dev/null)" = 1 ] && ok "$d read-only" || bad "$d not read-only"
done
chk "clock tree registered" sh -c '[ $(ls /sys/kernel/debug/clk 2>/dev/null | wc -l) -gt 400 ]'
chk "regulators registered" sh -c '[ $(ls /sys/class/regulator | wc -l) -gt 10 ]'
chk "rtc0 readable" sh -c '[ -n "$(cat /sys/class/rtc/rtc0/time 2>/dev/null)" ]'
chk "thermal zones" sh -c 'for z in /sys/class/thermal/thermal_zone*/temp; do t=$(cat $z); [ $t -gt 10000 ] && [ $t -lt 90000 ] || exit 1; done'
chk "i2c buses" sh -c '[ $(ls /sys/bus/i2c/devices | grep -c "^i2c-") -ge 4 ]'
# a USB NIC (enx*) that is up with an address, or else a default route over WiFi
if ls -d /sys/class/net/enx* > /dev/null 2>&1 || ! ip -4 route show default | grep -q "dev wl"; then
	chk "usb ethernet up" sh -c 'ip -br -4 addr show | grep -q "^enx.*UP.*[0-9]\.[0-9]"'
else
	chk "network up (WLAN default route, USB NIC not attached)" sh -c 'ip -4 route show default | grep -q "dev wl"'
fi
chk "rtl8168 (pcie) present" sh -c 'lspci -n | grep -q "10ec:8168"'
chk "no deferred probes except known" sh -c '! grep -vE "spi|hi110x|mali|dpe|codec|slimbus|asp" /sys/kernel/debug/devices_deferred | grep -q .'
echo "--- deferred:"; cat /sys/kernel/debug/devices_deferred 2>/dev/null
echo "--- dmesg errors/warnings:"
dmesg --level=err,warn 2>/dev/null | tail -40
n=$(dmesg | grep -cE "Internal error:|Unable to handle kernel|SError Interrupt|BUG: |WARNING: CPU|Oops[: ]|Kernel panic")
[ "$n" = 0 ] && ok "no oops/warn splats" || bad "$n oops/warn splats in dmesg"
exit $fail
