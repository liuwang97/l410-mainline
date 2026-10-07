#!/bin/bash
# Run tests/quick.sh on the L410 over ssh and copy the result directory back.
# Works from Git Bash on the Windows host and from WSL.
#   dev/quick-remote.sh [quick.sh options, e.g. --fast --only ufs,usb]
# L410_SSH   ssh command for the target (default: the home-WLAN address in CLAUDE.md)
# L410_QUICK_LOGS   local directory for the results (default ~/l410-quick-logs)
# Exit status is quick.sh's: the number of unexpected FAILs (255: ssh failed).
REPO=$(cd "$(dirname "$0")/.." && pwd)
SSH=${L410_SSH_CMD:-"ssh -o ConnectTimeout=20 -o ServerAliveInterval=15 ${L410_SSH:-user@l410}"}
LOGS=${L410_QUICK_LOGS:-$HOME/l410-quick-logs}
mkdir -p "$LOGS"
LOG=$(mktemp)
# shellcheck disable=SC2086
$SSH "sudo bash -s -- $*" < "$REPO/tests/quick.sh" | tee "$LOG"
rc=${PIPESTATUS[0]}
out=$(sed -n 's/^OUT: //p' "$LOG" | tail -1)
if [ -n "$out" ]; then
	dst="$LOGS/$(basename "$out")"
	mkdir -p "$dst"
	# shellcheck disable=SC2086
	$SSH "sudo tar -C '$out' -cf - ." | tar -C "$dst" -xf - && echo "results copied to $dst"
fi
rm -f "$LOG"
exit $rc
