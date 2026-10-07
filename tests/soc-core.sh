#!/bin/bash
# SoC core checks, run on the 6.18 test kernel (Debian) by
#   dev/l410-harness.sh test <bundle> --script tests/soc-core.sh
# Prints one PASS/FAIL line per check and a summary; exit code = number of failures.
#   clocks: every /clocks@0 node has a provider, no orphans, key rates as on the vendor kernel
#   IPC mailboxes (+ one LPM3 round trip), hwspinlock, DMA, pinctrl, GPIO, I2C, UART, SPI bound
#   I2C traffic: SN65DSI86 (i2c4 0x2c) ID, keyboard/touchpad HID descriptors, EC (i2c7 0x38)
S=sudo
[ "$(id -u)" = 0 ] && S=
fail=0
pass() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
bound() { # bus, driver, expected minimum count
	local n
	n=$(ls /sys/bus/"$1"/drivers/"$2" 2> /dev/null | grep -c -E '^[0-9a-f]+\.|^hwspinlock$')
	if [ "$n" -ge "$3" ]; then pass "$1 driver $2 bound x$n"; else bad "$1 driver $2 bound x$n (want >= $3)"; fi
}
D=/sys/kernel/debug

echo "== kernel $(uname -r)"
$S mount -t debugfs none $D 2> /dev/null

# --- clocks
rep=$($S dmesg | grep "kirin-clk: .* clock nodes" | tail -1)
echo "   ${rep#*] }"
if echo "$rep" | grep -q " 0 without provider, 0 orphans"; then pass "clock report"; else bad "clock report"; fi
# the display powers down completely when it is off (kirin990-dss): reading clk_summary
# then re-evaluates media CRG dividers, and the eDP bridge does not answer on I2C
DPMS=$(cat /sys/class/drm/card*-eDP-1/dpms 2> /dev/null | head -1)
if [ "${DPMS:-On}" = On ]; then
	n=$($S cat $D/clk/clk_summary 2> /dev/null | wc -l)
	[ "$n" -gt 500 ] && pass "clk_summary has $n lines" || bad "clk_summary has $n lines"
else
	echo "SKIP clk_summary: display is off (powered down)"
