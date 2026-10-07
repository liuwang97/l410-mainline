#!/bin/bash
cd ~/l410-bench/launch-lat
PAT=plasmashell bash ./trace.sh ${1:-kick} 11 -- 'for i in 1 2 3 4; do trig kick$i; qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.activateLauncherMenu; sleep 1.3; qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.activateLauncherMenu; sleep 0.9; done'
