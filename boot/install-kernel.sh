#!/bin/bash
# Install a kernel bundle built by l410/build.sh (kernel tree) on the L410's Debian.
#
#   sudo boot/install-kernel.sh BUNDLE [--root DIR] [--uuid UUID]
#
#   BUNDLE      directory with Image l410.dtb initrd.img boot.cfg modules.tar.gz kver
#   --root DIR  Debian root mounted somewhere else (from Kylin, or a rootfs being prepared);
#               default /
#   --uuid UUID filesystem UUID of that root, written into boot.cfg (root=UUID=...);
#               default: looked up with findmnt
#
# GRUB's l410 entry (boot/grub-entry.sh) sources /boot/l410/boot.cfg from the Debian root, so a
# new kernel needs no GRUB change. The kernel that was there before moves to /boot/l410.prev;
# to go back, swap the two directories.
set -e
B=
R=/
UUID=
while [ $# -gt 0 ]; do
	case $1 in
	--root) R=$2; shift 2 ;;
	--uuid) UUID=$2; shift 2 ;;
	-h|--help) sed -n '2,16p' "$0"; exit 0 ;;
	-*) echo "unknown option $1" >&2; exit 2 ;;
	*) B=$1; shift ;;
	esac
done
[ -n "$B" ] || { sed -n '2,16p' "$0"; exit 2; }
for f in Image l410.dtb initrd.img boot.cfg kver; do
	[ -e "$B/$f" ] || { echo "$B/$f missing" >&2; exit 1; }
done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
R=$(cd "$R" && pwd)
[ -d "$R/etc" ] && [ -d "$R/usr" ] || { echo "$R does not look like a Debian root" >&2; exit 1; }
KVER=$(cat "$B/kver")
if [ -z "$UUID" ]; then
	UUID=$(findmnt -n -o UUID --target "$R")
	[ -n "$UUID" ] || { echo "cannot find the filesystem UUID of $R; pass --uuid" >&2; exit 1; }
fi

rm -rf "$R/boot/l410.prev"
[ -d "$R/boot/l410" ] && mv "$R/boot/l410" "$R/boot/l410.prev"
install -d "$R/boot/l410"
install -m 644 "$B/Image" "$B/l410.dtb" "$B/initrd.img" "$R/boot/l410/"
sed "s/@ROOT_UUID@/$UUID/" "$B/boot.cfg" > "$R/boot/l410/boot.cfg"
[ -f "$B/config" ] && install -m 644 "$B/config" "$R/boot/l410/config-$KVER"
if [ -f "$B/modules.tar.gz" ]; then
	rm -rf "$R/lib/modules/$KVER"
	# lib is a symlink to usr/lib on Debian
	tar --keep-directory-symlink -xzf "$B/modules.tar.gz" -C "$R/"
	depmod -a -b "$R" "$KVER"
fi
sync
echo "installed $KVER in $R/boot/l410 (root=UUID=$UUID)"
cat "$R/boot/l410/boot.cfg"
