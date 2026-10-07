#!/bin/bash
# abapps.sh ROUNDS [APPS]: per app, interleaved variants (VARIANTS: lines "label|prefix", default base/noafbc/na76);
# APPS: space-separated subset of: settings chromium firefox wps qq (default all)
cd ~/l410-bench/launch-lat; R=${1:-3}; APPS=${2:-settings chromium firefox wps qq}
mapfile -t V <<< "${VARIANTS:-base|
noafbc|env PAN_MESA_DEBUG=noafbc
na76|env PAN_MESA_DEBUG=noafbc taskset -c 4-7}"
app() { local id=$1 w=$2 pat=$3 kn=$4; shift 4
    for r in $(seq 1 $R); do for v in "${V[@]}"; do
        PREFIX="${v#*|}" bash ./launch.sh 1 $w $id "$pat" "$kn" -- "$@" | grep -v MEAN | sed "s/^/${v%%|*} /"
    done; done | awk -v id=$id '{f[$1]=f[$1]" "$4; n[$1]=n[$1]" "$6; if ($6>=0) {s[$1]+=$6; c[$1]++}} END {for (k in f) printf "%-22s %-7s mean %5.0f  first:%s | normal:%s\n", id, k, s[k]/(c[k]?c[k]:1), f[k], n[k]}'
}
for a in $APPS; do case $a in
settings) app systemsettings 5 systemsettings systemsettings systemsettings ;;
chromium) app org.chromium.Chromium 6 chromium chromium /usr/bin/chromium ;;
firefox)  app firefox-esr 7 firefox firefox-esr /usr/lib/firefox-esr/firefox-esr ;;
wps)      app wps-office-prometheus 9 wps "wps wpsoffice et wpp" /usr/bin/wps ;;
qq)       app qq 10 "QQ|qq" qq /opt/QQ/qq ;;
esac; done
