#!/bin/bash
# UFS: Kirin 990 UFS checks on the 6.18 test kernel.
# Runs on the test kernel's Debian as root (the harness runs --script with
# `sudo bash -s`) or as a sudo user, e.g.
#   dev/l410-harness.sh test <bundle> --script tests/ufs.sh
# Prints one PASS/FAIL line per check and a summary line at the end.
#
# Safety: never writes sda/sdb/sdc (firmware LUNs) or any block device directly.
# The data test only writes regular files under /var/tmp on the Debian root and
# removes them afterwards. Resets used here (host reset, runtime PM cycles)
# are standard driver paths, not device configuration writes.
#
# UFS_TEST_MB   size of the sequential data test in MiB (default 2048)
# UFS_TEST_QUICK=1  skip the data test
# UFS_TEST_AH8  iterations of each auto-hibern8 stress pass (default 300)
set -u
PASS=0 FAIL=0
ok() { echo "PASS $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL $*"; FAIL=$((FAIL + 1)); }
info() { echo "INFO $*"; }
S=
[ "$(id -u)" = 0 ] || S=sudo
U=/sys/bus/platform/devices/f8200000.ufs
DBG=/sys/kernel/debug/ufshcd/f8200000.ufs
MB=${UFS_TEST_MB:-2048}
T=/var/tmp/l410-ufs-test

$S mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
# sum of the error event counters (resets are counted separately: host resets and
# runtime resume from link-off legitimately bump "Host Resets"/"Logical Unit Resets")
stats() { $S cat $DBG/stats 2>/dev/null | grep -v Resets | awk -F': ' '{s += $2} END {print s + 0}'; }
show_stats() { $S cat $DBG/stats 2>/dev/null | sed 's/^/INFO   /'; }
# markers carry a per-run id: a second run must not start reading at the first run's marker
RUNID=$$-$(date +%s)
kmsg_mark() { echo "l410-ufs-test: $RUNID $1" | $S tee /dev/kmsg > /dev/null; }
DM=$(mktemp)
dmesg_snap() { $S dmesg > "$DM" 2>/dev/null; }
ufs_errors_since() { # dmesg lines from ufshcd after marker $1 that look like errors
	dmesg_snap
	sed -n "/l410-ufs-test: $RUNID $1/,\$p" "$DM" | grep -iE "ufshcd|f8200000|sd [0-9]:|I/O error|blk_update" |
		grep -iE "err|fail|timeout|abort|reset|I/O" | grep -v "l410-ufs-test"
}

# auto-hibern8 stress: small direct reads separated by idle gaps longer than the
# auto-hibern8 timer, so every read has to bring the link out of hibern8
ah8_stress() { # $1 = label, $2 = iterations
	local n=${2:-300} i gap us fails e_a e_b
	us=$(cat $U/auto_hibern8 2>/dev/null)
	[ -n "$us" ] && [ "$us" -gt 0 ] || { info "ah8 stress $1: auto-hibern8 off"; return; }
	gap=$(awk -v u=$us 'BEGIN {printf "%.3f", u / 1e6 + 0.05}')
	kmsg_mark "ah8-$1"
	e_a=$(ah8_errs)
	fails=0
	for i in $(seq 1 $n); do
		dd if="$(findmnt -n -o SOURCE /)" of=/dev/null bs=4k count=1 skip=$((RANDOM * 32 + i)) iflag=direct 2> /dev/null || fails=$((fails + 1))
		sleep $gap
	done
	e_b=$(ah8_errs)
	[ "$fails" = 0 ] && [ "$e_b" = "$e_a" ] && ok "ah8 stress $1: $n hibern8 exits (gap ${gap}s), no errors" ||
		bad "ah8 stress $1: $fails failed reads, auto-hibern8 errors $e_a -> $e_b"
}
ah8_errs() { $S cat $DBG/stats 2>/dev/null | awk -F': ' '/Auto-hibernate/ {print $2 + 0}'; }

kmsg_mark start
echo "== driver / host"
drv=$(basename "$(readlink $U/driver 2>/dev/null)" 2>/dev/null)
[ "$drv" = ufshcd-kirin ] && ok "driver bound: $drv" || bad "driver bound: '${drv:-none}'"
vcc=$(for r in /sys/class/regulator/regulator.*; do [ "$(cat $r/name 2>/dev/null)" = ldo15 ] && echo "$(cat $r/state) $(cat $r/microvolts 2>/dev/null) uV users=$(cat $r/num_users)"; done)
[ -n "$vcc" ] && info "vcc (ldo15): $vcc" || info "vcc (ldo15) regulator not registered"
info "kernel $(uname -r), HCI version $(cat $U/device_descriptor/specification_version 2>/dev/null) (device spec)"

