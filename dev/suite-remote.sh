#!/bin/bash
# Run a suite of tests/*.sh on the L410 over the home WLAN, detached from ssh: the suite runs
# in a transient system unit on the L410 (each test in its own unit, 15 min cap, as mk-suite.sh
# builds it), so a WiFi drop in the middle (a test taking wlan0 down) does not kill it.
# Polls until it ends, then copies the log back. Runs in Git Bash on the Windows host.
#
#   dev/suite-remote.sh <name> <test> [test...]      e.g. t2 smoke soc-core power ufs
#
# Log: the L410 /var/log/l410-suite/<name>.log, locally ~/l410-suite-logs/<name>.log.
set -e
NAME=$1; shift
[ -n "$NAME" ] && [ $# -gt 0 ] || { sed -n '2,10p' "$0"; exit 2; }
REPO=$(cd "$(dirname "$0")/.." && pwd)
SSH_OPTS=(-i ${L410_SSH_KEY:-$HOME/.ssh/id_ed25519} -o IdentitiesOnly=yes
	  -o ConnectTimeout=20 -o ConnectionAttempts=3 -o ServerAliveInterval=15)
HOST=${L410_SSH:-user@l410}	# ssh destination of the L410
ssh_() { ssh -p ${L410_SSH_PORT:-22} "${SSH_OPTS[@]}" $HOST "$@"; }
LOGS=${L410_SUITE_LOGS:-$HOME/l410-suite-logs}
mkdir -p "$LOGS"
S=$(mktemp)
bash "$REPO/dev/mk-suite.sh" "$S" "$@" > /dev/null
scp -q -O -P ${L410_SSH_PORT:-22} "${SSH_OPTS[@]}" "$S" $HOST:/var/tmp/l410-suite-$NAME.sh
rm -f "$S"
ssh_ "sudo bash -s" << EOF
set -e
mkdir -p /var/log/l410-suite
touch /run/l410-keep; echo 0 > /sys/kernel/l410_deadman/timeout 2>/dev/null || true
systemctl reset-failed l410-suite-$NAME 2>/dev/null || true
systemd-run --quiet --collect --unit=l410-suite-$NAME -p StandardOutput=file:/var/log/l410-suite/$NAME.log \
	-p StandardError=inherit bash /var/tmp/l410-suite-$NAME.sh
echo "started l410-suite-$NAME"
EOF
n=0
while :; do
	sleep 30
	if st=$(ssh_ "systemctl is-active l410-suite-$NAME; grep '^##########' /var/log/l410-suite/$NAME.log | tail -1" 2> /dev/null); then
		n=0
		echo "$(date +%T) $(echo $st | tr '\n' ' ')"
		case $(echo "$st" | head -1) in active|activating) ;; *) break ;; esac
	else
		n=$((n + 1)); echo "$(date +%T) no ssh ($n)"
		[ $n -lt 40 ] || { echo "no ssh for 20 minutes"; exit 1; }
	fi
done
ssh_ "cat /var/log/l410-suite/$NAME.log" > "$LOGS/$NAME.log"
sed -n '/^########## SUMMARY/,$p' "$LOGS/$NAME.log"
echo "log: $LOGS/$NAME.log"
