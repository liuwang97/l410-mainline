#!/bin/bash
# PCIe: PCIe (kport RC0/RC1) + RTL8168 (r8169) checks. Runs on the 6.18 test
# kernel's Debian, as root or with passwordless sudo:
#   ssh l410 'bash -s' < tests/pcie.sh          (or: dev/l410-harness.sh test ... --script tests/pcie.sh)
# Prints one PASS/FAIL/SKIP line per check and a summary; exit status 1 if anything failed.
#
# The Ethernet cable is often not plugged in, so link/traffic checks are SKIP
# unless a carrier is present. Suspend is only tried with PCIE_TEST_SUSPEND=1.
S=; [ "$(id -u)" = 0 ] || S=sudo
PATH=$PATH:/usr/sbin:/sbin	# ethtool, setpci for non-root ssh sessions
# the RTL8168 MAC address (from Kylin: ip link); empty: only checked to be stable
EXPECT_MAC=${EXPECT_MAC:-}
RC0=f0000000.pcie_kport_rc RC1=f4000000.pcie_kport_rc
NIC=0000:01:00.0 WIFI=0001:01:00.0
pass=0 fail=0 skip=0
PASS() { echo "PASS $*"; pass=$((pass + 1)); }
FAIL() { echo "FAIL $*"; fail=$((fail + 1)); }
SKIP() { echo "SKIP $*"; skip=$((skip + 1)); }
check() { local name=$1; shift; if "$@" > /dev/null 2>&1; then PASS "$name"; else FAIL "$name"; fi; }
drv_of() { basename "$(readlink "$1/driver" 2>/dev/null)" 2>/dev/null; }
rd() { cat "$1" 2>/dev/null; }

echo "== kernel $(uname -r)"

# --- root complexes ---
for rc in $RC0 $RC1; do
	d=/sys/bus/platform/devices/$rc
	[ "$(drv_of $d)" = pcie-kport ] && PASS "rc $rc bound to pcie-kport" || FAIL "rc $rc bound (driver: $(drv_of $d))"
done
$S dmesg | grep -E "pcie-kport|pcie_kport_rc" | sed 's/^/   /' | tail -20

# --- RC0: RTL8168 ---
d=/sys/bus/pci/devices/$NIC
if [ -d $d ]; then
	PASS "enumerated $NIC [$(rd $d/vendor | cut -c3-):$(rd $d/device | cut -c3-)] rev $(rd $d/revision)"
	[ "$(rd $d/vendor)" = 0x10ec ] && [ "$(rd $d/device)" = 0x8168 ] && PASS "nic id 10ec:8168" || FAIL "nic id"
	[ "$(drv_of $d)" = r8169 ] && PASS "nic bound to r8169" || FAIL "nic driver: $(drv_of $d)"
	sp=$(rd $d/current_link_speed); w=$(rd $d/current_link_width)
	msp=$(rd $d/max_link_speed); mw=$(rd $d/max_link_width)
	echo "   link: $sp x$w (max $msp x$mw)"
	# vendor kernel: RTL8168H is PCIe Gen1 x1, same as its capability
	[ "$sp" = "$msp" ] && [ "$w" = "$mw" ] && PASS "nic link at max speed/width ($sp x$w)" || FAIL "nic link $sp x$w, max $msp x$mw"
	rp=/sys/bus/pci/devices/0000:00:00.0
	[ "$(drv_of $rp)" = pcieport ] && PASS "rc0 root port bound to pcieport" || FAIL "rc0 root port driver: $(drv_of $rp)"
	echo "   aspm: l0s=$(rd $d/link/l0s_aspm) l1=$(rd $d/link/l1_aspm) l1.1=$(rd $d/link/l1_1_aspm) l1.2=$(rd $d/link/l1_2_aspm)"
else
	FAIL "enumerated $NIC"
fi

