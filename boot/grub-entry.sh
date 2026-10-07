#!/bin/bash
# Add a boot entry for the L410 Debian to the GRUB that came with Kylin.
#
#   sudo boot/grub-entry.sh ROOT_UUID [--default | --once]
#   sudo boot/grub-entry.sh --remove
#
#   ROOT_UUID  filesystem UUID of the Debian root partition (blkid -s UUID -o value /dev/sddN)
#   --default  make it the default entry (grubenv saved_entry)
#   --once     boot it once at the next restart (grubenv next_entry), then the old default again
#
# The L410 boots UEFI -> grubaa64.efi on the ESP -> grub.cfg on the ext4 partition labelled
# SYSBOOT (sdd2). Kylin's grub.cfg ends with the stock 41_custom hook, which sources custom.cfg
# from the same directory, so the entry goes there and survives Kylin's update-grub. It loads
# /boot/l410/boot.cfg from the Debian root (written by boot/install-kernel.sh), which holds the
# kernel, initramfs, device tree and command line.
#
# Works from Kylin (uses grub-editenv) or from the Debian itself (uses boot/grubenv-set).
set -e
ID=l410-debian
BEGIN="### BEGIN l410-debian ###"
END="### END l410-debian ###"
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

UUID= MODE=
while [ $# -gt 0 ]; do
	case $1 in
	--default) MODE=default; shift ;;
	--once) MODE=once; shift ;;
	--remove) MODE=remove; shift ;;
	-h|--help) sed -n '2,17p' "$0"; exit 0 ;;
	-*) echo "unknown option $1" >&2; exit 2 ;;
	*) UUID=$1; shift ;;
	esac
done
[ -n "$UUID" ] || [ "$MODE" = remove ] || { sed -n '2,17p' "$0"; exit 2; }

DEV=$(blkid -L SYSBOOT) || { echo "no partition labelled SYSBOOT" >&2; exit 1; }
MNT=$(findmnt -n -o TARGET --source "$DEV" | head -1)
RESTORE=
if [ -z "$MNT" ]; then
	MNT=$(mktemp -d /tmp/sysboot.XXXX)
	mount "$DEV" "$MNT"
	RESTORE=umount
elif findmnt -n -o OPTIONS --source "$DEV" | head -1 | grep -qw ro; then
	# Kylin mounts it read-only at /boot
	mount -o remount,rw "$MNT"
	RESTORE=ro
fi
cleanup() {
	sync
	case $RESTORE in
	umount) umount "$MNT"; rmdir "$MNT" ;;
	ro) mount -o remount,ro "$MNT" ;;
	esac
}
trap cleanup EXIT
G=$MNT/grub
[ -f "$G/grub.cfg" ] || { echo "$G/grub.cfg not found" >&2; exit 1; }
grep -q custom.cfg "$G/grub.cfg" || echo "warning: $G/grub.cfg does not source custom.cfg" >&2

setenv() {
	if command -v grub-editenv > /dev/null; then
		grub-editenv "$G/grubenv" set "$@"
	else
		python3 "$HERE/grubenv-set" "$G/grubenv" "$@" > /dev/null
	fi
}

C=$G/custom.cfg
[ -f "$C" ] && [ ! -f "$C.orig-l410" ] && cp -a "$C" "$C.orig-l410"
touch "$C"
# drop an earlier copy of the entry
sed -i "/^$BEGIN\$/,/^$END\$/d" "$C"
if [ "$MODE" = remove ]; then
	echo "removed the $ID entry from $C"
	exit 0
fi
cat >> "$C" << EOF
$BEGIN
menuentry 'Debian (Linux 6.18, L410)' --id $ID {
    insmod part_gpt
    insmod ext2
    insmod fdt
    search --no-floppy --fs-uuid --set=root $UUID
    source /boot/l410/boot.cfg
}
$END
EOF
case $MODE in
default) setenv saved_entry=$ID; echo "default entry: $ID" ;;
once) setenv next_entry=$ID; echo "next boot only: $ID" ;;
esac
echo "entry $ID in $C"