fi
orph=$($S awk 'NR>3 && NF' $D/clk/clk_orphan_summary 2> /dev/null | wc -l)
[ "$orph" -eq 0 ] && pass "no orphan clocks" || bad "$orph orphan clocks"
# rates read on the vendor kernel (vendor-info/clk_summary-4.19.71-23.txt); +-1 Hz for rounding
while read -r clk want; do
	got=$($S cat $D/clk/"$clk"/clk_rate 2> /dev/null)
	if [ "$clk" = clk_g3d ] && [ -n "$got" ] &&
		grep -qw "$got" /sys/class/devfreq/*.mali/available_frequencies 2> /dev/null; then
		pass "rate $clk = $got (a GPU OPP; scales with load and mode)"
	elif [ -n "$got" ] && [ $((got - want)) -ge -1 ] && [ $((got - want)) -le 1 ]; then
		pass "rate $clk = $got"
	else
		bad "rate $clk = ${got:-none} (vendor $want)"
	fi
done << 'EOF'
clkin_sys 38400000
clk_ppll0 1660000000
clk_ap_ppll2 1920000000
clk_ap_ppll6 1720000000
sc_div_aobus 37449142
clkmux_i2c 110666666
clk_i2c7 110666666
clk_uart4 166000000
uart6clk 19200000
clk_g3d 166000000
EOF

# --- IPC, hwspinlock, DMA
bound platform kirin-ipc-mailbox 3
bound platform kirin-hwspinlock 1
bound platform hisi-dma64 1
before=$($S awk '$2=="mailbox-13"{print $7}' $D/kirin-ipc/channels)
echo "HISI_ACPU_LPM3_MBX_1 0xd0002 0x0" | $S tee $D/kirin-ipc/xfer > /dev/null
res=$($S cat $D/kirin-ipc/xfer)
after=$($S awk '$2=="mailbox-13"{print $7}' $D/kirin-ipc/channels)
if [ "${res%% *}" = 0 ] && [ "$after" -gt "${before:-0}" ]; then pass "LPM3 IPC round trip: $res"; else bad "LPM3 IPC round trip: $res"; fi
tm=$($S awk 'NR>1{t+=$9} END{print t+0}' $D/kirin-ipc/channels)
[ "$tm" -eq 0 ] && pass "no IPC ack timeouts" || bad "$tm IPC ack timeouts"

# DMA memcpy self-test on the peripheral DMA (CONFIG_DMATEST)
M=/sys/module/dmatest/parameters
if [ -d $M ]; then
	echo 2000 | $S tee $M/timeout > /dev/null
	echo 20 | $S tee $M/iterations > /dev/null
	echo 4096 | $S tee $M/test_buf_size > /dev/null
	echo dma0chan0 | $S tee $M/channel > /dev/null
	echo 1 | $S tee $M/run > /dev/null
	$S cat $M/wait > /dev/null
	sum=$($S dmesg | grep "dmatest: dma0chan0-copy0: summary" | tail -1)
	if echo "$sum" | grep -q " 0 failures"; then pass "DMA memcpy: ${sum#*summary }"; else bad "DMA memcpy: ${sum:-no summary}"; fi
else
	echo "SKIP dmatest not built in"
fi

# --- pin control, GPIO, buses
bound platform pinctrl-single 8
bound amba pl061_gpio 37
bound amba uart-pl011 4
bound amba ssp-pl022 1
bound platform i2c_designware 4
n=$($S grep -c "^gpiochip" $D/gpio)
[ "$n" -ge 37 ] && pass "$n gpiochips" || bad "$n gpiochips (want 37)"
for b in 3 4 6 7; do
	[ -e /sys/bus/i2c/devices/i2c-$b ] && pass "i2c-$b present" || bad "i2c-$b missing"
done
dfr=$($S cat $D/devices_deferred 2> /dev/null | grep -E "gpio|pinmux|i2c|uart|spi|ipc|hwspinlock|dma" | awk '{print $1}' | tr '\n' ' ')
[ -z "$dfr" ] && pass "no deferred soc-core devices" || bad "deferred: $dfr"

# --- I2C traffic (ID/descriptor reads only)
xfer() { $S i2ctransfer -f -y "$@" 2> /dev/null; }
if [ "${DPMS:-On}" = On ]; then
	id=$(xfer 4 w1@0x2c 0x00 r8@0x2c)
	[ "$id" = "0x36 0x38 0x49 0x53 0x44 0x20 0x20 0x20" ] && pass "i2c4 0x2c SN65DSI86 id '68ISD'" || bad "i2c4 0x2c SN65DSI86 id: ${id:-no answer}"
else
	echo "SKIP i2c4 0x2c SN65DSI86: display is off (bridge powered down)"
fi
hd=$(xfer 7 w2@0x3a 0x01 0x00 r4@0x3a)
[ "${hd:0:14}" = "0x1e 0x00 0x00" ] && pass "i2c7 0x3a keyboard HID descriptor: $hd" || bad "i2c7 0x3a keyboard HID descriptor: ${hd:-no answer}"
hd=$(xfer 6 w2@0x5d 0x01 0x00 r4@0x5d)
[ "${hd:0:14}" = "0x1e 0x00 0x00" ] && pass "i2c6 0x5d touchpad HID descriptor: $hd" || bad "i2c6 0x5d touchpad HID descriptor: ${hd:-no answer}"
ec=$(xfer 7 r4@0x38)
[ -n "$ec" ] && pass "i2c7 0x38 EC answers: $ec" || bad "i2c7 0x38 EC no answer"

echo "== soc-core: $fail failure(s)"
exit $fail
