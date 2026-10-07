#!/bin/bash
# Unattended checks for the desktop kernel configuration (docs/kernel-config.md,
# CFG-10 ... CFG-27; plus the 97-security-net fragment). No devices need to be plugged in:
# file systems are tested on loop files, CIFS against a samba share on 127.0.0.1.
#
#   sudo bash tests/desktop-cfg.sh [--no-apt]
#
# Needs exfatprogs ntfs-3g dosfstools udftools xorriso samba cifs-utils nftables cryptsetup-bin (installed
# with apt unless --no-apt). Writes only /var/tmp/l410-cfg/, removes it at the end, restores
# samba to its previous state. Result lines as in tests/quick.sh.
if [ "$(id -u)" != 0 ]; then
	if [ -f "$0" ]; then exec sudo -n bash "$0" "$@"; else exec sudo -n bash -s -- "$@"; fi
fi
APT=1; [ "$1" = --no-apt ] && APT=0
W=/var/tmp/l410-cfg
LOG=/var/tmp/l410-cfg-results-$(date +%Y%m%d-%H%M%S).txt
NF=0
res() { printf '%-5s %-8s %-18s %s\n' "$1" "$2" "$3" "$4" | tee -a $LOG; [ "$1" = FAIL ] && NF=$((NF + 1)); return 0; }
pass() { res PASS "$@"; }
fail() { res FAIL "$@"; }
skip() { res SKIP "$@"; }
info() { res INFO "$@"; }
CURSOR=$(journalctl -k -n 0 --show-cursor 2> /dev/null | sed -n 's/^-- cursor: //p')
MNT=$W/mnt
cleanup() {
	umount -l $MNT 2> /dev/null
	for l in $(losetup -j $W/img 2> /dev/null | cut -d: -f1); do losetup -d $l; done
	[ -n "$SMB_WAS" ] && [ "$SMB_WAS" != active ] && systemctl stop smbd 2> /dev/null
	[ -f $W/smb.conf.orig ] && cp $W/smb.conf.orig /etc/samba/smb.conf
	rm -rf $W
}
trap cleanup EXIT
rm -rf $W; mkdir -p $MNT

if [ $APT = 1 ]; then
	need=""
	for p in exfatprogs ntfs-3g dosfstools udftools xorriso samba cifs-utils nftables cryptsetup-bin python3; do dpkg -s $p > /dev/null 2>&1 || need="$need $p"; done
	[ -n "$need" ] && DEBIAN_FRONTEND=noninteractive apt-get install -y -q $need > $W/apt.log 2>&1
fi

MODS="exfat ntfs3 isofs udf sr_mod sg nls_utf8 nls_cp936 nls_cp950 nls_ascii cifs snd-usb-audio uas usblp ch341 pl2303
usb_serial_simple rndis_host rfcomm bnep uhid joydev xpad wacom huawei_cdc_ncm cdc_mbim qmi_wwan cdc-wdm qcserial ppp_generic
ppp_async ppp_synctty ppp_deflate bsd_comp sch_fq_codel sch_fq snd-seq nf_tables nft_nat nft_masq nft_ct nft_fib_inet wireguard
xfrm_user esp4 esp6 l2tp_core l2tp_ppp pppoe dm-crypt"

# CFG-03 / CFG-10: every module exists and loads
x=""; y=""
for m in $MODS; do
	modinfo $m > /dev/null 2>&1 || { x="$x $m"; continue; }
	modprobe $m 2> /dev/null || y="$y $m"
done
[ -z "$x" ] && pass CFG-03 modules.present "all $(echo $MODS | wc -w) modules installed" || fail CFG-03 modules.present "missing:$x"
[ -z "$y" ] && pass CFG-10 modules.load "all load" || fail CFG-10 modules.load "modprobe failed:$y"

