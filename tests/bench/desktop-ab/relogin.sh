#!/bin/bash
# relogin.sh [VAR=value ...]: KWin env drop-in (always with the per-frame log), then a fresh
# Plasma session: ssh sessions keep the user manager (and with it the Plasma services) alive
# across a logout, so stop the services themselves before sddm autologs in again.
# Run detached: nohup bash relogin.sh ... > relogin.log 2>&1 &
set -e
export XDG_RUNTIME_DIR=/run/user/${L410_UID:-1000} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${L410_UID:-1000}/bus
D=$HOME/.config/systemd/user/plasma-kwin_wayland.service.d
mkdir -p $D
{ echo "[Service]"; echo "Environment=KWIN_LOG_PERFORMANCE_DATA=1"; for v in "$@"; do echo "Environment=$v"; done; } > $D/cgpu.conf
cat $D/cgpu.conf
systemctl --user daemon-reload
OLD=$(pgrep -u ${L410_UID:-1000} -x kwin_wayland || true)
rm -f "$HOME/kwin perf statistics eDP-1.csv"
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
echo "kwin $OLD -> $K: $(sudo cat /proc/$K/environ | tr '\0' '\n' | grep -E '^KWIN_' | paste -sd' ')"
qdbus6 org.kde.KWin /KWin org.kde.KWin.supportInformation | grep -E '^(OpenGL version string|Compositing Type|OpenGL renderer)'
b=$(cat /sys/class/backlight/*/brightness)
[ "$b" -gt 5 ] || qdbus6 org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement/Actions/BrightnessControl setBrightness 6000
echo "brightness $(cat /sys/class/backlight/*/brightness)/$(cat /sys/class/backlight/*/max_brightness)"
# the kernel reads the panel size from EDID and KWin may pick 1.25; the tests assume 1.5
scale() { kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/.*Scale: *//p' | head -1; }
sc=$(scale); echo "scale $sc"
[ "$sc" = 1.5 ] || { kscreen-doctor output.eDP-1.scale.1.5 > /dev/null 2>&1; sleep 2; echo "scale -> $(scale)"; }
sudo tuned-adm profile l410-balanced
sleep 2
cat /sys/kernel/l410_perf/mode
echo 0 | sudo tee /sys/kernel/l410_deadman/timeout > /dev/null; sudo touch /run/l410-keep
echo RELOGIN-DONE
