#!/bin/bash
# compare.sh LABEL N [SS_BIN]: launch time of the goal's apps, closing them the way a user does
# (launch2.sh); results in out/compare-LABEL.txt. $PREFIX applies to every launch.
cd ~/l410-bench/launch-lat; L=$1; N=${2:-5}; SS=${3:-systemsettings}
{
echo "### $L systemsettings ($SS)"; bash ./launch2.sh $N 5 systemsettings systemsettings systemsettings systemsettings -- $SS
echo "### $L chromium";  bash ./launch2.sh $N 6 org.chromium.Chromium chromium chromium chromium -- /usr/bin/chromium
echo "### $L firefox";   bash ./launch2.sh $N 7 firefox-esr firefox firefox-esr firefox-esr -- /usr/lib/firefox-esr/firefox-esr
echo "### $L qq";        bash ./launch2.sh $N 10 qq "QQ|qq" QQ qq -- /opt/QQ/qq
} 2>&1 | tee out/compare-$L.txt | grep -E "###|MEAN"
# WPS: the main window is the second one (after the splash); launch.sh reports both
echo "### $L wps"; bash ./launch.sh $N 9 wps-office-prometheus "wps" "wps wpsoffice et wpp" -- /usr/bin/wps | tee -a out/compare-$L.txt | grep MEAN
