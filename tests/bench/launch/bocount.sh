#!/bin/bash
# bocount.sh: one Kickoff open+close under bpftrace counting plasmashell's BO creates/submits/closes
cd ~/l410-bench/launch-lat; . ./env.sh; P=$(pgrep -x plasmashell)
sudo -n bpftrace -q $B/bocount.bt $P 3 > $B/out/bocount.txt 2>&1 &
sleep 1.2
qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.activateLauncherMenu
sleep 1.4
wait
cat $B/out/bocount.txt
