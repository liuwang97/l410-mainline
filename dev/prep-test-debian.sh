#!/bin/bash
# One-time preparation of the Debian 13 partition (sdd7) for unattended kernel testing.
# Run on the L410 under Kylin as root:  sudo NIC_MAC=<mac> bash prep-test-debian.sh
set -e
D=${D:-/media/$SUDO_USER/DEBIAN}	# the Debian root, mounted
U=${L410_USER:-$SUDO_USER}	# test user; same uid/gid in both systems
NIC_MAC=${NIC_MAC:?MAC of the USB NIC used for ssh}
NIC_ADDR=${NIC_ADDR:-}	# optional fixed address/prefix for it
[ -d $D/etc ] || { echo "Debian root not mounted at $D"; exit 1; }

# 1. network. A USB RTL8153 dongle carries ssh in the lab: DHCP (client-id = MAC), plus an optional
#    fixed address so a port forwarder in front of the machine always finds it.
mkdir -p $D/etc/systemd/network/disabled
if [ -f $D/etc/systemd/network/10-enx-static.network ]; then
	mv $D/etc/systemd/network/10-enx-static.network $D/etc/systemd/network/disabled/
fi
# Match by MAC: Name=enx* would also match the RTL8168 through its udev altname
# (enx<MAC>) and hand it this static address too.
printf '%s\n' '[Match]' "MACAddress=$NIC_MAC" '' '[Network]' 'DHCP=ipv4' ${NIC_ADDR:+"Address=$NIC_ADDR"} \
	'LinkLocalAddressing=no' 'IPv6AcceptRA=no' '' '[DHCPv4]' 'ClientIdentifier=mac' \
	> $D/etc/systemd/network/10-l410-usb-eth.network
printf '%s\n' '[Match]' 'Name=enp* eth*' '' '[Network]' 'DHCP=ipv4' '' '[DHCPv4]' 'ClientIdentifier=mac' \
	> $D/etc/systemd/network/20-l410-eth.network
mkdir -p $D/etc/NetworkManager/conf.d
printf '%s\n' '[keyfile]' 'unmanaged-devices=interface-name:enx*;interface-name:enp*;interface-name:eth*' \
	> $D/etc/NetworkManager/conf.d/99-l410-unmanaged.conf

# 2. ssh as the test user with the same keys as on Kylin, passwordless sudo
install -d -m 700 -o $U -g $U $D/home/$U/.ssh
install -m 600 -o $U -g $U /home/$U/.ssh/authorized_keys $D/home/$U/.ssh/authorized_keys
echo "$U ALL=(ALL) NOPASSWD: ALL" > $D/etc/sudoers.d/90-l410-test
chmod 440 $D/etc/sudoers.d/90-l410-test

# 3. auto-revert: reboot back to the default entry (Kylin 2203) after 15 min unless /run/l410-keep exists
printf '%s\n' '[Unit]' 'Description=L410 test: reboot to default entry unless kept alive' \
	'After=multi-user.target' '' '[Service]' 'Type=simple' \
	"ExecStart=/bin/sh -c 'sleep 900; [ -e /run/l410-keep ] || { echo l410-revert > /dev/kmsg; systemctl reboot --force; }'" \
	'' '[Install]' 'WantedBy=multi-user.target' > $D/etc/systemd/system/l410-revert.service
ln -sf /etc/systemd/system/l410-revert.service $D/etc/systemd/system/multi-user.target.wants/l410-revert.service

mkdir -p $D/boot/l410
echo "debian prepared"
