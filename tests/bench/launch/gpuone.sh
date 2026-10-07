#!/bin/bash
# gpuone.sh LABEL NAME -- cmd...: one launch (plain process) under the GPU ioctl counter, plus first-window
# time; NAME = process name of the app (window match and kill)
cd ~/l410-bench/launch-lat; . ./env.sh; L=$1; name=$2; shift 3
probe_load; follow_start
sudo -n bpftrace -q $B/gpucount.bt 5 > $B/out/g1-$L.txt 2>/dev/null &
BP=$!; sleep 1.5; trig $L
setsid "$@" >/dev/null 2>&1 < /dev/null &
wait $BP; pkill -x $name; sleep 1.5; pkill -KILL -x $name; follow_stop
echo "### $L: $(report "$name" | cut -d' ' -f2)  $(grep -E "\[$name\]" $B/out/g1-$L.txt | tr '\n' ' ')"
rm -f $B/trig.$$ $LOG
