#!/bin/bash
# settle.sh: wait until plasmashell has run >= 60 s and the system is quiet (loadavg-1 < 0.6 or 3 min)
for i in $(seq 1 90); do
    p=$(pgrep -x plasmashell) && e=$(ps -o etimes= -p $p) && [ "$e" -ge 60 ] &&
        awk '{exit !($1 < 0.6)}' /proc/loadavg && { echo "settled after ${i}x2s, plasmashell ${e}s, load $(cut -d' ' -f1 /proc/loadavg)"; exit 0; }
    sleep 2
done
echo "not settled: load $(cut -d' ' -f1 /proc/loadavg)"
