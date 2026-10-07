#!/bin/bash
# Upgrade the test Debian (sdd7) from 13 trixie to testing (forky) to get Plasma 6.7 over the
# home WLAN. Runs in Git Bash on the Windows host, like wifi-deploy.sh. See docs/tuning/desktop.md.
#
#   forky-upgrade.sh preflight          read-only report, change nothing
#   forky-upgrade.sh backup <dir>       tar.zst of the Debian root into <dir> on the L410 (not on sdd7)
#   forky-upgrade.sh backup-local <dir> the same tarball streamed over ssh into <dir> on this host
#   forky-upgrade.sh upgrade            switch apt to forky, full-upgrade in a detached unit, follow the log
#   forky-upgrade.sh reboot             boot l410-test once (fallback kylin2403) and wait for ssh
#   forky-upgrade.sh verify             versions, failed units, WiFi, KWin GL, audio, perf user space
#
# the L410 must be up on the 6.18 Debian. The upgrade runs under systemd-run, so a WiFi drop while
# NetworkManager restarts does not kill dpkg; rerunning "upgrade" only follows the log again.
set -e
SSH_OPTS=(-i ${L410_SSH_KEY:-$HOME/.ssh/id_ed25519} -o IdentitiesOnly=yes
	  -o ConnectTimeout=30 -o ConnectionAttempts=3 -o ServerAliveInterval=15)
HOST=${L410_SSH:-user@l410}	# ssh destination of the L410
DEB_UUID=${DEB_UUID:?set DEB_UUID to the UUID of the Debian root filesystem}
LOG=/var/log/l410-forky-upgrade.log
ssh_() { ssh -p ${L410_SSH_PORT:-22} "${SSH_OPTS[@]}" $HOST "$@"; }

on_debian() {
	[ "$(ssh_ findmnt -n -o UUID /)" = $DEB_UUID ] || { echo "the L410 is not running the sdd7 Debian"; exit 1; }
}

preflight() {
	on_debian
	ssh_ 'sudo bash -s' <<'EOF'
set -u
U=${L410_USER:-$(id -un 1000)}; UID_=$(id -u $U)
echo "== base"; uname -r; . /etc/os-release; echo "$PRETTY_NAME ($(cat /etc/debian_version))"; uptime
echo "== apt sources"
grep -rHv '^\s*\(#\|$\)' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
echo "== holds / pins"; apt-mark showhold; ls /etc/apt/preferences.d/ 2>/dev/null
echo "== boot-related packages (a grub-install onto SYSBOOT would replace Kylin's loader)"
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' 'grub*' 'linux-image*' 'shim*' \
	'systemd-boot*' 'flash-kernel' 'u-boot*' 'initramfs-tools' 'dracut*' 2>/dev/null | grep '^ii' || echo none
findmnt -n -o TARGET,SOURCE,FSTYPE /boot/efi /mnt/sysboot 2>/dev/null
grep -v '^\s*#' /etc/fstab | grep -v '^\s*$'
echo "== not from a Debian archive"
apt list '?installed ?not(?origin(Debian))' 2>/dev/null | tail -n +2
echo "== init.d scripts without a systemd unit"
for f in /etc/init.d/*; do n=${f##*/}
	[ -e /usr/lib/systemd/system/$n.service ] || [ -e /etc/systemd/system/$n.service ] ||
	[ -e /lib/systemd/system/$n.service ] || echo "$n"
done
echo "== desktop stack now"
dpkg-query -W -f='${Package} ${Version}\n' plasma-workspace kwin-wayland libqt6core6t64 libgl1-mesa-dri \
	sddm network-manager wpasupplicant pipewire wireplumber chromium firefox-esr tuned tuned-ppd 2>/dev/null
