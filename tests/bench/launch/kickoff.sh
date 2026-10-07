#!/bin/bash
# kickoff.sh N: toggle the launcher N times through the D-Bus call the Meta key makes;
# prints trigger->mapped ms (mapped = plasmashell committed the popup's first frame)
. ~/l410-bench/launch-lat/env.sh
probe_load; follow_start
for i in $(seq 1 ${1:-10}); do
    trig kickoff$i
    qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.activateLauncherMenu
    sleep 1.5
    qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.activateLauncherMenu
    sleep 1.0
done
sleep 0.5; follow_stop; report "plasmashell"; rm -f $B/trig.$$
