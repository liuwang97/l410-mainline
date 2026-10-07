#!/bin/bash
# t-ss.sh TAG [prefix...]: 3 systemsettings launches under trace; prefix e.g. "env -u QT_ACCESSIBILITY" or "taskset -c 6,7"
cd ~/l410-bench/launch-lat
TAG=${1:-ss}; shift; PRE="$*"
PAT=systemsettings bash ./trace.sh $TAG 18 -- 'for i in 1 2 3; do trig ss$i; setsid '"$PRE"' systemsettings >/dev/null 2>&1 </dev/null & sleep 4; pkill -x systemsettings; sleep 1.5; done'
