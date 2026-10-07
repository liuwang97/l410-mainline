#!/bin/bash
# abknob2.sh ROUNDS FILE "label|value" ...: interleaved A/B of a sysfs knob over the goal's apps (cold
# starts, closed like a user; resident services stopped meanwhile); restores the knob and the services
cd ~/l410-bench/launch-lat; . ./env.sh; R=$1; F=$2; shift 2
orig=$(sed -n 's/.*\[\(.*\)\].*/\1/p' $F); [ -n "$orig" ] || orig=$(cat $F)
systemctl --user stop l410-chromium-warm.service l410-systemsettings-resident.service; pkill -x chromium; pkill -x systemsettings; sleep 2
run() { bash ./launch2.sh 1 "$@" | grep map_ms; }
for r in $(seq 1 $R); do for v in "$@"; do
    echo "${v#*|}" | sudo tee $F > /dev/null; sleep 1; lab=${v%%|*}
    { run 5 systemsettings systemsettings systemsettings systemsettings -- systemsettings
      run 6 org.chromium.Chromium chromium chromium chromium -- /usr/bin/chromium
      run 7 firefox-esr firefox firefox-esr firefox-esr -- /usr/lib/firefox-esr/firefox-esr
      run 8 qq "QQ|qq" QQ qq -- /opt/QQ/qq
      bash ./launch.sh 1 9 wps-office-prometheus wps "wps wpsoffice et wpp" -- /usr/bin/wps | grep -v MEAN | awk '{print $1, "map_ms="$5}'
    } | sed "s/^/$lab /"
done; done | awk '{k=$1" "$2; sub(/[0-9]+$/, "", k); split($3,a,"="); n[k]=n[k]" "a[2]; if (a[2]+0>0) {s[k]+=a[2]; c[k]++}} END {for (k in n) printf "%-30s mean %5.0f  [%s ]\n", k, s[k]/(c[k]?c[k]:1), n[k]}' | sort -k2,2 -k1,1
echo "$orig" | sudo tee $F > /dev/null
systemctl --user start --no-block l410-chromium-warm.service l410-systemsettings-resident.service