echo "== LUNs"
# LUN sizes in 512-byte sectors, from the vendor kernel
declare -A want=([0]=8192 [1]=131072 [2]=2621440 [3]=997433344)
for lun in 0 1 2 3; do
	d=/sys/bus/scsi/devices/0:0:0:$lun
	blk=$(ls $d/block 2>/dev/null)
	if [ -z "$blk" ]; then bad "LUN$lun has no block device"; continue; fi
	model=$(cat $d/model | tr -d ' ')
	size=$(cat /sys/block/$blk/size)
	[ "$size" = "${want[$lun]}" ] && [ "$model" = SDINFDO4-512G ] &&
		ok "LUN$lun = $blk $model $size sectors ro=$(cat /sys/block/$blk/ro)" ||
		bad "LUN$lun = $blk model '$model' size $size (want ${want[$lun]})"
done
dmesg_snap
for lun in 0 1 2; do
	blk=$(ls /sys/bus/scsi/devices/0:0:0:$lun/block 2>/dev/null)
	[ -n "$blk" ] || continue
	# device-level power-on write protection (fPowerOnWPEn armed by ufs-kirin)
	grep -q "\[$blk\] Write Protect is on" "$DM" && ok "LUN$lun ($blk) write-protected by the device" ||
		bad "LUN$lun ($blk) not write-protected by the device"
	[ "$(cat /sys/block/$blk/ro)" = 1 ] && ok "LUN$lun ($blk) read-only in the kernel" || bad "LUN$lun ($blk) ro=$(cat /sys/block/$blk/ro)"
done
rootdev=$(findmnt -no SOURCE /)
case $rootdev in /dev/sdd[0-9]*) ok "root on $rootdev" ;; *) bad "root on '$rootdev', want a partition of /dev/sdd" ;; esac
nparts=$(ls -d /sys/block/sdd/sdd* 2>/dev/null | wc -l)
[ "$nparts" -ge 7 ] && ok "sdd partitions: $nparts" || bad "sdd partitions: $nparts"

echo "== power mode"
g=$(cat $U/power_info/gear) l=$(cat $U/power_info/lane) m=$(cat $U/power_info/mode) r=$(cat $U/power_info/rate)
info "gear=$g lane=$l mode=$m rate=$r dev_pm=$(cat $U/power_info/dev_pm) link=$(cat $U/power_info/link_state)"
[ "$g" = HS_GEAR4 ] && [ "$l" = 2 ] && [ "$m" = FAST_MODE ] && [ "$r" = HS_RATE_B ] &&
	ok "power mode HS-G4 x2 rate B FAST" || bad "power mode $g x$l $r $m (want HS_GEAR4 x2 HS_RATE_B FAST_MODE)"
ah8=$(cat $U/auto_hibern8 2>/dev/null)
[ -n "$ah8" ] && [ "$ah8" -gt 0 ] && ok "auto-hibern8 enabled (${ah8} us)" || bad "auto-hibern8 '${ah8}'"
info "rpm_lvl=$(cat $U/rpm_lvl) spm_lvl=$(cat $U/spm_lvl)"
e0=$(stats)
show_stats
[ "$e0" = 0 ] && ok "no UFS error events since boot" || info "UFS event counters sum at start: $e0"

if [ "${UFS_TEST_QUICK:-0}" != 1 ]; then
	echo "== data integrity ($MB MiB sequential + 4 parallel writers + random direct I/O)"
	$S rm -rf $T && $S mkdir -p $T && $S chown "$(id -u)" $T
	avail=$(df -m --output=avail /var/tmp | tail -1)
	if [ "$avail" -lt $((MB * 2 + 1024)) ]; then MB=$(((avail - 1024) / 2)); info "only ${avail} MiB free, using $MB MiB"; fi
	kmsg_mark data
	t0=$(date +%s.%N)
	head -c ${MB}M /dev/urandom | tee $T/seq.bin | sha256sum | cut -d' ' -f1 > $T/seq.sha
	sync
	t1=$(date +%s.%N)
	for i in 1 2 3 4; do
		(head -c $((MB / 8))M /dev/urandom | tee $T/par$i.bin | sha256sum | cut -d' ' -f1 > $T/par$i.sha) &
	done
	wait
	sync
	# random 4 KiB..1 MiB direct writes of known content into a preallocated file
	python3 - "$T" << 'PY'
import os, random, hashlib, sys
d = sys.argv[1]
p = d + "/rand.bin"
size = 256 << 20
random.seed(410)
with open(p, "wb") as f:
    f.truncate(size)
fd = os.open(p, os.O_RDWR | os.O_DIRECT)
import mmap
shadow = bytearray(size)
for n in range(3000):
    ln = random.choice([4096, 16384, 65536, 262144, 1048576])
    off = random.randrange(0, size - ln, 4096)
    buf = mmap.mmap(-1, ln)
    data = random.randbytes(ln)
    buf.write(data)
    os.pwrite(fd, buf, off)
    shadow[off:off + ln] = data
