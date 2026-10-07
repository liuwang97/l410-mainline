#!/bin/bash
# trace.sh TAG SECONDS -- body...: run "body" (a shell snippet that calls trig/launches things) under
# system-wide perf (sched_switch + sched_wakeup + cpu-clock 4 kHz, CLOCK_MONOTONIC timestamps, realtime offset in TAG.off),
# then analyse every trigger window [trigger, window mapped] with ana.py. Output in $B/out/TAG.*
cd ~/l410-bench/launch-lat; . ./env.sh
TAG=$1; S=$2; shift 3; O=$B/out; mkdir -p $O
probe_load; follow_start
sudo -n perf record -q -a -k CLOCK_MONOTONIC -e sched:sched_switch -e sched:sched_wakeup \
    -e cpu-clock/freq=4000/ -o $O/$TAG.data -- sleep $S 2>/dev/null &
PP=$!; sleep 0.6
python3 -c "import time; print(time.clock_gettime(time.CLOCK_REALTIME) - time.clock_gettime(time.CLOCK_MONOTONIC))" > $O/$TAG.off
eval "$@"
wait $PP; sleep 0.3
follow_stop; cp $LOG $O/$TAG.kwin; cp $B/trig.$$ $O/$TAG.trig; rm -f $B/trig.$$ $LOG
sudo -n chown $USER $O/$TAG.data
perf script -i $O/$TAG.data -F comm,pid,tid,cpu,time,event,trace,ip,sym,dso --ns 2>/dev/null > $O/$TAG.txt
python3 $B/ana.py $O/$TAG.txt $O/$TAG.trig $O/$TAG.kwin $O/$TAG.off "${PAT:-.}" | tee $O/$TAG.report
