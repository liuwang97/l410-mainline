#!/bin/bash
# launch.sh N WAIT ID PATTERN [KILLNAMES] -- cmd...: start cmd N times the way Plasma does (transient
# app-ID@uuid.service in app.slice), report trigger -> first window (any type) and -> first normal
# window (KWin type 0) whose line matches PATTERN; stop the unit (SIGTERM to its cgroup) between runs.
# PREFIX="taskset -c 4-7" puts a command in front of cmd (A/B without touching the drop-ins).
cd ~/l410-bench/launch-lat; . ./env.sh
N=$1; W=$2; ID=$3; PAT=$4; KN=$5; shift 5; [ "$1" = -- ] && shift
probe_load; follow_start
for i in $(seq 1 $N); do
    u=app-$ID@$(cat /proc/sys/kernel/random/uuid | tr -d -).service
    trig "$ID$i"
    systemd-run --user --quiet --no-block --unit=$u --slice=app.slice -p ExitType=cgroup --collect $PREFIX "$@"
    sleep $W
    systemctl --user stop $u 2>/dev/null
    [ -n "$KN" ] && for k in $KN; do pkill -TERM -x $k; done
    sleep 2
    [ -n "$KN" ] && for k in $KN; do pkill -KILL -x $k; done
done
follow_stop
awk -v pat="$PAT" 'FNR==NR { sub(/^js: /, ""); $0 = $0; if ($1=="L410T" && $2=="add" && $0 ~ pat) { n++; a[n]=$3; nt[n]=($0 ~ / type=0 /) } next }
    { t=$2; f=-1; m=-1; for (i=1;i<=n;i++) if (a[i]>=t && a[i]-t < 30000) { if (f<0) f=a[i]-t; if (nt[i] && m<0) m=a[i]-t } 
      printf "%s first %s normal %s\n", $1, f, m }' $LOG $B/trig.$$ |
  awk '{print; if ($3>=0) {fs+=$3; fn++} if ($5>=0) {ms+=$5; mn++}} END {printf "MEAN first %.0f ms (%d)  normal %.0f ms (%d)\n", fs/(fn?fn:1), fn, ms/(mn?mn:1), mn}'
cp $LOG $B/out/last-launch.kwin; rm -f $B/trig.$$ $LOG
