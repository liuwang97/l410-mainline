#!/bin/bash
# abcmd.sh ROUNDS WAIT ID PATTERN KILLNAMES -- "label|command" ...: interleaved A/B of whole commands
cd ~/l410-bench/launch-lat; R=$1; W=$2; ID=$3; PAT=$4; KN=$5; shift 6
for r in $(seq 1 $R); do for v in "$@"; do
    bash ./launch.sh 1 $W $ID "$PAT" "$KN" -- ${v#*|} | grep -v MEAN | sed "s/^/${v%%|*} /"
done; done | awk '{f[$1]=f[$1]" "$4; if ($4>=0) {s[$1]+=$4; c[$1]++}} END {for (k in f) printf "%-12s mean %5.0f  [%s ]\n", k, s[k]/(c[k]?c[k]:1), f[k]}'
