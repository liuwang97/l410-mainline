#!/bin/bash
# Mixed-load soak (docs/testing/test-plan.md REL-01/03, THM-04, MEM-02, UFS-04, GPU-04 short form).
# Runs everything at once for DURATION seconds and judges the machine afterwards:
#   CPU      stress-ng --cpu 8 with verification
#   memory   stress-ng --vm 1 GiB with verification
#   storage  fio verify (crc32c) on a 1 GiB file in /var/tmp, random write + read-back loop
#   GPU      glmark2-es2-wayland --run-forever in the desktop session (off-screen size)
#   audio    a silent PipeWire stream (DMA, codec and amps busy, nothing audible)
#   WiFi     ping to the gateway every second, a 100 MB download every 5 minutes
#   camera   a 30-frame grab every 5 minutes
#   EC       battery/AC read every 10 s
# Watches temperatures and throttling. Needs root; the GPU/audio parts need the Plasma session.
#
#   sudo bash tests/soak-mix.sh [seconds=3600]
# Result lines as in tests/quick.sh, last line RESULT. Output in /var/tmp/l410-soak/<time>/.
if [ "$(id -u)" != 0 ]; then
	if [ -f "$0" ]; then exec sudo -n bash "$0" "$@"; else exec sudo -n bash -s -- "$@"; fi
fi
DUR=${1:-3600}
OUT=/var/tmp/l410-soak/$(date +%Y%m%d-%H%M%S); mkdir -p $OUT
NF=0
res() { printf '%-5s %-20s %s\n' "$1" "$2" "$3" | tee -a $OUT/results.txt; [ "$1" = FAIL ] && NF=$((NF + 1)); return 0; }
pass() { res PASS "$@"; }; fail() { res FAIL "$@"; }; warn() { res WARN "$@"; }; info() { res INFO "$@"; }
U=$(loginctl list-sessions --no-legend | awk '$3 != "root" && $3 != "sddm" { print $3; exit }'); U=${U:-$(id -un ${L410_UID:-1000})}; UIDN=$(id -u $U)
UE="XDG_RUNTIME_DIR=/run/user/$UIDN WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UIDN/bus"
CURSOR=$(journalctl -k -n 0 --show-cursor 2> /dev/null | sed -n 's/^-- cursor: //p')
touch /run/l410-keep; echo 0 > /sys/kernel/l410_deadman/timeout 2> /dev/null
PIDS=""
cleanup() {
	for p in $PIDS; do kill $p 2> /dev/null; done
	pkill -x stress-ng; pkill -x fio; pkill -u $U -x glmark2-es2-wayland; pkill -u $U -x pw-cat
	rm -f /var/tmp/l410-soak.fio
}
trap cleanup EXIT
info soak.start "$(uname -r), $DUR s, mode $(sed 's/.*\[\(.*\)\].*/\1/' /sys/kernel/l410_perf/mode 2> /dev/null), battery $(cat /sys/class/power_supply/echub-battery/capacity 2> /dev/null)% AC $(cat /sys/class/power_supply/echub-ac/online 2> /dev/null)"

stress-ng --cpu 8 --cpu-method all --verify --timeout ${DUR}s --metrics-brief > $OUT/cpu.txt 2>&1 & PIDS="$PIDS $!"
stress-ng --vm 1 --vm-bytes 1G --vm-method all --verify --timeout ${DUR}s --metrics-brief > $OUT/vm.txt 2>&1 & PIDS="$PIDS $!"
fio --name=soak --filename=/var/tmp/l410-soak.fio --size=1G --rw=randwrite --bs=64k --ioengine=libaio --iodepth=8 \
	--direct=1 --verify=crc32c --verify_fatal=1 --do_verify=1 --loops=1000 --time_based --runtime=$DUR \
	--output=$OUT/fio.txt > /dev/null 2>&1 & PIDS="$PIDS $!"
if [ -S /run/user/$UIDN/bus ] && command -v glmark2-es2-wayland > /dev/null; then
	su $U -c "$UE glmark2-es2-wayland --run-forever --size 800x600 -b build:use-vbo=true -b texture -b shading" > $OUT/glmark2.txt 2>&1 & PIDS="$PIDS $!"
fi
if [ -S /run/user/$UIDN/bus ] && command -v pw-cat > /dev/null; then
	# silence: the playback path runs, nothing is heard
	su $U -c "$UE sh -c 'head -c $((48000 * 4 * DUR)) /dev/zero | pw-cat --playback --rate 48000 --channels 2 --format s16 -'" > $OUT/audio.txt 2>&1 & PIDS="$PIDS $!"
fi
GW=$(ip route show default | awk '{ print $3; exit }')
ping -i 1 -W 2 $GW > $OUT/ping.txt 2>&1 & PING=$!; PIDS="$PIDS $PING"

