#!/bin/bash
# baseline.sh [N]: launch time of the goal's apps (first window / first normal window), N runs each
cd ~/l410-bench/launch-lat; N=${1:-4}
echo "### systemsettings"; bash ./launch.sh $N 5 systemsettings systemsettings systemsettings -- systemsettings
echo "### chromium";       bash ./launch.sh $N 6 org.chromium.Chromium chromium chromium -- /usr/bin/chromium
echo "### firefox";        bash ./launch.sh $N 7 firefox-esr firefox firefox-esr -- /usr/lib/firefox-esr/firefox-esr
echo "### wps";            bash ./launch.sh $N 9 wps-office-prometheus "wps" "wps wpsoffice et wpp" -- /usr/bin/wps
echo "### qq";             bash ./launch.sh $N 10 qq "QQ|qq" "qq" -- /opt/QQ/qq
