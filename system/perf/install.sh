#!/bin/bash
# perf: the three power modes and the per-user performance hints (docs/tuning/perf-power.md).
#
# tuned-ppd stands in for power-profiles-daemon, so Plasma's battery applet and PowerDevil switch
# between l410-powersave, l410-balanced and l410-performance. Each tuned profile runs
# profile.sh, which sets the kernel knobs (schedutil rate limit, PELT half-life, Panfrost
# boosts, DDR governor, UFS auto-hibern8, WiFi power save) and /sys/kernel/l410_perf/mode.
# l410-perfd (user service) gives KWin and the focused app their CPU clamps and starts the
# launch boost; the KWin script tells it which window is in front. PowerDevil picks the mode
# by power source: plugged in performance, battery balanced, low battery power saver.
set -e
: "${L410_SYSTEM:=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
. "$L410_SYSTEM/lib.sh"
S=$L410_SYSTEM/perf
L=/usr/local/lib/l410-perf
U=$(l410_user)

# tuned-ppd provides (and replaces) power-profiles-daemon
inst tuned tuned-ppd python3-dbus python3-gi libkf6config-bin	# kwriteconfig6
install -d $L
install -m 755 $S/profile.sh $S/l410-perfd $L/
# l410-perfd writes /sys/kernel/l410_perf/launch; profile.sh gives that file to group l410
getent group l410 > /dev/null || groupadd -r l410
[ -n "$U" ] && usermod -aG l410 "$U"

for m in powersave balanced performance; do
	install -d /etc/tuned/profiles/l410-$m
	install -m 644 $S/tuned/l410-$m/tuned.conf /etc/tuned/profiles/l410-$m/
	install -m 755 $S/tuned/l410-$m/script.sh /etc/tuned/profiles/l410-$m/
done
install -m 644 $S/tuned/ppd.conf /etc/tuned/ppd.conf
sed -i 's/^#\? *dynamic_tuning *=.*/dynamic_tuning = 0/' /etc/tuned/tuned-main.conf

# cgroups: the ancestors let cpu.uclamp.min through; user units get the cpu controller
install -D -m 644 $S/systemd/user@.service.d-l410-uclamp.conf /etc/systemd/system/user@.service.d/l410-uclamp.conf
for u in app-.scope app-.service plasma-kwin_wayland.service; do
	install -D -m 644 $S/systemd/$u.d-l410-cpu.conf /etc/systemd/user/$u.d/l410-cpu.conf
done
# KWin composites with OpenGL ES (fewer dropped frames for low-latency clients than desktop GL)
install -D -m 644 $S/systemd/plasma-kwin_wayland.service.d-l410-gles.conf \
	/etc/systemd/user/plasma-kwin_wayland.service.d/l410-gles.conf
install -m 644 $S/systemd/l410-perfd.service /etc/systemd/user/l410-perfd.service
live && systemctl daemon-reload
systemctl --global enable l410-perfd.service

# KWin script, on by default for every user (a user can still switch it off in the settings)
install -D -m 644 $S/kwin-script/metadata.json /usr/share/kwin/scripts/l410-perf/metadata.json
install -D -m 644 $S/kwin-script/contents/code/main.js /usr/share/kwin/scripts/l410-perf/contents/code/main.js
kwriteconfig6 --file /etc/xdg/kwinrc --group Plugins --key l410-perfEnabled true

# PowerDevil: plugged in -> performance, battery -> balanced, low battery -> power saver
kwriteconfig6 --file /etc/xdg/powerdevilrc --group AC --group Performance --key PowerProfile performance
kwriteconfig6 --file /etc/xdg/powerdevilrc --group Battery --group Performance --key PowerProfile balanced
kwriteconfig6 --file /etc/xdg/powerdevilrc --group LowBattery --group Performance --key PowerProfile power-saver

if live; then
	systemctl enable --now tuned.service tuned-ppd.service
	tuned-adm profile l410-balanced || true
	uid=$(id -u "$U")
	for c in /sys/fs/cgroup/user.slice /sys/fs/cgroup/user.slice/user-$uid.slice \
		 /sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service; do
		echo max > $c/cpu.uclamp.min 2> /dev/null || true
	done
	as_user systemctl --user daemon-reload 2> /dev/null || true
	as_user systemctl --user restart l410-perfd.service 2> /dev/null || true
else
	systemctl enable tuned.service tuned-ppd.service
	echo l410-balanced > /etc/tuned/active_profile
	echo manual > /etc/tuned/profile_mode
fi
echo "perf: tuned profiles l410-*, l410-perfd, KWin script, PowerDevil switching"
