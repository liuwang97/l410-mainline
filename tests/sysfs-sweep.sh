#!/bin/bash
# Read-only sweep of /sys, /proc and debugfs (docs/testing/test-plan.md REL-08, C6): read every
# readable file as root, with clock gating on, looking for reads that abort (a register of
# a clock-gated block, like the PL011 case), oops, hang or flood the log.
#
#   sudo bash tests/sysfs-sweep.sh [sys|proc|debug|all]      (default all)
#
# Before each read the path goes to /var/lib/l410-test/sweep/current with fsync, so if the
# machine dies the next boot shows the culprit: sudo bash tests/sysfs-sweep.sh last
# Skipped: files known to act on read or to be huge/slow (see SKIP), anything under a
# path that blocks (each read has a 2 s timeout). Output: /var/lib/l410-test/sweep/.
if [ "$(id -u)" != 0 ]; then
	if [ -f "$0" ]; then exec sudo -n bash "$0" "$@"; else exec sudo -n bash -s -- "$@"; fi
fi
S=/var/lib/l410-test/sweep; mkdir -p $S
WHAT=${1:-all}
if [ "$WHAT" = last ]; then
	echo "last file being read: $(cat $S/current 2> /dev/null)"; tail -3 $S/log 2> /dev/null; exit 0
fi
# reads that change state, wait for events, dump huge buffers, or are known to hurt here
SKIP='(/sys/kernel/debug/tracing|/sys/kernel/tracing|/trace_pipe|/sys/kernel/debug/clk/clk_summary|/sys/kernel/debug/clk/clk_dump|/sys/kernel/debug/provoke-crash|/sys/kernel/debug/dri/[0-9]+/(crtc|state|framebuffer)|/sys/kernel/debug/kmemleak|/sys/kernel/debug/fail|/sys/kernel/debug/asp-pcm|/sys/kernel/debug/hi6405/registers|/sys/kernel/debug/kirin-ipc|/sys/kernel/debug/huawei-echub|/sys/kernel/debug/usb/.*/(regdump|lsp_dump|link_state)|/sys/firmware/efi/efivars|/sys/kernel/security/apparmor/(\.load|\.replace|\.remove)|/sys/power/(state|mem_sleep|pm_test|wakeup_count)|/sys/bus/i2c/devices/.*/(eeprom|nvmem)|/sys/devices/.*/(nvmem|eeprom|rom|config|resource[0-9]*|remove|rescan|reset|bind|unbind|uevent|new_id|remove_id)$|/sys/class/drm/.*/edid|/sys/fs/pstore|/sys/kernel/l410_deadman|/proc/(kmsg|kcore|kpage|sysrq-trigger|[0-9]+|self|thread-self|bus/pci)|/proc/sys/vm/(drop_caches|compact_memory)|/proc/sys/fs/binfmt_misc|/proc/pressure)'
CURSOR=$(journalctl -k -n 0 --show-cursor 2> /dev/null | sed -n 's/^-- cursor: //p')
touch /run/l410-keep; echo 0 > /sys/kernel/l410_deadman/timeout 2> /dev/null
: > $S/log; n=0; slow=0; err=0
sweep() {
	local root=$1 f
	while IFS= read -r -d '' f; do
		[[ $f =~ $SKIP ]] && continue
		[ -r "$f" ] || continue
		printf '%s\n' "$f" > $S/current; sync $S/current
		if ! timeout 2 dd if="$f" of=/dev/null bs=64k count=16 status=none 2> /dev/null; then
			[ $? = 124 ] && { slow=$((slow + 1)); echo "TIMEOUT $f" >> $S/log; } || err=$((err + 1))
		fi
		n=$((n + 1))
		[ $((n % 2000)) = 0 ] && echo "$n files, now $f" >> $S/log
	done < <(find "$root" -xdev -type f -print0 2> /dev/null)
}
case $WHAT in
sys) sweep /sys ;;
proc) sweep /proc ;;
debug) sweep /sys/kernel/debug ;;
all) sweep /sys; sweep /proc; sweep /sys/kernel/debug ;;
esac
echo "done" > $S/current
journalctl -k --after-cursor "$CURSOR" --no-pager -o short-monotonic > $S/klog.txt 2> /dev/null
bad=$(grep -cE "Internal error|Unable to handle|SError|BUG:|WARNING: CPU|Oops|synchronous external abort|rcu.*stall|soft lockup" $S/klog.txt)
echo "read $n files ($err read errors, $slow timed out), kernel log: $(wc -l < $S/klog.txt) lines, $bad oops/abort lines"
grep TIMEOUT $S/log | head -10
[ "$bad" = 0 ] && echo "RESULT: PASS" || { grep -m5 -E "Internal error|Unable to handle|SError|BUG:|WARNING: CPU|Oops|abort" $S/klog.txt; echo "RESULT: FAIL ($bad)"; }
exit $bad
