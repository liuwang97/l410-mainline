#!/bin/bash
# relogin.sh: fresh Plasma session (KWin + plasmashell), nothing else changed. ssh sessions keep the
# user manager alive across a logout, so the Plasma services are stopped explicitly before sddm
# autologs in again. Run detached: setsid nohup bash relogin.sh > relogin.log 2>&1 < /dev/null &
export XDG_RUNTIME_DIR=/run/user/${L410_UID:-1000} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${L410_UID:-1000}/bus
systemctl --user daemon-reload
OLD=$(pgrep -u ${L410_UID:-1000} -x kwin_wayland || true)
sudo systemctl stop sddm
systemctl --user stop plasma-kwin_wayland.service || true
systemctl --user stop graphical-session.target || true
for i in $(seq 1 20); do pgrep -u ${L410_UID:-1000} -x 'kwin_wayland|plasmashell' > /dev/null || break; sleep 1; done
pgrep -a -u ${L410_UID:-1000} -x 'kwin_wayland|plasmashell' || echo "plasma stopped"
sleep 2
sudo systemctl start sddm
for i in $(seq 1 60); do
	K=$(pgrep -u ${L410_UID:-1000} -x kwin_wayland || true)
	[ -n "$K" ] && [ "$K" != "$OLD" ] && pgrep -u ${L410_UID:-1000} -x plasmashell > /dev/null && break
	sleep 2
done
sleep 10
K=$(pgrep -u ${L410_UID:-1000} -x kwin_wayland)
echo "kwin $OLD -> $K, libgallium: $(sudo grep -m1 gallium /proc/$K/maps | awk '{print $6}')"
b=$(cat /sys/class/backlight/*/brightness)
[ "$b" -gt 5 ] || qdbus6 org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement/Actions/BrightnessControl setBrightness 6000
echo "brightness $(cat /sys/class/backlight/*/brightness)/$(cat /sys/class/backlight/*/max_brightness)"
export WAYLAND_DISPLAY=wayland-0
scale() { kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/.*Scale: *//p' | head -1; }
sc=$(scale); echo "scale $sc"
[ "$sc" = 1.5 ] || { kscreen-doctor output.eDP-1.scale.1.5 > /dev/null 2>&1; sleep 2; echo "scale -> $(scale)"; }
cat /sys/kernel/l410_perf/mode
echo RELOGIN-DONE
