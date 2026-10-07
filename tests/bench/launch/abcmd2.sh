#!/bin/bash
# abcmd2.sh ROUNDS WAIT ID PATTERN CLASS PROC -- "label|command" ...: interleaved A/B of whole commands,
# closing like a user (launch2.sh)
cd ~/l410-bench/launch-lat; R=$1; W=$2; ID=$3; PAT=$4; CL=$5; PR=$6; shift 7
for r in $(seq 1 $R); do for v in "$@"; do
    bash ./launch2.sh 1 $W $ID "$PAT" "$CL" $PR -- ${v#*|} | grep "map_ms" | sed "s/^/${v%%|*} /"
done; done | awk '{split($3,a,"="); f[$1]=f[$1]" "a[2]; if (a[2]+0>0) {s[$1]+=a[2]; c[$1]++}} END {for (k in f) printf "%-12s mean %5.0f  [%s ]\n", k, s[k]/(c[k]?c[k]:1), f[k]}'
