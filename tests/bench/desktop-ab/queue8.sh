#!/bin/bash
# queue8: Chrome trace + KWin frame log while scrolling (log: queue8.log), then back to normal
export XDG_RUNTIME_DIR=/run/user/${L410_UID:-1000} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${L410_UID:-1000}/bus WAYLAND_DISPLAY=wayland-0
C=$HOME/l410-bench/cgpu; cd $C
echo "kernel $(uname -r) sched_ext $(cat /sys/kernel/sched_ext/state) $(date +%T)"
bash relogin.sh
bash traceprobe.sh tr-p1
bash traceprobe.sh tr-p2
pkill -x chromium
rm -f $HOME/.config/systemd/user/plasma-kwin_wayland.service.d/cgpu.conf
systemctl --user daemon-reload
sudo systemctl stop sddm
systemctl --user stop plasma-kwin_wayland.service graphical-session.target || true
sleep 3; sudo systemctl start sddm; sleep 25
K=$(pgrep -u ${L410_UID:-1000} -x kwin_wayland); echo "kwin $K: $(sudo cat /proc/$K/environ | tr '\0' '\n' | grep -E '^(KWIN_|LD_)' | paste -sd' ')"
b=$(cat /sys/class/backlight/*/brightness); [ "$b" -gt 5 ] || qdbus6 org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement/Actions/BrightnessControl setBrightness 6000
echo "QUEUE8-DONE $(date +%T)"
