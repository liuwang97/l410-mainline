#!/bin/bash
# chrome://gpu of Chromium in the desktop session, with extra flags from $@
export XDG_RUNTIME_DIR=/run/user/${L410_UID:-1000} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${L410_UID:-1000}/bus WAYLAND_DISPLAY=wayland-0
D=$(dirname "$(readlink -f "$0")")
P=$HOME/.config/chromium-cgpu
pkill -TERM -x chromium; sleep 3
mkdir -p $P/Default
[ -f $P/Default/Preferences ] || echo '{"browser":{"custom_chrome_frame":false,"has_seen_welcome_page":true},"distribution":{"skip_first_run_ui":true}}' > $P/Default/Preferences
touch "$P/First Run"
systemd-run --user --scope -q -u app-chromium-cgpu-$$.scope \
	chromium --user-data-dir=$P --ozone-platform=wayland --no-first-run --password-store=basic \
	--remote-debugging-port=9222 "$@" --new-window chrome://gpu > $D/chromium.log 2>&1 &
sleep 8
python3 $D/gpuinfo.py 9222
pkill -TERM -x chromium