ifc=$(ls $d/net 2>/dev/null | head -1)
if [ -n "$ifc" ]; then
	PASS "netdev $ifc"
	mac=$(rd /sys/class/net/$ifc/address)
	# without EXPECT_MAC, the permanent address read now is what the later checks compare against
	[ -n "$EXPECT_MAC" ] || EXPECT_MAC=$($S ethtool -P $ifc 2> /dev/null | awk '{print $NF}')
	[ "$mac" = "$EXPECT_MAC" ] && PASS "mac $mac" || FAIL "mac $mac (want $EXPECT_MAC)"
	if command -v ethtool > /dev/null; then
		perm=$($S ethtool -P $ifc 2>/dev/null | awk '{print $NF}')
		[ "$perm" = "$EXPECT_MAC" ] && PASS "permanent mac $perm" || FAIL "permanent mac $perm"
		$S ethtool -i $ifc 2>/dev/null | sed 's/^/   /'
		check "ethtool register dump" $S ethtool -d $ifc
		check "ethtool statistics" $S ethtool -S $ifc
	else
		SKIP "ethtool not installed (permanent mac, register dump, statistics)"
	fi
	# bring the interface up: firmware request + MSI vector allocation
	$S ip link set $ifc up; sleep 3
	[ "$(rd $d/msi_bus)" != 0 ] && ls $d/msi_irqs > /dev/null 2>&1 && PASS "msi vectors: $(ls $d/msi_irqs | tr '\n' ' ')" || FAIL "msi vectors"
	grep -E "$ifc|$NIC" /proc/interrupts | sed 's/^/   /'
	$S dmesg | grep -E "r8169|$ifc" | tail -8 | sed 's/^/   /'
	$S dmesg | grep -q "rtl_nic/.*\(-2\)\|unable to load firmware" && SKIP "rtl_nic firmware (not loaded, see dmesg)" || PASS "rtl_nic firmware request ok"
	carrier=$(rd /sys/class/net/$ifc/carrier)
	if [ "$carrier" = 1 ]; then
		PASS "carrier up ($(rd /sys/class/net/$ifc/speed) Mb/s $(rd /sys/class/net/$ifc/duplex))"
		irqsum() { grep -E "$ifc|$NIC" /proc/interrupts | awk '{for (i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i} END {print s+0}'; }
		irq0=$(irqsum)
		gw=$(ip route | awk -v i=$ifc '/default/ && $0 ~ i {print $3; exit}')
		[ -n "$gw" ] && ping -c 3 -W 2 -I $ifc $gw > /dev/null && PASS "ping $gw via $ifc" || SKIP "ping (no gateway on $ifc)"
		irq1=$(irqsum)
		[ "${irq1:-0}" -gt "${irq0:-0}" ] && PASS "msi interrupts counting ($irq0 -> $irq1)" || FAIL "msi interrupts not counting"
	else
		SKIP "carrier down (cable not plugged): link/traffic/irq-count checks skipped"
	fi
	# rebind r8169 (probe/remove path, config space, MSI teardown)
	echo $NIC | $S tee /sys/bus/pci/drivers/r8169/unbind > /dev/null
	sleep 1
	echo $NIC | $S tee /sys/bus/pci/drivers/r8169/bind > /dev/null
	sleep 2
	ifc2=$(ls $d/net 2>/dev/null | head -1)
	[ -n "$ifc2" ] && [ "$(rd /sys/class/net/$ifc2/address)" = "$EXPECT_MAC" ] && PASS "r8169 rebind ($ifc2)" || FAIL "r8169 rebind"
	$S ip link set ${ifc2:-$ifc} down 2> /dev/null
else
	FAIL "netdev for $NIC"
fi

