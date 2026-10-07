#!/bin/bash
# Memory tuning check (docs/tuning/memory.md): kernel config, runtime knobs, swap, oomd,
# cgroup protection, and a memory pressure run with a protected "foreground" probe.
#
#   sudo bash tests/mem.sh [--no-load] [--load fit|over] [--secs N]
#
#   --load fit   a background hog of 90% of MemAvailable (reclaim of page cache and anon)
#   --load over  a hog of 130% of MemAvailable (only survivable with swap/zswap) [default]
#   --no-load    configuration checks only
# The hog runs in system.slice (a transient unit); the probe, a 256 MiB working set touched
# every 100 ms, runs in the desktop user's app.slice like an application. Reported: probe
# stall times, direct reclaim/compaction/refault deltas, zswap and PSI, OOM kills.
# Result lines as in tests/quick.sh; last line RESULT: PASS | RESULT: FAIL (n). Writes only
# /var/tmp/l410-mem/. Safe over WiFi ssh: the hog is capped by time and MemoryMax.
if [ "$(id -u)" != 0 ]; then
	if [ -f "$0" ]; then exec sudo -n bash "$0" "$@"; else exec sudo -n bash -s -- "$@"; fi
fi
LOAD=over SECS=60
while [ $# -gt 0 ]; do
	case $1 in
	--no-load) LOAD=none; shift ;;
	--load) LOAD=$2; shift 2 ;;
	--secs) SECS=$2; shift 2 ;;
	*) echo "usage: $0 [--no-load] [--load fit|over] [--secs N]" >&2; exit 2 ;;
	esac
done
OUT=/var/tmp/l410-mem/$(date +%Y%m%d-%H%M%S); mkdir -p $OUT
NF=0
res() { printf '%-5s %-22s %s\n' "$1" "$2" "$3" | tee -a $OUT/results.txt; [ "$1" = FAIL ] && NF=$((NF + 1)); return 0; }
pass() { res PASS "$@"; }
fail() { res FAIL "$@"; }
info() { res INFO "$@"; }
warn() { res WARN "$@"; }
rd() { cat "$1" 2> /dev/null; }
sel() { sed -n 's/.*\[\(.*\)\].*/\1/p' "$1" 2> /dev/null; }
U=$(loginctl list-sessions --no-legend 2> /dev/null | awk '$3 != "root" && $3 != "sddm" { print $3; exit }')
U=${U:-$(id -un ${L410_UID:-1000})}; UIDN=$(id -u $U)
CURSOR=$(journalctl -k -n 0 --show-cursor 2> /dev/null | sed -n 's/^-- cursor: //p')

echo "== kernel"
cfg=$(zcat /proc/config.gz 2> /dev/null)
miss=""
for o in ZSWAP ZSMALLOC CRYPTO_ZSTD ZSWAP_DEFAULT_ON ZSWAP_SHRINKER_DEFAULT_ON LRU_GEN LRU_GEN_ENABLED PSI MEMCG \
	UCLAMP_TASK_GROUP ENERGY_MODEL PREEMPT TRANSPARENT_HUGEPAGE TRANSPARENT_HUGEPAGE_MADVISE; do
	echo "$cfg" | grep -qE "^CONFIG_$o=y" || miss="$miss $o"
done
[ -z "$miss" ] && pass mem.config "zswap, zstd, multi-gen LRU, PSI, memcg, uclamp, EM, PREEMPT, THP madvise built in" || fail mem.config "not =y:$miss"
[ "$(rd /proc/sys/kernel/sched_energy_aware)" = 1 ] && pass mem.eas "EAS on" || warn mem.eas "sched_energy_aware=$(rd /proc/sys/kernel/sched_energy_aware)"

