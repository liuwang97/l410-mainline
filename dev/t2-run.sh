#!/bin/bash
# T2 integration regression over the home WLAN (docs/testing/test-plan.md T2): every unattended
# A-class script that is safe with the desktop running, one after the other, results copied
# back. Runs in Git Bash on the Windows host.
#
#   dev/t2-run.sh [--soak SECONDS] [--sweep] [--cycle N]
#
# Always: quick.sh, desktop-cfg.sh, mem.sh (config + 130% pressure), perf.sh, the track
# suite (smoke soc-core power ufs usb pcie audio laptop wifi-bt, detached from ssh), l410-diag.
# --soak    soak-mix.sh for SECONDS (REL-03 short form, default off)
# --sweep   sysfs-sweep.sh (REL-08; a hang would need the power key: last file is logged)
# --cycle N tests/cycle.sh with N warm reboots (BOOT-03/11; ends on the test kernel)
# Not here (need a person or stop the desktop): graphics.sh (takes DRM master from KWin),
# display-power.sh, suspend.sh, S/M/L cases.
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
SOAK=0 SWEEP=0 CYCLE=0
while [ $# -gt 0 ]; do
	case $1 in
	--soak) SOAK=$2; shift 2 ;;
	--sweep) SWEEP=1; shift ;;
	--cycle) CYCLE=$2; shift 2 ;;
	*) sed -n '2,15p' "$0"; exit 2 ;;
	esac
done
SSH_OPTS=(-i ${L410_SSH_KEY:-$HOME/.ssh/id_ed25519} -o IdentitiesOnly=yes
	  -o ConnectTimeout=20 -o ServerAliveInterval=15)
HOST=${L410_SSH:-user@l410}	# ssh destination of the L410
ssh_() { ssh -p ${L410_SSH_PORT:-22} "${SSH_OPTS[@]}" $HOST "$@"; }
OUT=$HOME/l410-t2/$(date +%Y%m%d-%H%M); mkdir -p "$OUT"
UE='export XDG_RUNTIME_DIR=/run/user/${L410_UID:-1000} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${L410_UID:-1000}/bus WAYLAND_DISPLAY=wayland-0'
res() { printf '%-14s %s\n' "$1" "$2" | tee -a "$OUT/summary.txt"; }

scp -q -O -P ${L410_SSH_PORT:-22} "${SSH_OPTS[@]}" "$REPO"/tests/{quick.sh,desktop-cfg.sh,mem.sh,perf.sh,soak-mix.sh,sysfs-sweep.sh,cycle.sh} \
	"$REPO/tools/l410-diag" "$REPO/dev/testrig-nosleep.sh" $HOST:l410-bench/ || { echo "the L410 unreachable"; exit 1; }
ssh_ "sudo sh -c 'echo 0 > /sys/kernel/l410_deadman/timeout; touch /run/l410-keep'; $UE; bash ~/l410-bench/testrig-nosleep.sh off > /dev/null 2>&1 || true"
res start "$(ssh_ 'uname -r; . /etc/os-release; echo $PRETTY_NAME' | tr '\n' ' ')"

run() {	# run <name> <remote command>
	local n=$1; shift
	ssh_ "$*" > "$OUT/$n.txt" 2>&1
	res "$n" "$(grep -E '^RESULT' "$OUT/$n.txt" | tail -1) $(grep -cE '^(FAIL|FAIL:)' "$OUT/$n.txt") FAIL lines"
}
run quick "sudo bash ~/l410-bench/quick.sh"
run desktop-cfg "sudo bash ~/l410-bench/desktop-cfg.sh --no-apt"
run mem "sudo bash ~/l410-bench/mem.sh --load over --secs 60"
run perf "sudo bash ~/l410-bench/perf.sh"
L410_SUITE_LOGS="$OUT" bash "$REPO/dev/suite-remote.sh" t2 smoke soc-core power ufs usb pcie audio laptop wifi-bt > "$OUT/suite-run.txt" 2>&1
res suite "$(sed -n '/########## SUMMARY/,$p' "$OUT/t2.log" 2> /dev/null | grep -c PASS) PASS, $(sed -n '/########## SUMMARY/,$p' "$OUT/t2.log" 2> /dev/null | grep -c FAIL) FAIL"
ssh_ "sudo bash ~/l410-bench/l410-diag /var/tmp" > "$OUT/diag.txt" 2>&1; res l410-diag "$(tail -1 "$OUT/diag.txt")"
[ "$SOAK" -gt 0 ] && run soak "$UE; sudo -E bash ~/l410-bench/soak-mix.sh $SOAK"
[ "$SWEEP" = 1 ] && run sweep "sudo bash ~/l410-bench/sysfs-sweep.sh all"
if [ "$CYCLE" -gt 0 ]; then
	ssh_ "sudo bash ~/l410-bench/cycle.sh start $CYCLE" > "$OUT/cycle-start.txt" 2>&1
	res cycle "started $CYCLE warm reboots; check later: ssh $HOST sudo bash ~/l410-bench/cycle.sh status"
fi
echo "results: $OUT"