t0=$(date +%s); n=0; dl_ok=0; dl_fail=0; cam_ok=0; cam_fail=0; ec_fail=0; tmax=0
while [ $(($(date +%s) - t0)) -lt $DUR ]; do
	sleep 10; n=$((n + 1))
	cat /sys/class/power_supply/echub-battery/voltage_now > /dev/null 2>&1 || ec_fail=$((ec_fail + 1))
	for z in /sys/class/thermal/thermal_zone*/temp; do t=$(cat $z 2> /dev/null); [ "${t:-0}" -gt $tmax ] && tmax=$t; done
	echo "$(date +%s) $(cat /sys/class/thermal/thermal_zone*/temp 2> /dev/null | tr '\n' ' ') f $(cat /sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq | tr '\n' ' ')" >> $OUT/thermal.txt
	if [ $((n % 30)) = 0 ]; then
		curl -s -o /dev/null --max-time 120 -r 0-104857599 https://mirrors.ustc.edu.cn/debian/dists/forky/main/Contents-arm64.gz -w '%{http_code} %{size_download} %{speed_download}\n' >> $OUT/download.txt 2>&1 &&
			dl_ok=$((dl_ok + 1)) || dl_fail=$((dl_fail + 1))
		v=$(ls /dev/video* 2> /dev/null | head -1)
		[ -n "$v" ] && { timeout 20 v4l2-ctl -d $v --stream-mmap --stream-count=30 --stream-to=/dev/null > /dev/null 2>&1 && cam_ok=$((cam_ok + 1)) || cam_fail=$((cam_fail + 1)); }
	fi
done
kill $PING 2> /dev/null; sleep 5
for p in $PIDS; do wait $p 2> /dev/null; done 2> /dev/null

grep -qE "successful run completed|passed:" $OUT/cpu.txt && ! grep -qiE "fail|error" <(grep -vE "^stress-ng: (info|metrc)" $OUT/cpu.txt) && pass soak.cpu "stress-ng cpu verified ($(grep -oE 'passed: [0-9]+' $OUT/cpu.txt | head -1))" || fail soak.cpu "$(tail -3 $OUT/cpu.txt | tr '\n' ' ')"
grep -qE "successful run completed|passed:" $OUT/vm.txt && ! grep -qiE "fail|error" <(grep -vE "^stress-ng: (info|metrc)" $OUT/vm.txt) && pass soak.memory "stress-ng vm 1 GiB verified" || fail soak.memory "$(tail -3 $OUT/vm.txt | tr '\n' ' ')"
if grep -qE "err= *0" $OUT/fio.txt && ! grep -q "verify:" <(grep -i "bad\|mismatch" $OUT/fio.txt); then pass soak.ufs-verify "fio crc32c verify: $(grep -oE 'WRITE: bw=[^,]*' $OUT/fio.txt | head -1)"; else fail soak.ufs-verify "$(grep -iE 'err=|verify|bad' $OUT/fio.txt | head -3 | tr '\n' ' ')"; fi
if [ -s $OUT/glmark2.txt ]; then
	grep -qiE "error|failed|lost" $OUT/glmark2.txt && fail soak.gpu "$(grep -iE 'error|failed|lost' $OUT/glmark2.txt | head -2 | tr '\n' ' ')" || pass soak.gpu "glmark2 ran $DUR s ($(grep -c FPS $OUT/glmark2.txt) scenes)"
fi
# from the replies themselves: ping prints its summary only on SIGINT, and it is stopped with SIGTERM
x=$(awk -F'icmp_seq=' '/icmp_seq=/ { split($2, a, " "); n++; if (a[1] + 0 > m) m = a[1] + 0 } END { if (m) printf "%.2f", (m - n) * 100 / m }' $OUT/ping.txt)
awk -v l=${x:-100} 'BEGIN { exit !(l < 1) }' && pass soak.wifi "ping $GW: ${x}% loss; downloads ok $dl_ok fail $dl_fail" || fail soak.wifi "ping $GW: ${x:-?}% loss; downloads ok $dl_ok fail $dl_fail"
[ $dl_fail = 0 ] || warn soak.download "$dl_fail of $((dl_ok + dl_fail)) downloads failed"
[ $cam_fail = 0 ] && pass soak.camera "$cam_ok camera grabs" || fail soak.camera "$cam_fail of $((cam_ok + cam_fail)) camera grabs failed"
[ $ec_fail = 0 ] && pass soak.ec "battery read every 10 s, 0 failures" || fail soak.ec "$ec_fail battery read failures"
[ $tmax -lt 95000 ] && pass soak.thermal "hottest zone $((tmax / 1000)) C (< 95)" || fail soak.thermal "hottest zone $((tmax / 1000)) C"
journalctl -k --after-cursor "$CURSOR" --no-pager -o short-monotonic > $OUT/klog.txt 2> /dev/null
# 10-01: an i2c-6 hang (touchpad dead) went through as "no kernel errors": bus and HCI timeouts count too
KBAD='Internal error|Unable to handle|SError|BUG:|WARNING: CPU|Oops|rcu.*stall|soft lockup|hung_task|blocked for more than|underflow|completion timeout|panfrost.*(fault|timeout|reset)|I/O error|ufshcd.*(error|abort)|controller timed out|lost arbitration|i2c_hid.*(failed|-110)|command 0x[0-9a-f]+ tx timeout|beat timeout|xhci.*(died|halt failed)'
x=$(grep -cE "$KBAD" $OUT/klog.txt)
[ "$x" = 0 ] && pass soak.klog "no kernel errors in $DUR s" || fail soak.klog "$x error lines, first: $(grep -m1 -E "$KBAD" $OUT/klog.txt | cut -c1-160)"
pgrep -x kwin_wayland > /dev/null && pgrep -x plasmashell > /dev/null && pass soak.session "desktop alive" || fail soak.session "kwin_wayland or plasmashell gone"
echo "RESULT: $([ $NF = 0 ] && echo PASS || echo "FAIL ($NF)")"
echo "OUT: $OUT"
exit $NF
