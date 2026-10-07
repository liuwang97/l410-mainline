#!/bin/bash
# L410 hardware test harness. Runs in WSL. Only ONE hardware test at a time (flock).
#
#   l410-harness.sh test <bundle-dir> [--name N] [--script remote.sh] [--host-script local.sh]
#                        [--timeout SEC] [--stay]
#       Deploy bundle (Image, l410.dtb, initrd.img, boot.cfg, optional modules.tar.gz) to the
#       Debian partition, grub-reboot into 'l410-test', wait, run the optional test script on
#       the test kernel, collect logs, reboot back to the default entry (Kylin 2203).
#       --host-script runs a WSL-side script while the test kernel is up (e.g. bulk transfers
#       through ssh); its output is host-test.out and its rc counts toward the result.
#       If the test kernel never answers ssh, wait for the deadman/auto-revert and pull the
#       pstore console log from Kylin instead.
#   l410-harness.sh run '<cmd>'     run a command on the L410 (shared lock; waits for a running test)
#   l410-harness.sh on-debian <script> [stage-dir]
#       boot Debian 13 once with its own 4.19 kernel, stage files to /var/cache/l410-stage,
#       run the script as root there, come back (package installs must happen this way)
#   l410-harness.sh status          which kernel the L410 is running now
#   l410-harness.sh to-kylin        make sure the L410 is back on the default Kylin 2203 kernel
#   l410-harness.sh pstore          dump the newest pstore console log archived on Kylin
#
# Logs: ~/l410/testlogs/<timestamp>-<name>/  (result, console-ramoops.txt, dmesg.txt, test.out ...)
# Run from a private copy: the script lives on /mnt/c (drvfs), where replacing the file
# under a running bash kills it ("error reading input file").
if [ -z "$L410_SNAPSHOT" ]; then
	snap=$(mktemp /tmp/l410-$(basename "$0" .sh).XXXXXX.sh)
	cp "$0" "$snap"
	L410_SNAPSHOT=$snap exec bash "$snap" "$@"
fi
trap 'rm -f "$L410_SNAPSHOT"' EXIT
export -n L410_SNAPSHOT
set -o pipefail
L=${L410_HOME:-$HOME/l410}
LOCK=$L/.hwlock
LOGROOT=$L/testlogs
DEB_UUID=${DEB_UUID:?set DEB_UUID to the UUID of the Debian root filesystem}
KYLIN_KVER=4.19.71-23-kr990
SSHO=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3)
L410_HOST=${L410_SSH:-l410}	# ssh host or alias of the L410 (key login, passwordless sudo)

log() { echo "[$(date +%T)] $*" >&2; }
rsh() { ssh "${SSHO[@]}" "$L410_HOST" "$@"; }
kver() { timeout 25 ssh "${SSHO[@]}" "$L410_HOST" uname -r 2>/dev/null; }

wait_down() {
	local end=$(($(date +%s) + ${1:-180}))
	while [ "$(date +%s)" -lt $end ]; do kver > /dev/null || return 0; sleep 3; done
	return 1
}
wait_up() {
	local end=$(($(date +%s) + ${1:-1500})) v
	while [ "$(date +%s)" -lt $end ]; do
		v=$(kver) && [ -n "$v" ] && { echo "$v"; return 0; }
		sleep 10
	done
	return 1
}

# on Kylin: make sure the Debian root is mounted, print mount point
deb_mnt() {
	rsh "M=\$(findmnt -rno TARGET -S UUID=$DEB_UUID | head -1); if [ -z \"\$M\" ]; then sudo mkdir -p /mnt/l410-deb && sudo mount UUID=$DEB_UUID /mnt/l410-deb && M=/mnt/l410-deb; fi; echo \$M"
}

# on Kylin: id of the newest boot recorded in the Debian journal
deb_lastboot() {
	rsh "sudo chroot $1 journalctl -D /var/log/journal --list-boots --no-pager -q 2>/dev/null | tail -1 | awk '{print \$2}'"
}

