#!/bin/bash
# t-app.sh TAG ID PATTERN WAIT -- cmd...: one launch (transient app unit) under the sched trace (trace.sh/ana.py)
cd ~/l410-bench/launch-lat
TAG=$1; ID=$2; P=$3; W=$4; shift 5
U=app-$ID@$(cat /proc/sys/kernel/random/uuid | tr -d -).service
PAT="$P" bash ./trace.sh $TAG $((W + 1)) -- "trig $TAG; systemd-run --user --quiet --no-block --unit=$U --slice=app.slice -p ExitType=cgroup --collect $PREFIX $*; sleep $W"
systemctl --user stop $U 2>/dev/null
