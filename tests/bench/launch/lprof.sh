#!/bin/bash
# lprof.sh TAG SECONDS ID -- cmd...: one launch (transient app unit, $PREFIX in front) under system-wide perf -g,
# report CPU time per process/DSO/kernel path from launch to the first window
cd ~/l410-bench/launch-lat; . ./env.sh; O=$B/out; TAG=$1; S=$2; ID=$3; shift 4
probe_load; follow_start
sudo -n perf record -q -a -g -F 2000 -k CLOCK_MONOTONIC -o $O/$TAG.lp.data -- sleep $S 2>/dev/null &
PP=$!; sleep 0.5
python3 -c "import time; print(time.clock_gettime(time.CLOCK_REALTIME) - time.clock_gettime(time.CLOCK_MONOTONIC))" > $O/$TAG.lp.off
u=app-$ID@$(cat /proc/sys/kernel/random/uuid | tr -d -).service
trig $TAG; systemd-run --user --quiet --no-block --unit=$u --slice=app.slice -p ExitType=cgroup --collect $PREFIX "$@"
wait $PP; systemctl --user stop $u 2>/dev/null; sleep 1; follow_stop
t0=$(awk '{print $2}' $B/trig.$$); OFF=$(cat $O/$TAG.lp.off)
t1=$(grep "L410T add" $LOG | sed 's/^js: //' | awk -v t=$t0 -v nw=${NORMAL:-0} '$3 >= t && (!nw || / type=0 /) {print $3; exit}')
rm -f $B/trig.$$ $LOG
echo "### $TAG: first window $((t1 - t0)) ms"
sudo -n perf script -f -i $O/$TAG.lp.data -F comm,pid,tid,time,ip,sym,dso 2>/dev/null |
    python3 $B/sysprof.py $(python3 -c "print($t0/1000 - $OFF, $t1/1000 - $OFF)") 2000