# CFG-11
x=""; for f in exfat ntfs3 iso9660 udf cifs; do grep -qw $f /proc/filesystems || x="$x $f"; done
[ -z "$x" ] && pass CFG-11 fs.registered "exfat ntfs3 iso9660 udf cifs" || fail CFG-11 fs.registered "missing:$x"

NAME="测试文件-中文名称.txt"
roundtrip() {	# roundtrip <id> <name> <mkfs command...>: mkfs a loop file, write, remount, verify
	local id=$1 nm=$2 mt=$3; shift 3
	rm -f $W/img; truncate -s 96M $W/img
	local dev; dev=$(losetup -f --show $W/img)
	if ! "$@" $dev > $W/mkfs.log 2>&1; then fail $id $nm "mkfs failed: $(tail -1 $W/mkfs.log)"; losetup -d $dev; return; fi
	if ! mount -t $mt ${MOPT:+-o $MOPT} $dev $MNT 2> $W/mount.log; then fail $id $nm "mount -t $mt failed: $(cat $W/mount.log)"; losetup -d $dev; return; fi
	echo "中文内容 l410" > "$MNT/$NAME"
	mkdir -p "$MNT/目录"; head -c 16M /dev/urandom > "$MNT/目录/随机数据.bin"
	local s1; s1=$(sha256sum "$MNT/目录/随机数据.bin" | cut -d' ' -f1)
	umount $MNT; mount -t $mt ${MOPT:+-o $MOPT} $dev $MNT 2> /dev/null
	local s2; s2=$(sha256sum "$MNT/目录/随机数据.bin" 2> /dev/null | cut -d' ' -f1)
	local n; n=$(ls "$MNT" 2> /dev/null | grep -c "测试文件-中文名称")
	umount $MNT
	local fsck=ok
	[ -n "$FSCK" ] && { $FSCK $dev > $W/fsck.log 2>&1 || fsck="fsck: $(tail -1 $W/fsck.log)"; }
	losetup -d $dev
	[ "$s1" = "$s2" ] && [ "$n" = 1 ] && [ "$fsck" = ok ] && pass $id $nm "Chinese names and 16 MiB sha256 round trip" || fail $id $nm "sha ${s1:0:8}/${s2:0:8}, name found $n, $fsck"
}
command -v mkfs.exfat > /dev/null && MOPT="" FSCK="fsck.exfat -n" roundtrip CFG-12 fs.exfat exfat mkfs.exfat || skip CFG-12 fs.exfat "no exfatprogs"
command -v mkntfs > /dev/null && MOPT="" FSCK="ntfsfix -n" roundtrip CFG-13 fs.ntfs3 ntfs3 mkntfs -Q -F || skip CFG-13 fs.ntfs3 "no ntfs-3g (mkntfs)"
command -v mkfs.vfat > /dev/null && MOPT="codepage=936,iocharset=utf8" FSCK="fsck.vfat -n" roundtrip CFG-14 fs.vfat-cp936 vfat mkfs.vfat || skip CFG-14 fs.vfat-cp936 "no dosfstools"
command -v mkudffs > /dev/null && MOPT="" FSCK="" roundtrip CFG-16 fs.udf udf mkudffs || skip CFG-16 fs.udf "no udftools"

# CFG-15: ISO 9660 + Joliet + Rock Ridge
if command -v xorriso > /dev/null; then
	mkdir -p "$W/iso/光盘目录"; echo "光盘内容" > "$W/iso/光盘目录/$NAME"; head -c 4M /dev/urandom > $W/iso/data.bin
	s1=$(sha256sum $W/iso/data.bin | cut -d' ' -f1)
	xorriso -as mkisofs -quiet -J -R -o $W/t.iso $W/iso 2> $W/iso.log
	if mount -t iso9660 -o loop,ro,norock,iocharset=utf8 $W/t.iso $MNT 2> $W/mount.log; then
		n=$(ls "$MNT/光盘目录" 2> /dev/null | grep -c "测试文件"); s2=$(sha256sum $MNT/data.bin | cut -d' ' -f1); umount $MNT
		[ "$n" = 1 ] && [ "$s1" = "$s2" ] && pass CFG-15 fs.iso-joliet "Joliet Chinese names and data" || fail CFG-15 fs.iso-joliet "name $n, sha ${s1:0:8}/${s2:0:8}"
	else fail CFG-15 fs.iso-joliet "mount failed: $(cat $W/mount.log)"; fi
