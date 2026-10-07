#!/bin/bash
# Override QQ's desktop entry (sudo): run it with GTK's built-in Adwaita theme. Electron initialises
# GTK at start and parses the GTK theme; Breeze's 212 KB gtk.css costs QQ ~80 ms
# (807 -> 729 ms, docs/tuning/launch-latency.md). QQ draws its own UI; only GTK dialogs change look.
# --remove deletes the override.
set -e
A=/usr/local/share/applications/qq.desktop
if [ "$1" = --remove ]; then rm -f $A; exit 0; fi
install -d /usr/local/share/applications
sed -E 's#^Exec=/opt/QQ/qq#Exec=env GTK_THEME=Adwaita /opt/QQ/qq#' /usr/share/applications/qq.desktop > $A
grep "^Exec=" $A
