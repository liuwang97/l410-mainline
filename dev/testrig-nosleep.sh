#!/bin/bash
# Test-rig only: stop PowerDevil from suspending the L410 when idle. Since system sleep works
# (10-01), an idle the L410 goes into s2idle after the PowerDevil timeout and WiFi goes with it;
# nothing can wake it remotely (no WoWLAN; wake sources are the power key, the lid, RTC).
# Delivery images must NOT carry this (docs/testing/test-plan.md INS-07): run with "restore".
#
#   bash testrig-nosleep.sh [off|restore]      (as the desktop user, in the session)
set -e
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)} DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}
for g in AC Battery LowBattery; do
	if [ "${1:-off}" = restore ]; then
		kwriteconfig6 --file powerdevilrc --group $g --group SuspendAndShutdown --key AutoSuspendAction --delete
	else
		kwriteconfig6 --file powerdevilrc --group $g --group SuspendAndShutdown --key AutoSuspendAction 0
	fi
done
# PowerDevil rereads its configuration when told to
qdbus6 org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement org.kde.Solid.PowerManagement.refreshStatus 2> /dev/null || true
grep -A2 SuspendAndShutdown ~/.config/powerdevilrc || true