else skip CFG-15 fs.iso-joliet "no xorriso"; fi

# CFG-17: CIFS against a local samba share (SMB 3.1.1)
if command -v smbd > /dev/null && command -v mount.cifs > /dev/null; then
	SMB_WAS=$(systemctl is-active smbd 2> /dev/null)
	cp /etc/samba/smb.conf $W/smb.conf.orig
	mkdir -p $W/share; chmod 777 $W/share
	cat >> /etc/samba/smb.conf << EOF

[l410test]
   path = $W/share
   read only = no
   guest ok = yes
   force user = root
EOF
	systemctl restart smbd; sleep 2
	head -c 64M /dev/urandom > $W/big.bin; s1=$(sha256sum $W/big.bin | cut -d' ' -f1)
	if mount -t cifs //127.0.0.1/l410test $MNT -o guest,vers=3.1.1,iocharset=utf8 2> $W/mount.log; then
		cp $W/big.bin "$MNT/大文件.bin"; echo x > "$MNT/$NAME"; sync
		umount $MNT; mount -t cifs //127.0.0.1/l410test $MNT -o guest,vers=3.1.1,iocharset=utf8
		s2=$(sha256sum "$MNT/大文件.bin" | cut -d' ' -f1); n=$(ls "$MNT" | grep -c "测试文件"); umount $MNT
		[ "$s1" = "$s2" ] && [ "$n" = 1 ] && pass CFG-17 fs.cifs "SMB 3.1.1: 64 MiB and Chinese names round trip" || fail CFG-17 fs.cifs "sha ${s1:0:8}/${s2:0:8} name $n"
	else fail CFG-17 fs.cifs "mount failed: $(cat $W/mount.log)"; fi
	cp $W/smb.conf.orig /etc/samba/smb.conf
	if [ "$SMB_WAS" = active ]; then systemctl restart smbd; else systemctl stop smbd nmbd 2> /dev/null; fi
else skip CFG-17 fs.cifs "no samba/cifs-utils"; fi

# CFG-18: device aliases resolve (udev autoloads the module when the device appears)
x=""
while read -r alias mod; do
	r=$(modprobe -R "$alias" 2> /dev/null | tr '\n' ' ')
	[[ " $r " == *" $mod "* ]] || x="$x $mod($r)"
done << 'EOF'
usb:v1A86p7523d0254dc00dsc00dp00icFFiscFFipFFin00 ch341
usb:v067Bp2303d0300dc00dsc00dp00icFFisc00ip00in00 pl2303
usb:v0D8Cp0014d0100dc00dsc00dp00ic01isc01ip00in00 snd_usb_audio
usb:v04B8p0005d0100dc00dsc00dp00ic07isc01ip02in00 usblp
usb:v152Dp0578d0100dc00dsc00dp00ic08isc06ip62in00 uas
usb:v18D1p4EE3d0100dcEFdsc01dp01icE0isc01ip03in00 rndis_host
usb:v12D1p1506d0100dc00dsc00dp00icFFisc02ip16in00 huawei_cdc_ncm
usb:v2C7Cp0125d0318dcEFdsc02dp01ic02isc0Eip00in00 cdc_mbim
EOF
[ -z "$x" ] && pass CFG-18 usb.aliases "CH341 PL2303 USB audio printer UAS RNDIS Huawei NCM MBIM resolve" || fail CFG-18 usb.aliases "unresolved:$x"

