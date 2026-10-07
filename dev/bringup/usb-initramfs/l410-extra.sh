#!/bin/sh
# T4 usb: extra probe-mode diagnostics, run by /init's dump() (output -> kernel log
# as "L410INIT: extra: ..."). Appended to a bundle's initrd by append.sh.
#   - USB device list with speeds/drivers
#   - RTL8153: link up, DHCP (busybox udhcpc), ping the gateway
#   - serve a status page on :2222 (where the lab ssh forwarder pointed) during
#     l410.hold, so the whole path can be checked from WSL:
#     curl http://<forwarder>:2222/
NIC=${NIC:-$(ls /sys/class/net | grep -m1 "^enx")}

for d in /sys/bus/usb/devices/*; do
	[ -f "$d/idVendor" ] || continue
	drv=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)
	ifd=""
	for i in "$d":1.*; do [ -e "$i/driver" ] && ifd="$ifd $(basename "$(readlink "$i/driver")")"; done
	echo "usbdev $(basename "$d") $(cat "$d/idVendor"):$(cat "$d/idProduct") speed=$(cat "$d/speed") drv=$drv if:$ifd $(cat "$d/product" 2>/dev/null)"
done
for d in /sys/bus/platform/devices/*usb* /sys/bus/platform/devices/*dwc3* /sys/bus/platform/devices/*hub*; do
	[ -e "$d" ] && echo "pdev $(basename "$d") -> $(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)"
done
grep -h . /sys/kernel/debug/usb/devices 2>/dev/null | grep -E "^(T|P|S:  Product)" | head -40

[ -d /sys/class/net/$NIC ] || { echo "no $NIC"; exit 0; }
ip link set lo up
ip link set $NIC up
i=0
while [ $i -lt 15 ] && [ "$(cat /sys/class/net/$NIC/carrier 2>/dev/null)" != 1 ]; do sleep 1; i=$((i + 1)); done
echo "$NIC carrier=$(cat /sys/class/net/$NIC/carrier 2>/dev/null) after ${i}s speed=$(cat /sys/class/net/$NIC/speed 2>/dev/null)"
udhcpc -i $NIC -n -q -t 8 -T 2 -s /l410-udhcpc.sh 2>&1
ip -4 addr show dev $NIC
ip route
gw=$(ip route | awk '/^default/ {print $3; exit}')
[ -n "$gw" ] && ping -c 5 -W 2 "$gw" 2>&1 | tail -3
if [ -n "$gw" ]; then
	mkdir -p /tmp/www
	{
		echo "l410 usb probe kernel $(uname -r)"
		ip -4 addr show dev $NIC
		for d in /sys/bus/usb/devices/*; do [ -f "$d/idVendor" ] && echo "$(basename "$d") $(cat "$d/idVendor"):$(cat "$d/idProduct") $(cat "$d/speed")M"; done
	} > /tmp/www/index.html
	# detach from /init's log pipe, or dump() would never see EOF
	httpd -p 2222 -h /tmp/www < /dev/null > /dev/null 2>&1 && echo "httpd on :2222"
fi