os.fsync(fd)
os.close(fd)
open(d + "/rand.sha", "w").write(hashlib.sha256(shadow).hexdigest() + "\n")
PY
	sync
	t2=$(date +%s.%N)
	echo 3 | $S tee /proc/sys/vm/drop_caches > /dev/null
	bad_files=""
	for f in seq par1 par2 par3 par4 rand; do
		[ "$(sha256sum < $T/$f.bin | cut -d' ' -f1)" = "$(cat $T/$f.sha)" ] || bad_files="$bad_files $f"
	done
	t3=$(date +%s.%N)
	[ -z "$bad_files" ] && ok "data verified after drop_caches (seq/parallel/random)" || bad "checksum mismatch:$bad_files"
	info "$(awk -v a=$t0 -v b=$t1 -v c=$t2 -v d=$t3 -v m=$MB 'BEGIN {printf "seq write %.0f MB/s, total write %.1f s, verify read %.0f MB/s", m/(b-a), c-a, (m*1.5+256)/(d-c)}')"
	# direct read of the whole sequential file, bypassing the page cache
	dd if=$T/seq.bin of=/dev/null bs=4M iflag=direct 2>&1 | tail -1 | sed 's/^/INFO direct read: /'
	errs=$(ufs_errors_since data)
	[ -z "$errs" ] && ok "no UFS/block errors in dmesg during data test" || { bad "UFS/block errors during data test"; echo "$errs" | head -20; }
	$S rm -rf $T
fi

echo "== auto-hibern8 (fresh link)"
ah8_stress fresh ${UFS_TEST_AH8:-300}

echo "== host reset (error handler path: full UFS subsystem re-init)"
kmsg_mark reset
e_before=$(stats)
$S python3 -c '
import fcntl, os, struct
fd = os.open("/dev/sdd", os.O_RDONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, 0x2284, struct.pack("i", 3))   # SG_SCSI_RESET, SG_SCSI_RESET_HOST
os.close(fd)' && ok "host reset issued" || bad "host reset ioctl failed"
sleep 2
dd if="$(findmnt -n -o SOURCE /)" of=/dev/null bs=1M count=64 iflag=direct 2> /dev/null && ok "I/O after host reset" || bad "I/O after host reset"
g=$(cat $U/power_info/gear)
[ "$g" = HS_GEAR4 ] && ok "HS-G4 restored after reset" || bad "gear after reset: $g"
dmesg_snap
sed -n "/l410-ufs-test: $RUNID reset/,\$p" "$DM" | grep -E "ufshcd|f8200000" | head -10 | sed 's/^/INFO   /'

echo "== runtime PM (rpm_lvl 1 = link hibern8; rpm_lvl 5 = device powerdown + link off only with UFS_TEST_RPM5=1)"
rpm_cycle() { # $1 = rpm_lvl
	local lvl=$1 i st n0 n1
	echo "$lvl" | $S tee $U/rpm_lvl > /dev/null
	for d in /sys/bus/scsi/devices/0:0:0:*/power/control $U/power/control; do echo auto | $S tee $d > /dev/null; done
	for d in /sys/bus/scsi/devices/0:0:0:*/power/autosuspend_delay_ms; do echo 1000 | $S tee $d > /dev/null 2>&1; done
	n0=$(cat $U/power/runtime_suspended_time)
	st=""
	for i in $(seq 1 30); do
		sleep 1
		st=$(cat $U/power/runtime_status)
		[ "$st" = suspended ] && break
	done
	n1=$(cat $U/power/runtime_suspended_time)
	if [ "$st" = suspended ] || [ "$n1" -gt "$n0" ]; then
		ok "rpm_lvl=$lvl: host runtime-suspended (status $st, link $(cat $U/power_info/link_state), dev $(cat $U/power_info/dev_pm))"
	else
		info "rpm_lvl=$lvl: host never runtime-suspended in 30 s (status $st; root fs busy?)"
	fi
	dd if="$(findmnt -n -o SOURCE /)" of=/dev/null bs=1M count=16 skip=$((RANDOM % 1000)) iflag=direct 2> /dev/null &&
		ok "rpm_lvl=$lvl: I/O after runtime resume" || bad "rpm_lvl=$lvl: I/O after runtime resume"
}
kmsg_mark rpm
rpm_old=$(cat $U/rpm_lvl)
rpm_cycle 1
# rpm_lvl 5 (device powerdown + link off) is never used (runtime 1, system sleep 3). After
# its full re-init the first auto-hibern8 exit fails once and the error handler recovers in
# ~170 ms (docs/testing/test-plan.md M4, known): that run would make the error checks below fail,
# so it is opt-in.
if [ "${UFS_TEST_RPM5:-0}" = 1 ]; then
	rpm_cycle 5
else
	info "rpm_lvl=5 not exercised (unused level, known issue M4; UFS_TEST_RPM5=1 runs it)"
fi
echo "$rpm_old" | $S tee $U/rpm_lvl > /dev/null
for d in /sys/bus/scsi/devices/0:0:0:*/power/control $U/power/control; do echo on | $S tee $d > /dev/null; done
errs=$(ufs_errors_since rpm)
[ -z "$errs" ] && ok "no UFS errors during runtime PM" || { bad "UFS errors during runtime PM"; echo "$errs" | head -20; }

echo "== auto-hibern8 (after resets and runtime PM)"
ah8_stress after ${UFS_TEST_AH8:-300}

echo "== error counters"
show_stats
e1=$(stats)
info "UFS error event counters: start $e0, end $e1"
[ "$e1" = "$e0" ] && ok "no new UFS error events during the test" || bad "$((e1 - e0)) new UFS error events"

rm -f "$DM"
echo "SUMMARY ufs: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
