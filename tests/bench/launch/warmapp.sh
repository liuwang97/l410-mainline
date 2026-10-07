#!/bin/bash
# warmapp.sh N WAIT ID PATTERN CLASS -- cmd...: launch through a transient app unit while a resident
# instance runs; close the window via KWin between runs (the resident process stays)
cd ~/l410-bench/launch-lat; . ./env.sh
N=$1; W=$2; ID=$3; PAT=$4; CL=$5; shift 6
probe_load; follow_start
for i in $(seq 1 $N); do
    trig $ID$i
    systemd-run --user --quiet --no-block --unit=app-$ID@$(cat /proc/sys/kernel/random/uuid | tr -d -).service --slice=app.slice -p ExitType=cgroup --collect "$@"
    sleep $W; bash ./closewin.sh $CL; sleep 2
done
follow_stop; report "$PAT" | awk '{print; split($2,a,"="); if (a[2]+0>0) {s+=a[2]; n++}} END {printf "MEAN %.0f ms (%d)\n", s/n, n}'; rm -f $B/trig.$$