# CFG-19
ls /dev/sg* > /dev/null 2>&1 && pass CFG-19 scsi.sg "$(ls /dev/sg* | wc -l) sg nodes (UFS LUNs)" || fail CFG-19 scsi.sg "no /dev/sg*"

# CFG-20: Bluetooth RFCOMM and BNEP sockets
x=$(python3 - << 'PY' 2>&1
import socket
out = []
for name, st, proto in (("rfcomm", socket.SOCK_STREAM, 3), ("bnep", socket.SOCK_RAW, 4)):
    try:
        s = socket.socket(socket.AF_BLUETOOTH, st, proto); s.close(); out.append(name + " ok")
    except OSError as e:
        out.append("%s %s" % (name, e.strerror))
print(", ".join(out))
PY
)
[[ $x == "rfcomm ok, bnep ok" ]] && pass CFG-20 bt.sockets "$x" || fail CFG-20 bt.sockets "$x"

# CFG-21: bluetoothd sees RFCOMM/BNEP (restart it, read its log)
if systemctl is-active -q bluetooth; then
	since=$(date '+%Y-%m-%d %H:%M:%S')
	systemctl restart bluetooth; sleep 4
	e=$(journalctl -u bluetooth --since "$since" --no-pager -o cat | grep -iE "rfcomm|bnep|protocol not supported|failed to init" | grep -viE "^\s*$" | head -3)
	if echo "$e" | grep -qiE "not supported|failed"; then fail CFG-21 bt.bluetoothd "bluetoothd: $e"
	else pass CFG-21 bt.bluetoothd "bluetoothd restarted without RFCOMM/BNEP errors"; fi
	info CFG-21 bt.uuids "$(bluetoothctl show 2> /dev/null | grep -cE 'UUID:') UUIDs advertised"
else skip CFG-21 bt.bluetoothd "bluetooth.service not active"; fi

# CFG-22 / CFG-23
[ -c /dev/uhid ] && pass CFG-22 hid.uhid "/dev/uhid $(stat -c '%a %U:%G' /dev/uhid)" || fail CFG-22 hid.uhid "no /dev/uhid"
n=$(ls /dev/hidraw* 2> /dev/null | wc -l)
[ "$n" -ge 2 ] && pass CFG-23 hid.hidraw "$n hidraw nodes" || fail CFG-23 hid.hidraw "$n hidraw nodes (keyboard and touchpad expected)"

# CFG-24: fq_codel
q=$(sysctl -n net.core.default_qdisc)
t=$(tc qdisc show dev wlan0 2> /dev/null | head -3 | tr '\n' ' ')
[ "$q" = fq_codel ] && [[ $t == *fq_codel* ]] && pass CFG-24 net.qdisc "default fq_codel; wlan0: $t" || fail CFG-24 net.qdisc "default_qdisc $q; wlan0: $t"

# CFG-26: lockup detectors
x="$(cat /proc/sys/kernel/soft_watchdog 2>/dev/null) $(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null) $(cat /proc/sys/kernel/watchdog_thresh 2>/dev/null) $(cat /proc/sys/kernel/hung_task_timeout_secs 2>/dev/null) $(cat /sys/module/workqueue/parameters/watchdog_thresh 2>/dev/null)"
[[ $x =~ ^1\ 1\ 10\ 120\ [1-9][0-9]*$ ]] && pass CFG-26 lockup.detectors "soft/hard/thresh/hung/wq = $x" || fail CFG-26 lockup.detectors "soft/hard/thresh/hung/wq = $x (want 1 1 10 120 >0)"

# 97-security-net: nftables NAT table, WireGuard link, AppArmor, Yama, LUKS
if command -v nft > /dev/null; then
	nft -f - 2> $W/nft.log << 'EOF'