echo "== runtime knobs"
Z=/sys/module/zswap/parameters
x="$(rd $Z/enabled) $(rd $Z/compressor) $(rd $Z/max_pool_percent) $(rd $Z/shrinker_enabled)"
[ "$x" = "Y zstd 25 Y" ] && pass mem.zswap "enabled, zstd, max_pool_percent 25, shrinker on" || fail mem.zswap "enabled/compressor/max_pool/shrinker = $x (want Y zstd 25 Y)"
x="$(rd /sys/kernel/mm/lru_gen/enabled) $(rd /sys/kernel/mm/lru_gen/min_ttl_ms)"
[[ $x == 0x0007\ 1000 || $x == 0x0003\ 1000 ]] && pass mem.lru-gen "multi-gen LRU $x" || fail mem.lru-gen "lru_gen enabled/min_ttl_ms = $x (want 0x0007 1000)"
x="$(sel /sys/kernel/mm/transparent_hugepage/enabled) $(sel /sys/kernel/mm/transparent_hugepage/defrag)"
[ "$x" = "madvise defer" ] && pass mem.thp "THP madvise, defrag defer" || fail mem.thp "THP enabled/defrag = $x (want madvise defer)"
x=""
for kv in vm.swappiness=100 vm.page-cluster=0 vm.watermark_scale_factor=100 vm.watermark_boost_factor=0 \
	vm.dirty_background_bytes=67108864 vm.dirty_bytes=268435456; do
	[ "$(sysctl -n ${kv%=*})" = "${kv#*=}" ] || x="$x ${kv%=*}=$(sysctl -n ${kv%=*})"
done
[ -z "$x" ] && pass mem.sysctl "swappiness 100, page-cluster 0, watermark_scale 100, boost 0, dirty 64M/256M" || fail mem.sysctl "differs:$x"
systemctl is-enabled -q mem-tune.service 2> /dev/null && pass mem.tune-unit "mem-tune.service enabled" || fail mem.tune-unit "mem-tune.service not enabled"

echo "== swap"
sw=$(swapon --show=NAME,TYPE,SIZE --bytes --noheadings)
echo "$sw" > $OUT/swapon.txt
if echo "$sw" | grep -q '^/dev/zram'; then fail mem.no-zram "zram swap active (LRU inversion with the disk swap)"; else pass mem.no-zram "no zram swap"; fi
sz=$(echo "$sw" | awk '$1 == "/swapfile" { print $3 }')
[ -n "$sz" ] && [ "$sz" -ge $((7 * 1024 * 1024 * 1024)) ] && pass mem.swapfile "/swapfile active, $((sz >> 20)) MiB" || fail mem.swapfile "no /swapfile of >= 7 GiB active ($sw)"
x=$(sel /sys/block/sdd/queue/scheduler)
[ "$x" = mq-deadline ] && pass mem.iosched "sdd: mq-deadline" || fail mem.iosched "sdd scheduler: $x"

echo "== oomd and protection"
if systemctl is-active -q systemd-oomd.service; then
	oomctl > $OUT/oomctl.txt 2>&1
	grep -q "user@$UIDN.service" $OUT/oomctl.txt && pass mem.oomd "systemd-oomd watches user@$UIDN.service" || fail mem.oomd "oomd running but user@$UIDN.service not monitored"
	grep -A3 -i "swap monitored" $OUT/oomctl.txt | grep -q "/" && pass mem.oomd-swap "swap kill on -.slice monitored" || warn mem.oomd-swap "no swap-monitored cgroup in oomctl"
else
	fail mem.oomd "systemd-oomd not active"
fi
grep -q 'cgroup2 .*memory_recursiveprot' /proc/mounts && pass mem.recursiveprot "cgroup2 mounted with memory_recursiveprot" || fail mem.recursiveprot "no memory_recursiveprot"
C=/sys/fs/cgroup/user.slice
UC=$C/user-$UIDN.slice/user@$UIDN.service
x="user.slice min $(rd $C/memory.min) low $(rd $C/memory.low), user@ min $(rd $UC/memory.min), session.slice min $(rd $UC/session.slice/memory.min)"
ok=1; for v in "$(rd $C/memory.min)" "$(rd $C/memory.low)" "$(rd $UC/memory.min)" "$(rd $UC/session.slice/memory.min)"; do
	[ -n "$v" ] && [ "$v" != 0 ] || ok=0
done
[ $ok = 1 ] && pass mem.protect "$x" || fail mem.protect "$x (every level must be > 0)"

[ $LOAD = none ] && { echo "RESULT: $([ $NF = 0 ] && echo PASS || echo "FAIL ($NF)")"; echo "OUT: $OUT"; exit $NF; }

