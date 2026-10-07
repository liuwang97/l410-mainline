#!/bin/bash
# abknob.sh ROUNDS FILE "label|value" ...: interleaved A/B of a sysfs knob (written as root before each
# variant) over the goal's apps; restores the original value at the end
cd ~/l410-bench/launch-lat; R=$1; F=$2; shift 2
orig=$(sed -n 's/.*\[\(.*\)\].*/\1/p' $F); [ -n "$orig" ] || orig=$(cat $F)
for r in $(seq 1 $R); do for v in "$@"; do
    echo "${v#*|}" | sudo tee $F > /dev/null; sleep 1
    lab=${v%%|*}
    bash ./launch.sh 1 5 systemsettings systemsettings systemsettings -- systemsettings | grep -v MEAN | sed "s/^/$lab /"
    bash ./launch.sh 1 6 org.chromium.Chromium chromium chromium -- /usr/bin/chromium | grep -v MEAN | sed "s/^/$lab /"
    bash ./launch.sh 1 7 firefox-esr firefox firefox-esr -- /usr/lib/firefox-esr/firefox-esr | grep -v MEAN | sed "s/^/$lab /"
    bash ./launch.sh 1 9 wps-office-prometheus wps "wps wpsoffice et wpp" -- /usr/bin/wps | grep -v MEAN | sed "s/^/$lab /"
    bash ./launch.sh 1 10 qq "QQ|qq" qq -- /opt/QQ/qq | grep -v MEAN | sed "s/^/$lab /"
done; done | awk '{k=$1" "$2; sub(/[0-9]+$/, "", k); n[k]=n[k]" "$6; if ($6>=0) {s[k]+=$6; c[k]++}} END {for (k in n) printf "%-32s mean %5.0f  [%s ]\n", k, s[k]/(c[k]?c[k]:1), n[k]}' | sort -k2,2 -k1,1
echo "$orig" | sudo tee $F > /dev/null