echo "== disk"; df -h / /var /home 2>/dev/null | sort -u
lsblk -o NAME,SIZE,FSTYPE,LABEL,FSAVAIL,MOUNTPOINT /dev/sdd 2>/dev/null
du -sxh / 2>/dev/null | tail -1
echo "== health"; systemctl --failed --no-legend; dpkg --audit
echo "== guards (deadman 0 and /run/l410-keep needed before a long job)"
cat /sys/kernel/l410_deadman/timeout 2>/dev/null; ls /run/l410-keep 2>/dev/null
echo "== grubenv"; M=$(mktemp -d); mount -o ro LABEL=SYSBOOT $M 2>/dev/null &&
	{ tr -d '#' < $M/grub/grubenv | grep -v '^$'; umount $M; }; rmdir $M
echo "== session"; loginctl list-sessions --no-legend; systemctl is-active sddm
echo "== network"; nmcli -t -f NAME,TYPE,DEVICE,ACTIVE con show 2>/dev/null
if [ -S /run/user/$UID_/bus ]; then
	echo "== display / KWin"
	su $U -c "XDG_RUNTIME_DIR=/run/user/$UID_ kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | head -8"
	su $U -c "XDG_RUNTIME_DIR=/run/user/$UID_ DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_/bus \
		qdbus6 org.kde.KWin /KWin org.kde.KWin.supportInformation 2>/dev/null" |
		grep -iE '^(OpenGL|GLSL|Driver|GPU class|Compositing Type|OpenGL (vendor|renderer|version|platform))|Platform' | head -12
fi
EOF
}

