#!/bin/sh
# T1 soc-core: extra diagnostics for l410.mode=probe (busybox initramfs).
# Packed into the initrd as /l410-extra.sh by tests/soc-core-repack-initrd.sh;
# every line lands in the kernel log (pstore) prefixed "L410INIT: extra:".
# Only harmless reads/ID queries; the one IPC message is the "keep PPLL0 on"
# vote that clk_spll_vote/clk_ap_ppll0 send on the vendor kernel.
D=/sys/kernel/debug
echo "== clk"
echo "clk_summary lines: $(wc -l < $D/clk/clk_summary)"
echo "orphans: $(awk 'NR>3 && NF' $D/clk/clk_orphan_summary | wc -l)"
echo "== ipc channels"
cat $D/kirin-ipc/channels
echo "== ipc xfer HISI_ACPU_LPM3_MBX_1 0xd0002 0 (PPLL0 vote on)"
echo "HISI_ACPU_LPM3_MBX_1 0xd0002 0x0" > $D/kirin-ipc/xfer
echo "result: $(cat $D/kirin-ipc/xfer)"
echo "== ipc channels after"
cat $D/kirin-ipc/channels | awk 'NR==1 || $7 > 0 || $8 > 0 || $9 > 0 || $10 > 0'
echo "== hwspinlock"
ls /sys/bus/platform/drivers/kirin-hwspinlock 2>&1 | tr '\n' ' '; echo
echo "== gpio"
echo "gpiochips: $(ls -d /sys/class/gpio/gpiochip* 2>/dev/null | wc -l)"
head -5 $D/gpio
echo "== amba"
for d in /sys/bus/amba/devices/*; do
	echo "$(basename $d) -> $(basename $(readlink $d/driver) 2>/dev/null)"
done | grep -v -- "-> $" | awk '{print $3}' | sort | uniq -c
echo "== dma"
ls /sys/class/dma 2>&1 | tr '\n' ' '; echo
echo "== i2c adapters"
for a in /sys/bus/i2c/devices/i2c-*; do echo "$(basename $a) $(cat $a/name)"; done
i2c() { # label, i2ctransfer args
	l=$1; shift
	out=$(i2ctransfer -f -y "$@" 2>&1)
	echo "$l: rc=$? $out"
}
echo "== i2c traffic"
i2c "i2c4 0x2c SN65DSI86 id 0x00-0x07" 4 w1@0x2c 0x00 r8@0x2c
i2c "i2c4 0x2c SN65DSI86 rev 0x08" 4 w1@0x2c 0x08 r1@0x2c
i2c "i2c7 0x3a keyboard HID descriptor" 7 w2@0x3a 0x01 0x00 r30@0x3a
i2c "i2c6 0x5d touchpad HID descriptor" 6 w2@0x5d 0x01 0x00 r30@0x5d
i2c "i2c7 0x38 EC read" 7 r4@0x38
i2c "i2c3 0x4c smartpa page" 3 w1@0x4c 0x00 r1@0x4c
i2c "i2c3 0x4e smartpa page" 3 w1@0x4e 0x00 r1@0x4e
echo "== spi"
ls /sys/bus/spi/devices 2>&1 | tr '\n' ' '; echo
