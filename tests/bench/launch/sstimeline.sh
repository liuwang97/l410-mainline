#!/bin/bash
# sstimeline.sh: systemsettings startup phases from a seccomp-filtered strace (openat/connect/execve)
# plus the KWin window-map time
cd ~/l410-bench/launch-lat; . ./env.sh; O=$B/out
probe_load; follow_start
T0=$(date +%s.%N); trig ss
taskset -c 4-7 strace -f -ttt --seccomp-bpf -e trace=openat,execve,connect -e signal=none -o $O/sst.strace systemsettings >/dev/null 2>&1 &
sleep 4; pkill -x systemsettings; sleep 1; follow_stop
MAP=$(sed 's/^js: //' $LOG | awk -v t=$T0 '$1=="L410T" && $2=="add" && /systemsettings/ && $3/1000 >= t {printf "%.3f", $3/1000; exit}')
rm -f $B/trig.$$ $LOG
python3 - "$O/sst.strace" "$T0" "$MAP" <<'PY'
import sys, re
f, t0, tmap = sys.argv[1], float(sys.argv[2]), float(sys.argv[3] or 0)
ev = []
for l in open(f):
    m = re.match(r"(\d+)\s+([\d.]+)\s+(\w+)\((.*)", l)
    if m: ev.append((float(m.group(2)), m.group(3), m.group(4)))
first = lambda pat: next(((t - t0) * 1000 for t, c, a in ev if re.search(pat, a)), -1)
last = lambda pat: max([(t - t0) * 1000 for t, c, a in ev if re.search(pat, a)] or [-1])
print(f"window mapped        {1000*(tmap - t0):6.0f} ms")
for name, pat in [("exec", r"systemsettings\""), ("libQt6Quick", r"libQt6Quick\.so"),
                  ("first kcm .so", r"plugins/plasma/kcms/"),
                  ("moduledata kcms", r"kcm_(touchpad|touchscreen|tablet|bolt|bluetooth|gamecontroller|sddm|mouse)\.so"),
                  ("landingpage", r"kcm_landingpage\.so"), ("render node", r"renderD128"),
                  ("first .qml/.qmlc", r"\.qmlc?\""), ("look-and-feel preview", r"previews/preview\.png"),
                  ("first icon svg", r"/icons/.*\.svg")]:
    print(f"{name:22s} first {first(pat):6.0f}  last {last(pat):6.0f}")
so = [(t - t0) * 1000 for t, c, a in ev if c == "openat" and ".so" in a and "ENOENT" not in a]
for lim in (200, 400, 600, 800, 1000, 1200):
    print(f".so opened by {lim:4d} ms: {sum(1 for x in so if x <= lim)}")
PY