to_kylin() {
	local v
	v=$(kver) || v=""
	if [ "$v" = "$KYLIN_KVER" ]; then return 0; fi
	if [ -n "$v" ]; then
		log "the L410 runs $v, rebooting to default entry"
		# a test kernel that hangs while shutting down must not sit on a long deadman:
		# 240 s means FIQ panic -> PSCI reset after ~120 s, SP805 reset at 240 s
		rsh 'echo 240 | sudo tee /sys/kernel/l410_deadman/timeout' > /dev/null 2>&1 || true
		rsh 'sudo systemctl reboot --force' > /dev/null 2>&1 || true
		wait_down 180 || { log "the L410 did not go down"; }
	else
		log "the L410 not answering; waiting for it (deadman / auto-revert)"
	fi
	v=$(wait_up 1800) || { log "the L410 did not come back"; return 1; }
	[ "$v" = "$KYLIN_KVER" ] || { log "the L410 came back with $v, not Kylin"; return 1; }
	return 0
}

collect_pstore() { # $1 = logdir, $2 = t0 (the L410 epoch before the test reboot)
	rsh "sudo sh -c 'cd /var/lib/systemd/pstore 2>/dev/null && for f in \$(find . -type f -newermt @$2 | sort); do echo \"===== \$f\"; cat \"\$f\"; done; cd /sys/fs/pstore && for f in *; do [ -f \"\$f\" ] && { echo \"===== sysfs:\$f\"; cat \"\$f\"; }; done'" > "$1/pstore.txt" 2>&1
	grep -c . "$1/pstore.txt" > /dev/null && log "pstore: $(wc -c < "$1/pstore.txt") bytes -> $1/pstore.txt"
}

