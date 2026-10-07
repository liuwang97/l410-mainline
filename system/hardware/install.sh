#!/bin/bash
# hardware: what the L410's devices need from user space on top of the kernel.
#
#   l410-watchdog-off       stops the AP watchdog WDT0 the firmware leaves running (else panic
#                           after about 60 s)
#   60-l410-ufs-fw-ro.rules the three UFS LUNs with the boot firmware read-only, hidden from udisks
#   61-l410-keyboard.hwdb   F1-F10 hotkeys: the EC sends them as reserved keyboard usages
#                           0xA5-0xAF, which mainline maps to KEY_UNKNOWN (docs/hardware/laptop.md)
#   regulatory.db           cfg80211 only trusts the upstream-signed database; with Debian's
#                           signature it stays in the world domain 00 (fewer channels, lower power)
#   cfg80211 CN             country code for the Hi1103 WiFi
#   ucm2/conf.d/hi6405      ALSA UCM profile for the Hi6405 card: speaker, headphones, mics
#   90-l410-net.conf        fq_codel as default qdisc, unprivileged ping
set -e
: "${L410_SYSTEM:=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
. "$L410_SYSTEM/lib.sh"
D=$L410_SYSTEM/hardware

install -m 644 "$D/l410-watchdog-off.service" /etc/systemd/system/l410-watchdog-off.service
systemctl enable l410-watchdog-off.service
install -D -m 644 "$D/60-l410-ufs-fw-ro.rules" /etc/udev/rules.d/60-l410-ufs-fw-ro.rules
install -D -m 644 "$D/61-l410-keyboard.hwdb" /etc/udev/hwdb.d/61-l410-keyboard.hwdb
systemd-hwdb update
live && udevadm trigger --action=change --subsystem-match=input || true

inst wireless-regdb iw
update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream
echo "options cfg80211 ieee80211_regdom=CN" > /etc/modprobe.d/l410-cfg80211.conf
live && { iw reg reload 2> /dev/null; iw reg set CN; } || true

inst alsa-ucm-conf alsa-utils
install -d /usr/share/alsa/ucm2/conf.d/hi6405
install -m 644 "$D"/ucm2/conf.d/hi6405/*.conf /usr/share/alsa/ucm2/conf.d/hi6405/

install -m 644 "$D/90-l410-net.conf" /etc/sysctl.d/90-l410-net.conf
live && sysctl -q -p /etc/sysctl.d/90-l410-net.conf || true
echo "hardware: hotkeys, regdb CN, UCM hi6405, fq_codel"