backup() {
	[ -n "${1:-}" ] || { echo "usage: $0 backup <dir on the L410 outside sdd7>"; exit 2; }
	on_debian
	ssh_ "sudo bash -s -- '$1'" <<'EOF'
set -e
T=$1
[ -d "$T" ] || { echo "$T does not exist"; exit 1; }
[ "$(findmnt -n -o UUID --target "$T")" != $DEB_UUID ] ||
	{ echo "$T is on sdd7 itself"; exit 1; }
F=$T/debian13-sdd7-$(date +%Y%m%d-%H%M).tar.zst
# restore from Kylin: mkfs is not needed, wipe the mounted root and
#   zstd -dc F | tar -xpf - --numeric-owner --xattrs --acls -C <mounted sdd7>
tar --one-file-system --numeric-owner --xattrs --acls -cpf - \
	--exclude=./tmp/* --exclude=./var/tmp/* --exclude=./var/cache/apt/archives/*.deb \
	--exclude=./home/*/.cache/* -C / . 2>/tmp/l410-backup.err | zstd -T0 -3 -q -o "$F"
grep -v 'socket ignored' /tmp/l410-backup.err | tail -5 || true
ls -lh "$F"
zstd -t -q "$F" && echo "backup ok: $F"
EOF
}

backup_local() {
	# stream the tarball to this Windows host: sdd1-sdd6 belong to Kylin and are not written
	[ -n "${1:-}" ] || { echo "usage: $0 backup-local <local dir>"; exit 2; }
	on_debian
	mkdir -p "$1"
	local F="$1/debian-sdd7-$(date +%Y%m%d-%H%M).tar.zst"
	ssh_ 'command -v zstd > /dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q zstd > /dev/null'
	ssh_ 'sudo tar --one-file-system --numeric-owner --xattrs --acls -cpf - \
		--exclude=./tmp/* --exclude=./var/tmp/* --exclude=./var/cache/apt/archives/*.deb \
		--exclude=./home/*/.cache/* --exclude=./swapfile -C / . 2>/tmp/l410-backup.err | zstd -T0 -3 -q -c' > "$F"
	ssh_ 'grep -v "socket ignored" /tmp/l410-backup.err | tail -5' || true
	ls -l "$F"
	[ -s "$F" ] || { echo "backup is empty"; exit 1; }
	# restore from Kylin: wipe the mounted sdd7 root, then
	#   zstd -dc F | sudo tar -xpf - --numeric-owner --xattrs --acls -C <mounted sdd7>
	# Git Bash has no zstd: test the archive from WSL (/e/x -> /mnt/e/x)
	local wf; wf=$(echo "$F" | sed -E 's#^/([a-zA-Z])/#/mnt/\L\1/#')
	if command -v zstd > /dev/null; then zstd -t -q "$F"; else MSYS_NO_PATHCONV=1 wsl -d Debian -- zstd -t -q "$wf"; fi &&
		echo "backup ok: $F"
}

upgrade() {
	on_debian
	ssh_ 'sudo bash -s' <<'EOF'
set -e
if systemctl is-active -q l410-forky-upgrade; then echo "already running, following the log"; exit 0; fi
mkdir -p /var/tmp/l410-forky
cat > /var/tmp/l410-forky/upgrade.sh <<'SCRIPT'
set -eu
exec >> /var/log/l410-forky-upgrade.log 2>&1
echo "=== start $(date -Is)"
# a long dpkg run must not be cut by the deadman watchdog or the 15-minute auto-revert
echo 0 > /sys/kernel/l410_deadman/timeout 2>/dev/null || true
touch /run/l410-keep
export DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=l \
	NEEDRESTART_SUSPEND=1 UCF_FORCE_CONFFOLD=1 LANG=C.UTF-8
O="-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
# never let a grub postinst reach Kylin's EFI partition
for m in /boot/efi /mnt/sysboot; do mountpoint -q $m && umount $m && echo "unmounted $m"; done
G=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'grub*' 'shim*' 'flash-kernel' 2>/dev/null |
	awk '/^ii/ {print $2}')
[ -n "$G" ] && apt-mark hold $G
# sources: trixie -> forky; backports have no forky counterpart
mkdir -p /var/tmp/l410-forky/apt.orig
cp -a /etc/apt/sources.list /etc/apt/sources.list.d /var/tmp/l410-forky/apt.orig/ 2>/dev/null || true
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
	[ -f "$f" ] || continue
	sed -i -E '/trixie-backports/d; s/\btrixie\b/forky/g' "$f"
done
grep -rh 'forky' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
if ! apt-get update -q; then
	# testing may have no -updates suite on this mirror
	sed -i '/forky-updates/d' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
	sed -i 's/ forky-updates//' /etc/apt/sources.list.d/*.sources 2>/dev/null || true
	apt-get update -q
fi
echo "=== minimal upgrade $(date -Is)"
apt-get $O upgrade --without-new-pkgs
echo "=== full upgrade $(date -Is)"
apt-get $O full-upgrade
dpkg --configure -a
dpkg --audit
echo "=== versions"
dpkg-query -W -f='${Package} ${Version}\n' plasma-workspace kwin-wayland libqt6core6t64 libgl1-mesa-dri \
	systemd network-manager wpasupplicant pipewire wireplumber sddm
echo "=== done $(date -Is)"
SCRIPT
systemctl stop sddm 2>/dev/null || true
: > /var/log/l410-forky-upgrade.log
systemd-run --unit=l410-forky-upgrade --collect -p Type=exec bash /var/tmp/l410-forky/upgrade.sh
echo started
EOF
	follow
}

follow() {
	# ssh may drop while NetworkManager is upgraded; keep reconnecting until the unit is gone
	local n=0
	while :; do
		if st=$(ssh_ "sudo tail -n 4 $LOG; systemctl is-active l410-forky-upgrade || true" 2>/dev/null); then
			n=0
			echo "---- $(date +%T)"; echo "$st"
			case $(echo "$st" | tail -1) in active|activating) ;; *) break ;; esac
		else
			n=$((n + 1)); echo "---- $(date +%T) no ssh ($n)"
			[ $n -lt 40 ] || { echo "no ssh for 20 minutes"; exit 1; }
		fi
		sleep 30
	done
	ssh_ "sudo grep -E '^(===|E:|W: .*forky)|dpkg: error' $LOG | tail -30; sudo tail -n 20 $LOG"
}

reboot_() {
	on_debian
	ssh_ 'sudo bash -s' <<'EOF'
set -e
mkdir -p /mnt/sysboot
mountpoint -q /mnt/sysboot || mount LABEL=SYSBOOT /mnt/sysboot
/usr/local/sbin/grubenv-set /mnt/sysboot/grub/grubenv next_entry=l410-test l410_fallback=kylin2403
tr -d '#' < /mnt/sysboot/grub/grubenv | grep -v '^$'
sync; umount /mnt/sysboot
EOF
	ssh_ 'sudo systemctl reboot' || true
	sleep 40
	for i in $(seq 1 60); do
		if ssh_ 'uname -r; . /etc/os-release; echo $PRETTY_NAME' 2>/dev/null; then
			on_debian && exit 0
		fi
		sleep 5
	done
	echo "no ssh after 6 minutes (a failed boot falls back to Kylin 2403)"
	exit 1
}

verify() {
	on_debian
	ssh_ 'sudo bash -s' <<'EOF'
U=${L410_USER:-$(id -un 1000)}; UID_=$(id -u $U)
echo 0 > /sys/kernel/l410_deadman/timeout 2>/dev/null; touch /run/l410-keep
. /etc/os-release; echo "$PRETTY_NAME ($(cat /etc/debian_version)), kernel $(uname -r)"
dpkg-query -W -f='${Package} ${Version}\n' plasma-workspace kwin-wayland libqt6core6t64 libgl1-mesa-dri \
	systemd network-manager wpasupplicant pipewire wireplumber sddm chromium tuned tuned-ppd
echo "== apt"; apt-get -s full-upgrade 2>/dev/null | grep -E '^[0-9]+ upgraded'; dpkg --audit
echo "== failed units"; systemctl --failed --no-legend
echo "== network"; nmcli -t -f DEVICE,STATE,CONNECTION dev | grep wlan; ping -c 2 -W 2 deb.debian.org | tail -1
echo "== perf user space"; tuned-adm active 2>&1; powerprofilesctl get 2>&1
systemctl is-active sddm || systemctl start sddm
for i in $(seq 1 20); do [ -S /run/user/$UID_/bus ] && pgrep -u $U -x plasmashell > /dev/null && break; sleep 3; done
E="XDG_RUNTIME_DIR=/run/user/$UID_ DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_/bus"
echo "== session"; loginctl list-sessions --no-legend; pgrep -u $U -a -x 'kwin_wayland|plasmashell|pipewire|wireplumber'
su $U -c "$E systemctl --user --failed --no-legend; $E systemctl --user is-active l410-perfd"
echo "== KWin"; su $U -c "$E qdbus6 org.kde.KWin /KWin org.kde.KWin.supportInformation" |
	grep -iE '^(KWin version|Qt Version|OpenGL|GLSL|Driver|GPU class|Compositing Type|Platform)' | head -14
echo "== backlight"; cat /sys/class/backlight/*/brightness /sys/class/backlight/*/max_brightness
echo "== audio"; su $U -c "$E wpctl status 2>/dev/null" | sed -n '/Sinks:/,/Sources:/p' | head -8
echo "== udmabuf"; ls -l /dev/udmabuf 2>&1
echo "== GPU faults / job timeouts"; dmesg | grep -iE 'panfrost.*(fault|timeout|reset)' | tail -5
echo "== errors this boot"; journalctl -b -p err --no-pager -q | tail -15
EOF
}

case ${1:-} in
preflight) preflight ;;
backup) backup "${2:-}" ;;
backup-local) backup_local "${2:-}" ;;
upgrade) upgrade ;;
follow) follow ;;
reboot) reboot_ ;;
verify) verify ;;
*) sed -n '2,14p' "$0"; exit 2 ;;
esac
