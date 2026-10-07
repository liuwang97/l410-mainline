#!/bin/bash
# base: language, time, host name, the desktop user, ssh, input method.
#
# The RTC stays in local time because Kylin, which shares the machine, keeps it that way; with
# UTC in the RTC every switch between the two systems moves the clock by 8 hours.
set -e
: "${L410_SYSTEM:=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
. "$L410_SYSTEM/lib.sh"

inst locales tzdata sudo openssh-server ca-certificates
sed -i 's/^# *\(zh_CN.UTF-8 UTF-8\)/\1/; s/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen > /dev/null
update-locale LANG=zh_CN.UTF-8
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo Asia/Shanghai > /etc/timezone
printf '0.0 0 0.0\n0\nLOCAL\n' > /etc/adjtime

if [ -n "$L410_HOSTNAME" ]; then
	echo "$L410_HOSTNAME" > /etc/hostname
	printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n::1\tlocalhost ip6-localhost ip6-loopback\n' \
		"$L410_HOSTNAME" > /etc/hosts
fi

U=$(l410_user)
[ -n "$U" ] || { echo "no desktop user: pass --user NAME" >&2; exit 1; }
if ! id "$U" > /dev/null 2>&1; then
	useradd -m -s /bin/bash -c "$U" "$U"
	[ -n "$L410_PASSWORD" ] || { passwd -l "$U" > /dev/null; echo "user $U created without a password: run passwd $U" >&2; }
fi
[ -z "$L410_PASSWORD" ] || echo "$U:$L410_PASSWORD" | chpasswd
for g in sudo audio video render input netdev bluetooth plugdev lpadmin; do
	getent group $g > /dev/null && usermod -aG $g "$U"
done
H=$(getent passwd "$U" | cut -d: -f6)
if [ -f /opt/l410/authorized_keys ]; then
	install -d -m 700 -o "$U" -g "$U" "$H/.ssh"
	install -m 600 -o "$U" -g "$U" /opt/l410/authorized_keys "$H/.ssh/authorized_keys"
fi
enable_now ssh.service

# keyboard layout of the console and X11 apps; fcitx5 for Chinese input under Plasma
cat > /etc/default/keyboard << 'K'
XKBMODEL="pc105"
XKBLAYOUT="cn"
XKBVARIANT=""
XKBOPTIONS="lv3:ralt_switch"
BACKSPACE="guess"
K
if [ "$L410_BASE" != 1 ]; then
	inst fcitx5 fcitx5-chinese-addons
	grep -q '^QT_IM_MODULE=' /etc/environment || printf '%s\n' QT_IM_MODULE=fcitx GTK_IM_MODULE=fcitx XMODIFIERS=@im=fcitx >> /etc/environment
fi
echo "base: user $U, $(cat /etc/hostname), LANG=zh_CN.UTF-8, RTC local"
