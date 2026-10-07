#!/bin/sh
# busybox udhcpc hook for the usb probe initramfs
case $1 in
deconfig)
	ip -4 addr flush dev "$interface"
	ip link set "$interface" up
	;;
bound | renew)
	ip -4 addr flush dev "$interface"
	ip addr add "$ip/${mask:-24}" dev "$interface"
	for r in $router; do
		ip route add default via "$r" dev "$interface"
		break
	done
	echo "udhcpc: $interface $ip/${mask} router $router dns $dns lease $lease"
	;;
esac
exit 0
