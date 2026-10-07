#!/bin/bash
# mem: desktop memory tuning (docs/tuning/memory.md).
#
#   system/mem/install.sh [all|swap|l2|oomd|protect|iosched]   install one layer or all (idempotent)
#   system/mem/install.sh revert                               undo everything (swapfile removed)
#
# Layers: swap = 8 GB swapfile behind zswap; l2 = sysctl + mem-tune.service; oomd =
# systemd-oomd; protect = user.slice/user@/session.slice memory protection; iosched = udev rule.
# The kernel side (zswap, multi-gen LRU, THP madvise) is l410/configs/98-memory.config.
set -e
: "${L410_SYSTEM:=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
. "$L410_SYSTEM/lib.sh"
S=$L410_SYSTEM/mem
SWAP=/swapfile
SIZE=${SWAP_SIZE:-8G}

swap() {
	# the image builder has no swap; rootfs/deploy.sh creates /swapfile on the machine
	live || return 0
	if swapon --show=NAME --noheadings | grep -q '^/dev/zram'; then
		echo "zram swap is active: disable its generator first (zram and a disk swap invert the LRU)" >&2
		exit 1
	fi
	if [ ! -f $SWAP ]; then
		case $(findmnt -no FSTYPE /) in
		btrfs) btrfs filesystem mkswapfile --size $SIZE $SWAP ;;
		*) fallocate -l $SIZE $SWAP; chmod 600 $SWAP; mkswap -q $SWAP ;;
		esac
	fi
	chmod 600 $SWAP
	grep -q "^$SWAP " /etc/fstab || echo "$SWAP none swap defaults 0 0" >> /etc/fstab
	swapon --show=NAME --noheadings | grep -qx $SWAP || swapon $SWAP
}

l2() {
	install -m 755 $S/mem-tune /usr/local/sbin/mem-tune
	install -m 644 $S/systemd/mem-tune.service /etc/systemd/system/mem-tune.service
	install -m 644 $S/90-l410-memory.conf /etc/sysctl.d/90-l410-memory.conf
	systemctl enable mem-tune.service
	live || return 0
	systemctl daemon-reload
	systemctl restart mem-tune.service
	sysctl -q -p /etc/sysctl.d/90-l410-memory.conf
}

oomd() {
	inst systemd-oomd
	install -d /etc/systemd/system/user@.service.d /etc/systemd/system/-.slice.d /etc/systemd/oomd.conf.d
	install -m 644 $S/systemd/user@.service.d-l410-oomd.conf /etc/systemd/system/user@.service.d/l410-oomd.conf
	install -m 644 $S/systemd/-.slice.d-l410-oomd.conf /etc/systemd/system/-.slice.d/l410-oomd.conf
	install -m 644 $S/systemd/oomd.conf.d-l410.conf /etc/systemd/oomd.conf.d/l410.conf
	install -m 644 $S/systemd/l410-oomd-resync@.service $S/systemd/l410-oomd-resync@.timer /etc/systemd/system/
	systemctl enable systemd-oomd.service systemd-oomd.socket 2> /dev/null || systemctl enable systemd-oomd.service
	live || return 0
	systemctl daemon-reload
	systemctl restart systemd-oomd.service
	# PID 1 hands its ManagedOOM cgroup list to oomd on reload; without this a freshly
	# restarted oomd watches nothing until the next reload or boot (oomctl shows no cgroups)
	systemctl daemon-reload
}

protect() {
	install -d /etc/systemd/system/user.slice.d /etc/systemd/system/user@.service.d /etc/systemd/user/session.slice.d
	install -m 644 $S/systemd/user.slice.d-l410-mem.conf /etc/systemd/system/user.slice.d/l410-mem.conf
	install -m 644 $S/systemd/user@.service.d-l410-mem.conf /etc/systemd/system/user@.service.d/l410-mem.conf
	install -m 644 $S/systemd/session.slice.d-l410-mem.conf /etc/systemd/user/session.slice.d/l410-mem.conf
	live || return 0
	systemctl daemon-reload
	# apply to the running user managers without restarting them
	for u in $(loginctl list-users --no-legend | awk '{ print $1 }'); do
		systemctl set-property --runtime user@$u.service MemoryLow=75% MemoryMin=25% 2> /dev/null || true
		[ -S /run/user/$u/bus ] && su - "$(id -nu $u)" -c "XDG_RUNTIME_DIR=/run/user/$u systemctl --user daemon-reload" || true
	done
}

iosched() {
	install -m 644 $S/60-l410-iosched.rules /etc/udev/rules.d/60-l410-iosched.rules
	live || return 0
	udevadm control --reload
	udevadm trigger --action=change --subsystem-match=block
}

revert() {
	swapoff $SWAP 2> /dev/null || true
	sed -i "\#^$SWAP #d" /etc/fstab
	rm -f $SWAP
	systemctl disable --now mem-tune.service 2> /dev/null || true
	rm -f /usr/local/sbin/mem-tune /etc/systemd/system/mem-tune.service /etc/sysctl.d/90-l410-memory.conf \
		/etc/systemd/system/user@.service.d/l410-oomd.conf /etc/systemd/system/-.slice.d/l410-oomd.conf \
		/etc/systemd/oomd.conf.d/l410.conf /etc/systemd/system/l410-oomd-resync@.service \
		/etc/systemd/system/l410-oomd-resync@.timer \
		/etc/systemd/system/user.slice.d/l410-mem.conf \
		/etc/systemd/system/user@.service.d/l410-mem.conf /etc/systemd/user/session.slice.d/l410-mem.conf \
		/etc/udev/rules.d/60-l410-iosched.rules
	systemctl daemon-reload
	echo "reverted; sysctl and sysfs values return to the kernel defaults at the next boot"
}

case ${1:-all} in
all) swap; l2; oomd; protect; iosched ;;
swap|l2|oomd|protect|iosched|revert) $1 ;;
*) echo "usage: $0 [all|swap|l2|oomd|protect|iosched|revert]" >&2; exit 2 ;;
esac
echo "mem: ${1:-all} done"