echo "== pressure run: $LOAD, $SECS s"
vm() { awk '$1 ~ /^(allocstall_|compact_stall$|compact_fail$|pgmajfault$|workingset_refault_|zswpin$|zswpout$|zswpwb$|pswpin$|pswpout$|pgscan_direct$|pgsteal_direct$|oom_kill$|pgscan_kswapd$)/ { print $1, $2 }' /proc/vmstat; }
zs() { for f in pool_total_size stored_pages pool_limit_hit written_back_pages reject_compress_fail reject_reclaim_fail; do echo "$f $(rd /sys/kernel/debug/zswap/$f)"; done; }
vm > $OUT/vm.a; zs > $OUT/zs.a
avail=$(awk '/MemAvailable/ { print int($2 / 1024) }' /proc/meminfo)
total=$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)
case $LOAD in fit) hog=$((avail * 9 / 10)) ;; over) hog=$((avail * 13 / 10)) ;; esac
info mem.load "MemTotal ${total} MiB, MemAvailable ${avail} MiB, hog ${hog} MiB in system.slice"

# direct reclaim latency histogram when bpftrace is there (BTF kernel)
BT=""
if command -v bpftrace > /dev/null; then
	bpftrace -q -e 'tracepoint:vmscan:mm_vmscan_direct_reclaim_begin { @t[tid] = nsecs; }
		tracepoint:vmscan:mm_vmscan_direct_reclaim_end /@t[tid]/ { $d = (nsecs - @t[tid]) / 1000; @us = hist($d); @max = max($d); @n = count(); delete(@t[tid]); }
		END { clear(@t); }' > $OUT/reclaim-hist.txt 2>&1 & BT=$!
	sleep 3
fi
# PSI sampler
( while :; do echo "$(date +%s) $(sed -n 's/^some avg10=\([0-9.]*\).*/\1/p' /proc/pressure/memory) $(sed -n 's/^full avg10=\([0-9.]*\).*/\1/p' /proc/pressure/memory)"; sleep 1; done ) > $OUT/psi.txt & PSIP=$!

# the protected probe: an "application" in the user's app.slice touching its working set
cat > $OUT/probe.py << 'PY'
import mmap, time, sys, os
secs = float(sys.argv[1]); mb = 256
m = mmap.mmap(-1, mb << 20)
page = 4096; n = (mb << 20) // page
for i in range(n): m[i * page] = 1
t_end = time.monotonic() + secs; worst = []; lat = []
while time.monotonic() < t_end:
    t0 = time.monotonic()
    for i in range(0, n, 1): m[i * page] = (m[i * page] + 1) & 0xff
    d = (time.monotonic() - t0) * 1000; lat.append(d)
    time.sleep(0.1)
