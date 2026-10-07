#!/bin/bash
# Put the Debian root filesystem (rootfs/mkrootfs.sh) and a kernel bundle on an L410.
# Run as root on the L410 itself, under the factory Kylin (or any Linux booted on it).
#
#   sudo rootfs/deploy.sh --part /dev/sddN --rootfs l410-debian.tar.xz --kernel BUNDLE
#                         [--format] [--firmware-from DIR] [--swap 8G] [--default]
#
#   --part DEV           empty partition for Debian on the UFS (sdd), at least 32 GB; never one
#                        of sdd1-sdd3 (ESP, SYSBOOT, Kylin root)
#   --rootfs FILE        tarball from rootfs/mkrootfs.sh
#   --kernel DIR         kernel bundle from l410/build.sh in the kernel tree
#   --format             mkfs.ext4 the partition first (label DEBIAN); without it the
#                        partition must already hold an empty ext4 filesystem
#   --firmware-from DIR  root of a Kylin system to copy the vendor firmware from (default /,
#                        the running Kylin); see rootfs/firmware.list
#   --swap SIZE          swap file size, 0 for none (default 8G; the memory tuning in
#                        system/mem expects zswap in front of a disk swap)
#   --default            make Debian the default GRUB entry; otherwise it boots once
#                        (next_entry) and Kylin stays the default
set -e
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
TOP=$(dirname "$HERE")
PART= TARBALL= KERNEL= FORMAT=0 FWROOT=/ SWAP=8G DEFAULT=0
usage() { sed -n '2,24p' "$0"; exit 2; }
while [ $# -gt 0 ]; do
	case $1 in
	--part) PART=$2; shift 2 ;;
	--rootfs) TARBALL=$2; shift 2 ;;
	--kernel) KERNEL=$2; shift 2 ;;
	--format) FORMAT=1; shift ;;
	--firmware-from) FWROOT=$2; shift 2 ;;
	--swap) SWAP=$2; shift 2 ;;
	--default) DEFAULT=1; shift ;;
	-h|--help) usage ;;
	*) echo "unknown option $1" >&2; usage ;;
	esac
done
[ -n "$PART" ] && [ -f "$TARBALL" ] && [ -d "$KERNEL" ] || usage
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -b "$PART" ] || { echo "$PART is not a block device" >&2; exit 1; }

# refuse the partitions the machine needs to boot Kylin, and the firmware LUNs
case $(basename "$PART") in
sdd[1-3]|sda*|sdb*|sdc*) echo "refusing $PART: ESP, SYSBOOT, Kylin root or a firmware LUN" >&2; exit 1 ;;
esac
findmnt -n --source "$PART" > /dev/null && { echo "$PART is mounted" >&2; exit 1; }
SIZE=$(blockdev --getsize64 "$PART")
[ "$SIZE" -ge $((30 * 1024 * 1024 * 1024)) ] || { echo "$PART is smaller than 30 GiB" >&2; exit 1; }

if [ $FORMAT = 1 ]; then
	echo "formatting $PART ($((SIZE >> 30)) GiB), everything on it is lost"
	mkfs.ext4 -F -q -L DEBIAN "$PART"
fi
[ "$(blkid -s TYPE -o value "$PART")" = ext4 ] || { echo "$PART has no ext4 filesystem (use --format)" >&2; exit 1; }
UUID=$(blkid -s UUID -o value "$PART")

M=$(mktemp -d /tmp/l410-debian.XXXX)
mount "$PART" "$M"
trap 'sync; umount "$M" 2> /dev/null; rmdir "$M" 2> /dev/null' EXIT
if [ -n "$(ls -A "$M" | grep -v '^lost+found$')" ]; then
	echo "$PART is not empty (use --format to wipe it)" >&2
	exit 1
fi

echo "unpacking $TARBALL"
tar --numeric-owner --xattrs --xattrs-include='*' -xpf "$TARBALL" -C "$M"
echo "UUID=$UUID / ext4 errors=remount-ro,relatime 0 1" > "$M/etc/fstab"

# vendor firmware the 6.18 drivers load (WiFi/Bluetooth); not redistributable, so it comes
# from the Kylin on the same machine
n=0
while read -r f _; do
	case $f in ''|'#'*) continue ;; esac
	if [ -e "$FWROOT/$f" ]; then
		mkdir -p "$M/$(dirname "$f")"
		cp -a "$FWROOT/$f" "$M/$(dirname "$f")/"
		n=$((n + 1))
	else
		echo "warning: $FWROOT/$f not found: WiFi/Bluetooth will not start" >&2
	fi
done < "$HERE/firmware.list"
echo "copied $n firmware entries from $FWROOT"

if [ "$SWAP" != 0 ]; then
	fallocate -l "$SWAP" "$M/swapfile"
	chmod 600 "$M/swapfile"
	mkswap -q "$M/swapfile"
	echo "/swapfile none swap defaults 0 0" >> "$M/etc/fstab"
fi

"$TOP/boot/install-kernel.sh" "$KERNEL" --root "$M" --uuid "$UUID"
if [ $DEFAULT = 1 ]; then
	"$TOP/boot/grub-entry.sh" "$UUID" --default
else
	"$TOP/boot/grub-entry.sh" "$UUID" --once
fi
echo "done: Debian on $PART (UUID $UUID); reboot to start it"