table inet l410test {
	chain post { type nat hook postrouting priority 100; oifname "lo" masquerade; }
	chain forward_chain { type filter hook forward priority 0; ct state established,related accept; }
}
EOF
	[ $? = 0 ] && pass SEC-NF net.nftables "inet NAT + conntrack table loads" || fail SEC-NF net.nftables "$(head -2 $W/nft.log)"
	nft delete table inet l410test 2> /dev/null
else skip SEC-NF net.nftables "no nft"; fi
if ip link add l410wg0 type wireguard 2> $W/wg.log; then ip link del l410wg0; pass SEC-WG net.wireguard "wireguard link created"
else fail SEC-WG net.wireguard "$(cat $W/wg.log)"; fi
if [ "$(cat /sys/module/apparmor/parameters/enabled 2> /dev/null)" = Y ]; then
	n=$(cat /sys/kernel/security/apparmor/profiles 2> /dev/null | wc -l)
	pass SEC-06 lsm.apparmor "AppArmor enabled, $n profiles loaded; LSMs $(cat /sys/kernel/security/lsm)"
else fail SEC-06 lsm.apparmor "AppArmor not enabled (lsm: $(cat /sys/kernel/security/lsm 2> /dev/null))"; fi
[ -f /proc/sys/kernel/yama/ptrace_scope ] && pass SEC-02 lsm.yama "ptrace_scope $(cat /proc/sys/kernel/yama/ptrace_scope)" || fail SEC-02 lsm.yama "no Yama"
if command -v cryptsetup > /dev/null; then
	rm -f $W/img; truncate -s 64M $W/img
	echo -n l410-test-key > $W/key
	if cryptsetup luksFormat -q --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file $W/key $W/img > $W/luks.log 2>&1 &&
		cryptsetup open --key-file $W/key $W/img l410luks >> $W/luks.log 2>&1; then
		head -c 8M /dev/urandom > $W/r.bin; dd if=$W/r.bin of=/dev/mapper/l410luks bs=1M conv=fsync status=none
		s2=$(head -c 8M /dev/mapper/l410luks | sha256sum | cut -d' ' -f1); cryptsetup close l410luks
		[ "$s2" = "$(sha256sum $W/r.bin | cut -d' ' -f1)" ] && pass UFS-13 storage.luks "LUKS2 aes-xts round trip" || fail UFS-13 storage.luks "data mismatch"
	else fail UFS-13 storage.luks "$(tail -1 $W/luks.log)"; fi
else skip UFS-13 storage.luks "no cryptsetup"; fi

# CFG-27 (short form): no lockup reports in the kernel log so far (this boot)
x=$(journalctl -k -b --no-pager -o cat | grep -cE "soft lockup|hard LOCKUP|blocked for more than|workqueue lockup|BUG: workqueue")
[ "$x" = 0 ] && pass CFG-27 lockup.reports "no lockup/hung-task reports this boot" || fail CFG-27 lockup.reports "$x lockup/hung-task lines this boot: $(journalctl -k -b --no-pager -o cat | grep -m1 -E 'soft lockup|hard LOCKUP|blocked for more than|workqueue lockup')"
x=$(journalctl -k --after-cursor "$CURSOR" --no-pager -o cat 2> /dev/null | grep -cE "Unable to handle|BUG:|WARNING: CPU|Oops|usercopy|detected buffer overflow|fortify")
[ "$x" = 0 ] && pass CFG-10 klog.clean "no kernel errors during the tests" || fail CFG-10 klog.clean "$x error lines: $(journalctl -k --after-cursor "$CURSOR" --no-pager -o cat | grep -m1 -E 'Unable to handle|BUG:|WARNING: CPU|Oops|usercopy|detected buffer overflow|fortify')"

# unload what the tests loaded and nothing uses (best effort)
for m in $MODS; do modprobe -r $m 2> /dev/null; done
echo "RESULT: $([ $NF = 0 ] && echo PASS || echo "FAIL ($NF)")"
echo "LOG: $LOG"
exit $NF
