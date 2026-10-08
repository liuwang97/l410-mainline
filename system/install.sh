#!/bin/bash
# Configure Debian (forky) for the Huawei Qingyun L410 running the linux-l410 6.18 kernel.
#
#   sudo system/install.sh [--chroot] [--user NAME] [STAGE...]
#
# Without stages, all of them run in the order below. Every stage is idempotent, so rerunning
# the script after an upgrade or on a half-configured system is fine.
#
#   base       locale (zh_CN.UTF-8), Asia/Shanghai, RTC in local time (shared with Kylin),
#              hostname, the desktop user, ssh, Chinese input method
#   desktop    SDDM on Wayland (optional autologin), KWin on GLES, AppArmor, NTP, units that
#              only fail on this machine switched off
#   hardware   keyboard hotkeys (hwdb), WiFi regulatory domain CN, Hi6405 UCM profile,
#              fq_codel, unprivileged ping
#   perf       power modes through tuned-ppd (powersave / balanced / performance), l410-perfd,
#              the KWin hint script, PowerDevil switching by power source
#   sched-ext  scx_lavd started at boot (SCX_DEFAULT=none installs it disabled)
#   mem        zswap + swap file tuning, sysctl, systemd-oomd, memory protection for the session
#   input      libinput with touchpad scroll acceleration, Chromium touchpad scroll fix
#   video      hardware video decoding: Chromium's V4L2 decoder, GStreamer's v4l2codecs
#   mesa       Mesa panfrost with the AFBC upload fix (a patched libgallium next to Debian's)
#   launch     faster app start: expedited RCU, fewer fonts, hostnamectl cache, resident
#              Chromium and System Settings
#   apps       WPS Office and QQ adjustments, only for the ones that are installed
#
# --chroot     inside rootfs/mkrootfs.sh: install files and enable units only; the parts that
#              need the running machine are done again by `system/install.sh` after the first boot
# --user NAME  desktop user (default: the user who called sudo, else the first uid >= 1000)
#
# Stages that use a locally built library (input, mesa, sched-ext, launch, apps) take the
# binary from the release assets when Debian's package version matches the one it was built
# for, and tell you how to rebuild it otherwise (see the README in each directory).
set -e
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
export L410_SYSTEM=$HERE
ALL="base desktop hardware perf sched-ext mem input video mesa launch apps"
STAGES=
while [ $# -gt 0 ]; do
	case $1 in
	--chroot) export L410_CHROOT=1; shift ;;
	--user) export L410_USER=$2; shift 2 ;;
	-h|--help) sed -n '2,32p' "$0"; exit 0 ;;
	-*) echo "unknown option $1" >&2; exit 2 ;;
	*) STAGES="$STAGES $1"; shift ;;
	esac
done
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
. "$HERE/lib.sh"
if [ "$L410_BASE" = 1 ]; then
	ALL="base hardware"
fi
for s in ${STAGES:-$ALL}; do
	case " $ALL " in *" $s "*) ;; *) echo "unknown stage $s (stages: $ALL)" >&2; exit 2 ;; esac
	say "stage $s"
	bash "$HERE/$s/install.sh"
done
if live; then say "done"; else say "done (chroot: run system/install.sh again after the first boot)"; fi