# --- link retrain from the root port: the link must come back at the same speed
# with the NIC still usable. (The DesignWare root port does not signal its own
# events - LBMS/bwctrl, PME, AER - through the MSI controller on this SoC, so the
# bwctrl interrupt count is informational only; the 2026-09-29 run saw LBMS set
# and no interrupt.) ---
irq_count() { awk -v n="$1" '$0 ~ n && $0 ~ /DW-PCI-MSI-0000:00/ {for (i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i} END {print s+0}' /proc/interrupts; }
if command -v setpci > /dev/null && [ -d /sys/bus/pci/devices/0000:00:00.0 ]; then
	c0=$(irq_count bwctrl)
	$S setpci -s 0000:00:00.0 CAP_EXP+10.w=0020:0020	# Retrain Link
	sleep 1
	c1=$(irq_count bwctrl)
	lnksta=$($S setpci -s 0000:00:00.0 CAP_EXP+12.w)
	echo "   root port LNKSTA $lnksta after retrain (bwctrl irq $c0 -> $c1, informational)"
	[ $((0x$lnksta & 0x2000)) != 0 ] && [ $((0x$lnksta & 0xf)) = 1 ] && PASS "link retrained (DLL active, 2.5 GT/s)" || FAIL "link after retrain: LNKSTA $lnksta"
	ifc3=$(ls $d/net 2>/dev/null | head -1)
	[ -n "$ifc3" ] && $S ip link set $ifc3 up && sleep 2 && [ "$(rd /sys/class/net/$ifc3/operstate)" != unknown ] &&
		PASS "nic usable after retrain ($ifc3 $(rd /sys/class/net/$ifc3/operstate))" || FAIL "nic after retrain"
	[ -n "$ifc3" ] && $S ip link set $ifc3 down
else
	SKIP "setpci missing: link retrain check"
fi

# --- RC1: Hi110x (enumerated by the WiFi driver) ---
d=/sys/bus/pci/devices/$WIFI
if [ -d $d ]; then
	[ "$(rd $d/vendor)" = 0x19e5 ] && [ "$(rd $d/device)" = 0x1103 ] && PASS "rc1 endpoint 19e5:1103" || FAIL "rc1 endpoint id"
	echo "   link: $(rd $d/current_link_speed) x$(rd $d/current_link_width) (max $(rd $d/max_link_speed) x$(rd $d/max_link_width)), driver $(drv_of $d)"
else
	SKIP "rc1 endpoint $WIFI not present (enumerated by the Hi110x driver)"
fi

# --- suspend/resume (s2idle), optional ---
if [ "${PCIE_TEST_SUSPEND:-0}" = 1 ]; then
	if grep -q freeze /sys/power/state && command -v rtcwake > /dev/null; then
		echo "   suspending (s2idle, rtc wake in 10 s) ..."
		# if the machine never wakes up, let the deadman reset it in ~3 min instead of 30
		dm=/sys/kernel/l410_deadman/timeout
		[ -e $dm ] && echo 360 | $S tee $dm > /dev/null 2>&1
		mark=$($S dmesg | wc -l)
		$S rtcwake -m freeze -s 10 > /dev/null 2>&1; rc=$?
		sleep 3
		[ -e $dm ] && echo 3600 | $S tee $dm > /dev/null 2>&1
		echo "   rtcwake rc=$rc"
		$S dmesg | tail -n +$((mark + 1)) | grep -E "PM:|pcie-kport|r8169|pcieport|PCIe Gen|Freezing|Restarting|suspend|resume" | head -30 | sed 's/^/   /'
		ifc4=$(ls /sys/bus/pci/devices/$NIC/net 2>/dev/null | head -1)
		[ -n "$ifc4" ] && [ "$(rd /sys/bus/pci/devices/$NIC/vendor)" = 0x10ec ] &&
			$S ethtool -d "$ifc4" > /dev/null 2>&1 && PASS "nic alive after s2idle (register dump ok)" || FAIL "nic after s2idle"
		sp=$(rd /sys/bus/pci/devices/$NIC/current_link_speed)
		[ "$sp" = "$(rd /sys/bus/pci/devices/$NIC/max_link_speed)" ] && PASS "nic link after s2idle ($sp)" || FAIL "nic link after s2idle ($sp)"
		[ -n "$ifc4" ] && [ "$(rd /sys/class/net/$ifc4/address)" = "$EXPECT_MAC" ] && PASS "mac after s2idle" || FAIL "mac after s2idle"
	else
		SKIP "s2idle not available"
	fi
fi

echo "== pcie: $pass pass, $fail fail, $skip skip"
[ $fail = 0 ]
