#!/bin/bash
# sched-ext: run the LAVD sched_ext scheduler from boot (docs/tuning/sched-ext.md).
#
# scx_lavd and scx_bpfland come from scx v1.1.3 with patches/ applied (build-cross.sh on a PC or
# build-native.sh on the L410). If /usr/local/bin has no scx_lavd yet, the prebuilt pair from the
# release is installed. scx-run starts the scheduler with the options of the current power mode
# and keeps KWin's real-time threads clamped while it runs; scx-bpfland is installed but not
# enabled. SCX_DEFAULT=none installs scx-lavd disabled (EEVDF/EAS only).
set -e
: "${L410_SYSTEM:=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
. "$L410_SYSTEM/lib.sh"
S=$L410_SYSTEM/sched-ext
inst libelf1t64 zlib1g
for b in scx_lavd scx_bpfland; do
	[ -x /usr/local/bin/$b ] && continue
	fetch_asset $b /usr/local/bin/$b && chmod 755 /usr/local/bin/$b ||
		echo "warning: no $b; build it with $S/build-cross.sh or build-native.sh" >&2
done
install -d /usr/local/lib/l410-perf
install -m 755 $S/scx-run $S/scx-kwin-uclamp /usr/local/lib/l410-perf/
install -m 644 $S/scx-lavd.service $S/scx-bpfland.service /etc/systemd/system/
live && systemctl daemon-reload
systemctl disable scx-bpfland.service 2> /dev/null || true
if [ "${SCX_DEFAULT:-lavd}" = lavd ]; then
	systemctl enable scx-lavd.service
	echo "sched-ext: scx-lavd enabled at boot"
else
	systemctl disable scx-lavd.service 2> /dev/null || true
	echo "sched-ext: installed, not enabled (systemctl start scx-lavd)"
fi
