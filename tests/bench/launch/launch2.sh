#!/bin/bash
# launch2.sh N WAIT ID PATTERN CLASS PROC -- cmd...: like launch.sh, but closes the app the way a user
# does (KWin closeWindow on its windows) and waits up to 10 s for PROC to exit before the next run
cd ~/l410-bench/launch-lat; . ./env.sh
N=$1; W=$2; ID=$3; PAT=$4; CL=$5; PR=$6; shift 7
probe_load; follow_start
for i in $(seq 1 $N); do
    trig "$ID$i"
    systemd-run --user --quiet --no-block --unit=app-$ID@$(cat /proc/sys/kernel/random/uuid | tr -d -).service --slice=app.slice -p ExitType=cgroup --collect $PREFIX "$@"
    sleep $W; bash ./closewin.sh $CL
    for j in $(seq 1 50); do pgrep -x $PR > /dev/null || break; sleep 0.2; done
    pgrep -x $PR > /dev/null && { echo "($PR still running, TERM)"; pkill -x $PR; sleep 2; }
    sleep 1
done
follow_stop
report "$PAT" | awk '{print; split($2,a,"="); if (a[2]+0>0) {v[++n]=a[2]+0; s+=a[2]}} END {asort(v); printf "MEAN %.0f MEDIAN %.0f ms (%d)\n", s/n, (n%2 ? v[(n+1)/2] : (v[n/2]+v[n/2+1])/2), n}'
rm -f $B/trig.$$
