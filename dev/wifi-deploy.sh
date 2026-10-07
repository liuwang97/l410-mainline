#!/bin/bash
# Deploy and boot a test bundle over the home WLAN, where l410-harness.sh (ssh) can't
# reach the machine. Runs in Git Bash on the Windows host (L410_SSH, L410_SSH_KEY, L410_SSH_PORT).
# the L410 must be up on Debian 6.18 or Kylin 2403; on Kylin the Debian root (sdd7, label DEBIAN13)
# is mounted and written instead, never the Kylin root.
#
#   wifi-deploy.sh <bundle dir, e.g. //wsl.localhost/Debian/home/<you>/l410-build/bundle>
#                  [--append "kernel args"] [--no-reboot]
#
# The previous /boot/l410 is kept as /boot/l410.prev. The l410-test GRUB entry sets the
# grubenv fallback (kylin2403), so a crash or deadman reset lands on 2403, which has WiFi.
set -e
B=$1; shift
APPEND=""; REBOOT=1
while [ $# -gt 0 ]; do
	case $1 in
	--append) APPEND=$2; shift 2 ;;
	--no-reboot) REBOOT=0; shift ;;
	*) echo "unknown option $1"; exit 2 ;;
	esac
done
SSH_OPTS=(-i ${L410_SSH_KEY:-$HOME/.ssh/id_ed25519} -o IdentitiesOnly=yes
	  -o ConnectTimeout=30 -o ConnectionAttempts=3 -o ServerAliveInterval=15)
HOST=${L410_SSH:-user@l410}	# ssh destination of the L410
ssh_() { ssh -p ${L410_SSH_PORT:-22} "${SSH_OPTS[@]}" $HOST "$@"; }

for f in Image l410.dtb initrd.img boot.cfg modules.tar.gz kver; do
	[ -e "$B/$f" ] || { echo "missing $B/$f"; exit 1; }
done
KVER=$(cat "$B/kver")
echo "deploying $KVER"
ssh_ 'rm -rf /tmp/l410-bundle && mkdir -p /tmp/l410-bundle'
scp -O -P ${L410_SSH_PORT:-22} "${SSH_OPTS[@]}" "$B"/{Image,l410.dtb,initrd.img,boot.cfg,modules.tar.gz,kver} \
	$HOST:/tmp/l410-bundle/

ssh_ "sudo bash -s" <<EOF
set -e
cd /tmp/l410-bundle
[ -n "$APPEND" ] && sed -i "s|^linux .*|& $APPEND|" boot.cfg
# the l410-test entry boots from the Debian root; on Kylin mount it instead of writing the Kylin root
R=
if [ "\$(findmnt -n -o UUID /)" != $DEB_UUID ]; then
	R=/tmp/l410-debroot
	mkdir -p \$R
	mountpoint -q \$R || mount UUID=$DEB_UUID \$R
fi
rm -rf \$R/boot/l410.prev
[ -d \$R/boot/l410 ] && cp -a \$R/boot/l410 \$R/boot/l410.prev
mkdir -p \$R/boot/l410
cp Image l410.dtb initrd.img boot.cfg \$R/boot/l410/
tar -xzf modules.tar.gz -C \$R/
depmod -a \${R:+-b \$R} "$KVER" 2>/dev/null || true
cat \$R/boot/l410/boot.cfg
mkdir -p /mnt/sysboot
mountpoint -q /mnt/sysboot || mount LABEL=SYSBOOT /mnt/sysboot
if [ -x /usr/local/sbin/grubenv-set ]; then
	/usr/local/sbin/grubenv-set /mnt/sysboot/grub/grubenv next_entry=l410-test
else
	grub-editenv /mnt/sysboot/grub/grubenv set next_entry=l410-test
fi
sync
if [ -n "\$R" ]; then umount \$R; fi
EOF

[ $REBOOT = 1 ] || exit 0
echo "rebooting into $KVER"
ssh_ 'sudo systemctl reboot' || true
sleep 40
for i in $(seq 1 60); do
	if k=$(ssh_ uname -r 2>/dev/null); then
		echo "up after $((40 + i * 5)) s: $k"
		[ "$k" = "$KVER" ] && exit 0
		echo "running $k instead of $KVER (fell back?)"
		exit 1
	fi
	sleep 5
done
echo "no ssh after 6 minutes"
exit 1
