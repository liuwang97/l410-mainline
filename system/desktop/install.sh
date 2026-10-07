#!/bin/bash
# desktop: KDE Plasma on Wayland through SDDM, and the services around it.
#
#   SDDM          Wayland greeter run by KWin; L410_AUTOLOGIN=1 logs the desktop user straight
#                 into Plasma (/etc/sddm.conf.d/20-autologin.conf)
#   time          systemd-timesyncd with NTP; the RTC stays in local time (system/base)
#   AppArmor      Debian's profiles (the kernel enables the LSM, l410/configs/97-security-net.config)
#   units         smartd off (UFS has no SMART), networkd-wait-online off (NetworkManager is used)
set -e
: "${L410_SYSTEM:=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
. "$L410_SYSTEM/lib.sh"
U=$(l410_user)

install -d /etc/sddm.conf.d
cat > /etc/sddm.conf.d/10-wayland.conf << 'C'
[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Wayland]
CompositorCommand=kwin_wayland --no-lockscreen --no-global-shortcuts --locale1
C
if [ "$L410_AUTOLOGIN" = 1 ]; then
	printf '[Autologin]\nUser=%s\nSession=plasma\n' "$U" > /etc/sddm.conf.d/20-autologin.conf
fi
systemctl set-default graphical.target
systemctl enable sddm.service

inst systemd-timesyncd
enable_now systemd-timesyncd.service
live && timedatectl set-ntp true || true

inst apparmor apparmor-utils
enable_now apparmor.service

for u in smartmontools.service smartd.service systemd-networkd-wait-online.service; do
	systemctl list-unit-files "$u" --no-legend 2> /dev/null | grep -q . && systemctl disable "$u" 2> /dev/null || true
done
live && systemctl reset-failed || true
al=; [ "$L410_AUTOLOGIN" = 1 ] && al=", autologin $U"
echo "desktop: SDDM (Wayland$al), NTP, AppArmor"