lat.sort()
print("probe n=%d p50=%.1f p95=%.1f p99=%.1f max=%.1f ms" % (len(lat), lat[len(lat)//2], lat[int(len(lat)*.95)], lat[min(len(lat)-1, int(len(lat)*.99))], lat[-1]))
PY
PROBE_UNIT=app-l410-memprobe-$$
su - $U -c "XDG_RUNTIME_DIR=/run/user/$UIDN systemd-run --user --scope -q -u $PROBE_UNIT.scope python3 $OUT/probe.py $((SECS + 20))" > $OUT/probe.txt 2>&1 & PRP=$!
sleep 10
cat > $OUT/hog.py << 'PY'
# memory hog: MB of pages that compress about 3:1 (1 KiB random + 3 KiB zero per page),
# then random touches keep them in use until the time is up
import os, random, sys, time
mb, secs = int(sys.argv[1]), float(sys.argv[2])
page = 4096; chunk = 64 << 20; bufs = []
rnd = os.urandom(1 << 20)
t_end = time.monotonic() + secs
for i in range(mb // 64):
    b = bytearray(chunk)
    for off in range(0, chunk, page):
        o = (off // 4) % ((1 << 20) - 1024)
        b[off:off + 1024] = rnd[o:o + 1024]
    bufs.append(b)
    if time.monotonic() > t_end:
        break
n = len(bufs) * (chunk // page)
while time.monotonic() < t_end:
    for _ in range(20000):
        k = random.randrange(n)
        b = bufs[k // (chunk // page)]
        b[(k % (chunk // page)) * page + 2048] ^= 1
print("hog done", len(bufs) * 64, "MiB")
PY
# the hog (stress-ng caps --vm-bytes to the free memory, so it never overcommits): a
# transient unit with a hard MemoryMax so it cannot take the whole machine
systemd-run -q --unit=l410-memhog-$$ -p MemoryMax=$((hog + 512))M -p MemorySwapMax=infinity -p RuntimeMaxSec=$((SECS + 60)) \
	python3 $OUT/hog.py $hog $SECS > /dev/null 2>&1
t0=$(date +%s)
while [ $(($(date +%s) - t0)) -lt $((SECS + 25)) ] && systemctl is-active -q l410-memhog-$$; do sleep 2; done
systemctl stop l410-memhog-$$ 2> /dev/null; systemctl reset-failed l410-memhog-$$ 2> /dev/null
wait $PRP
kill $PSIP 2> /dev/null
[ -n "$BT" ] && { kill -INT $BT; wait $BT 2> /dev/null; }
vm > $OUT/vm.b; zs > $OUT/zs.b
d() { awk -v k="$1" 'NR == FNR { a[$1] = $2; next } $1 ~ k { s += $2 - a[$1] } END { print s + 0 }' $OUT/vm.a $OUT/vm.b; }
zd() { awk -v k="$1" 'NR == FNR { a[$1] = $2; next } $1 == k { print $2 - a[$1] }' $OUT/zs.a $OUT/zs.b; }

p=$(cat $OUT/probe.txt | grep '^probe' | tail -1)
pmax=$(echo "$p" | sed -n 's/.*max=\([0-9.]*\).*/\1/p')
p99=$(echo "$p" | sed -n 's/.*p99=\([0-9.]*\).*/\1/p')
if [ -z "$pmax" ]; then
	fail mem.probe "probe did not report (killed?): $(tail -2 $OUT/probe.txt)"
else
	# touching 256 MiB takes ~20-40 ms on the A76 when resident; refaults from zswap/UFS add to it
	awk -v x=$p99 'BEGIN { exit !(x < 250) }' && pass mem.probe "foreground working set under pressure: $p" || fail mem.probe "foreground stalls under pressure: $p"
fi
info mem.reclaim "allocstall +$(d '^allocstall_') pgscan_direct +$(d '^pgscan_direct$') compact_stall +$(d '^compact_stall$') pgmajfault +$(d '^pgmajfault$') refault_file +$(d '^workingset_refault_file$') refault_anon +$(d '^workingset_refault_anon$')"
info mem.swapio "zswpout +$(d '^zswpout$') zswpin +$(d '^zswpin$') zswpwb +$(d '^zswpwb$') pswpout +$(d '^pswpout$') pswpin +$(d '^pswpin$'); zswap pool_limit_hit +$(zd pool_limit_hit) stored_pages now $(rd /sys/kernel/debug/zswap/stored_pages)"
psimax=$(awk 'BEGIN { s = 0; f = 0 } { if ($2 > s) s = $2; if ($3 > f) f = $3 } END { print s, f }' $OUT/psi.txt)
info mem.psi "memory PSI avg10 peak some/full: $psimax"
if [ -s $OUT/reclaim-hist.txt ]; then
	mx=$(sed -n 's/^@max: //p' $OUT/reclaim-hist.txt); nn=$(sed -n 's/^@n: //p' $OUT/reclaim-hist.txt)
	info mem.reclaim-lat "direct reclaim: ${nn:-0} calls, longest ${mx:-0} us (histogram in reclaim-hist.txt)"
fi
ok=$(d '^oom_kill$')
[ $LOAD = over ] && [ "$(d '^zswpout$')" -gt 0 ] && pass mem.zswap-used "overcommit went to zswap (zswpout +$(d '^zswpout$'))"
[ $LOAD = over ] && [ "$(d '^zswpout$')" -eq 0 ] && fail mem.zswap-used "no zswpout during a 130% overcommit"
x=$(pgrep -x kwin_wayland > /dev/null && pgrep -x plasmashell > /dev/null && echo alive)
[ "$x" = alive ] && pass mem.session "kwin_wayland and plasmashell survived (kernel OOM kills +$ok)" || fail mem.session "desktop process gone after the run (oom_kill +$ok)"
journalctl -k --after-cursor "$CURSOR" --no-pager -o short-monotonic > $OUT/klog.txt 2>/dev/null
x=$(grep -cE "Unable to handle|BUG:|WARNING: CPU|Oops|soft lockup|hung_task|blocked for more than" $OUT/klog.txt)
[ "$x" = 0 ] && pass mem.klog "no kernel errors during the run" || fail mem.klog "$x kernel error lines (klog.txt)"
echo "RESULT: $([ $NF = 0 ] && echo PASS || echo "FAIL ($NF)")"
echo "OUT: $OUT"
exit $NF