cmd_test() {
	local bundle=$1; shift
	local name=test script="" hscript="" timeout=1500 stay=0
	while [ $# -gt 0 ]; do
		case $1 in
		--name) name=$2; shift 2 ;;
		--script) script=$2; shift 2 ;;
		--host-script) hscript=$2; shift 2 ;;
		--timeout) timeout=$2; shift 2 ;;
		--stay) stay=1; shift ;;
		*) echo "unknown arg $1"; return 2 ;;
		esac
	done
	[ -f "$bundle/Image" ] && [ -f "$bundle/boot.cfg" ] || { echo "bundle needs Image and boot.cfg"; return 2; }
	local ld="$LOGROOT/$(date +%Y%m%d-%H%M%S)-$name"
	mkdir -p "$ld"
	cp "$bundle/boot.cfg" "$ld/"
	[ -f "$bundle/kver" ] && cp "$bundle/kver" "$ld/"
	log "test '$name' logs -> $ld"

	to_kylin || { echo "FAIL-INFRA the L410 not on Kylin" > "$ld/result"; cat "$ld/result"; return 3; }
	local M
	M=$(deb_mnt) || { echo "FAIL-INFRA cannot mount Debian root" > "$ld/result"; return 3; }
	log "deploying to the L410:$M/boot/l410"
	rsh 'rm -rf /tmp/l410-deploy && mkdir -p /tmp/l410-deploy'
	scp -O -q "${SSHO[@]}" "$bundle"/* "$L410_HOST":/tmp/l410-deploy/ || { echo "FAIL-INFRA scp" > "$ld/result"; return 3; }
	rsh "set -e; cd /tmp/l410-deploy; sudo mkdir -p $M/boot/l410; for f in Image l410.dtb initrd.img boot.cfg; do [ -f \$f ] && sudo install -m 644 \$f $M/boot/l410/\$f; done; K=\$(cat kver 2>/dev/null); [ -n \"\$K\" ] && sudo rm -rf $M/lib/modules/\$K; if [ -f modules.tar.gz ]; then sudo tar xzf modules.tar.gz -C $M --no-same-owner; fi; ls -1dt $M/lib/modules/6.18.* 2>/dev/null | tail -n +7 | xargs -r sudo rm -rf; sync; ls -la $M/boot/l410" > "$ld/deploy.txt" 2>&1 ||
		{ echo "FAIL-INFRA deploy" > "$ld/result"; cat "$ld/deploy.txt"; return 3; }

	local t0 jprev
	t0=$(rsh 'date +%s')
	jprev=$(deb_lastboot "$M")
	log "grub-reboot l410-test + reboot (t0=$t0)"
	rsh 'sudo mount -o remount,rw /boot && sudo grub-reboot l410-test; sudo mount -o remount,ro /boot; sudo grub-editenv /boot/grub/grubenv list' > "$ld/grubenv.txt" 2>&1
	grep -q "next_entry=l410-test" "$ld/grubenv.txt" || { echo "FAIL-INFRA grub-reboot" > "$ld/result"; cat "$ld/grubenv.txt"; return 3; }
	rsh 'sudo systemctl reboot --force' > /dev/null 2>&1 || true
	wait_down 180 || log "WARN: the L410 did not go down within 180s"
	local v
	v=$(wait_up "$timeout") || v=""
	echo "$v" > "$ld/kver-seen"
	if [ -n "$v" ] && [ "$v" != "$KYLIN_KVER" ]; then
		log "test kernel up: $v"
		# deadman heartbeat: 600 s (FIQ panic at 300 s) re-armed every 120 s while we can reach the
		# target; if a test wedges the network the heartbeat stops and the L410 resets within ~5 min
		rsh 'echo 600 | sudo tee /sys/kernel/l410_deadman/timeout > /dev/null 2>&1; sudo touch /run/l410-keep' || true
		( while sleep 120; do timeout 30 ssh "${SSHO[@]}" "$L410_HOST" 'echo 600 | sudo tee /sys/kernel/l410_deadman/timeout > /dev/null' 2> /dev/null; done ) &
		local hb=$!
		rsh 'sudo dmesg' > "$ld/dmesg.txt" 2>&1
		rsh 'cat /proc/cmdline; uname -a; sudo cat /sys/kernel/debug/devices_deferred 2>/dev/null; ls /sys/bus/platform/drivers' > "$ld/sysinfo.txt" 2>&1
		local rc=0
		if [ -n "$script" ]; then
			log "running $script"
			# test scripts run as root (debugfs, /dev/rtc0, i2c, sysfs writes)
			timeout 3000 ssh "${SSHO[@]}" "$L410_HOST" 'sudo bash -s' < "$script" > "$ld/test.out" 2>&1
			rc=$?
			log "test script rc=$rc"
		fi
		if [ -n "$hscript" ]; then
			log "running host-side $hscript"
			timeout 3000 bash "$hscript" > "$ld/host-test.out" 2>&1
			local hrc=$?
			log "host script rc=$hrc"
			[ $rc = 0 ] && rc=$hrc
		fi
		kill $hb 2> /dev/null
		echo "BOOT-OK $v script-rc=$rc" > "$ld/result"
		if [ $stay = 0 ]; then to_kylin || log "WARN: could not return to Kylin"; fi
	elif [ "$v" = "$KYLIN_KVER" ]; then
		log "came back on Kylin: test kernel did not reach ssh"
		echo "NO-SSH (test kernel never answered ssh; back on Kylin)" > "$ld/result"
	else
		log "the L410 unreachable after ${timeout}s"
		echo "BOOT-FAIL (unreachable)" > "$ld/result"
		to_kylin || { echo "FAIL-INFRA the L410 lost" >> "$ld/result"; }
	fi
	if [ "$(kver)" = "$KYLIN_KVER" ]; then
		collect_pstore "$ld" "$t0"
		# the test kernel's own Debian journal, if it got that far (masked systemd-pstore keeps pstore intact)
		M=$(deb_mnt)
		local jnow
		jnow=$(deb_lastboot "$M")
		if [ -n "$jnow" ] && [ "$jnow" != "$jprev" ]; then
			rsh "sudo chroot $M journalctl -D /var/log/journal -b $jnow -o short-monotonic --no-pager" > "$ld/debian-journal.txt" 2>&1
			log "debian journal of test boot: $(wc -l < "$ld/debian-journal.txt") lines"
		fi
	fi
	if [ -s "$ld/pstore.txt" ]; then
		local p="$ld/pstore.txt" s=""
		grep -q "Linux version 6\." "$p" && s="$s kernel-started"
		grep -q "L410INIT: start" "$p" && s="$s initramfs"
		grep -q "L410INIT: switch_root" "$p" && s="$s switch_root"
		grep -q "systemd\[1\]" "$p" && s="$s systemd"
		grep -q "Kernel panic" "$p" && s="$s PANIC"
		grep -qi "Internal error\|Unable to handle kernel\|SError" "$p" && s="$s OOPS"
		grep -q "l410-revert" "$p" && s="$s auto-reverted"
		echo "pstore:${s:- (no 6.x log found)}" >> "$ld/result"
	fi
	rsh 'cat /proc/cmdline' > "$ld/kylin-cmdline-after.txt" 2>&1
	log "RESULT: $(cat "$ld/result")"
	cat "$ld/result"
	echo "logs: $ld"
}

# Boot the existing Debian 13 once with its own 4.19 vendor kernel (GRUB entry debian13),
# optionally stage a directory into /var/cache/l410-stage on sdd7 first, run a script there
# as root, return to Kylin. For work that must run inside Debian (e.g. dpkg: Kylin's endpoint
# security blocks package-manager execution, even in a chroot).
cmd_ondebian() {
	local script=$1 stage=$2
	[ -f "$script" ] || { echo "usage: on-debian <script> [stage-dir]"; return 2; }
	local ld="$LOGROOT/$(date +%Y%m%d-%H%M%S)-on-debian"
	mkdir -p "$ld"
	to_kylin || { echo "FAIL-INFRA the L410 not on Kylin"; return 3; }
	local M
	M=$(deb_mnt) || return 3
	rsh "sudo rm -rf $M/var/cache/l410-stage; sudo mkdir -p $M/var/cache/l410-stage"
	if [ -n "$stage" ]; then
		rsh 'rm -rf /tmp/l410-stage && mkdir -p /tmp/l410-stage'
		scp -O -q "${SSHO[@]}" "$stage"/* "$L410_HOST":/tmp/l410-stage/ || { echo "FAIL-INFRA scp"; return 3; }
		rsh "sudo cp /tmp/l410-stage/* $M/var/cache/l410-stage/ && rm -rf /tmp/l410-stage && sync"
	fi
	rsh 'sudo mount -o remount,rw /boot && sudo grub-reboot debian13; sudo mount -o remount,ro /boot'
	rsh 'sudo systemctl reboot --force' > /dev/null 2>&1 || true
	wait_down 180 || log "WARN: the L410 did not go down"
	local v
	v=$(wait_up 900) || v=""
	if [ "$v" != "4.19.71-46-kr990" ]; then
		echo "FAIL: expected Debian 4.19.71-46, got '$v'" | tee "$ld/result"
		to_kylin
		return 1
	fi
	rsh 'sudo touch /run/l410-keep'
	log "on Debian ($v), running $script"
	timeout 3000 ssh "${SSHO[@]}" "$L410_HOST" 'sudo bash -s' < "$script" > "$ld/out.txt" 2>&1
	local rc=$?
	echo "rc=$rc" > "$ld/result"
	rsh 'sudo rm -rf /var/cache/l410-stage' || true
	to_kylin || log "WARN: could not return to Kylin"
	cat "$ld/out.txt" | tail -40
	echo "logs: $ld (rc=$rc)"
	return $rc
}

case $1 in
test) shift; exec 9> "$LOCK"; flock 9; cmd_test "$@" ;;
on-debian) shift; exec 9> "$LOCK"; flock 9; cmd_ondebian "$@" ;;
run) shift; exec 9> "$LOCK"; flock -s 9; rsh "$@" ;;
status) kver || echo "unreachable" ;;
to-kylin) exec 9> "$LOCK"; flock 9; to_kylin && echo "on Kylin" ;;
pstore) exec 9> "$LOCK"; flock -s 9; rsh 'sudo ls -la /var/lib/systemd/pstore; sudo cat /var/lib/systemd/pstore/console-ramoops-0' ;;
*) sed -n '2,20p' "$0"; exit 2 ;;
esac
