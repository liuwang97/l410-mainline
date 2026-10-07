#!/bin/bash
# kcmhide.sh: A/B systemsettings start with/without the 9 module-data KCMs (moved aside temporarily,
# always moved back by the trap)
cd ~/l410-bench/launch-lat; . ./env.sh
K=/usr/lib/aarch64-linux-gnu/qt6/plugins/plasma/kcms; H=/var/tmp/l410-kcm-hidden
L="systemsettings/kcm_touchpad.so systemsettings/kcm_touchscreen.so systemsettings/kcm_tablet.so systemsettings/kcm_bolt.so systemsettings/kcm_bluetooth.so systemsettings/kcm_gamecontroller.so systemsettings/kcm_sddm.so systemsettings/kcm_mouse.so systemsettings_qwidgets/kcm_kwintouchscreen.so"
restore() { for f in $L; do [ -f $H/$(basename $f) ] && sudo mv $H/$(basename $f) $K/$f; done; }
trap restore EXIT
sudo mkdir -p $H
for r in 1 2 3; do
    bash ./launch.sh 1 5 systemsettings systemsettings systemsettings -- systemsettings | grep -v MEAN | sed "s/^/all /"
    for f in $L; do [ -f $K/$f ] && sudo mv $K/$f $H/; done
    bash ./launch.sh 1 5 systemsettings systemsettings systemsettings -- systemsettings | grep -v MEAN | sed "s/^/hidden /"
    restore
done
