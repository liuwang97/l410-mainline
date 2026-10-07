#!/bin/bash
# Install Debian packages into the test Debian (sdd7) although the L410 has no internet access.
# Runs in WSL: resolves dependencies against sdd7's own dpkg status, downloads the arm64
# .debs here, then boots Debian once (harness on-debian) and installs them with dpkg there.
# (Installing from Kylin via chroot does not work: Kylin's endpoint security blocks dpkg.)
#
#   deb-install.sh pkg [pkg...]
set -e
[ $# -gt 0 ] || { echo "usage: $0 pkg..."; exit 2; }
L=$HOME/l410
H=$(dirname "$(readlink -f "$0")")/l410-harness.sh
W=$L/tmp/main/debs
DEB_UUID=${DEB_UUID:?set DEB_UUID to the UUID of the Debian root filesystem}
rm -rf "$W" && mkdir -p "$W/archives/partial" "$W/state"

bash "$H" run "M=\$(findmnt -rno TARGET -S UUID=$DEB_UUID | head -1); [ -n \"\$M\" ] || { sudo mkdir -p /mnt/l410-deb; sudo mount UUID=$DEB_UUID /mnt/l410-deb; M=/mnt/l410-deb; }; cat \$M/var/lib/dpkg/status" > "$W/state/status"
grep -q "^Package: dpkg" "$W/state/status" || { echo "could not read sdd7 dpkg status"; exit 1; }

sudo apt-get -qq update || true
sudo apt-get -y -q --download-only \
	-o APT::Architecture=arm64 -o APT::Architectures::=arm64 \
	-o Dir::State::status="$W/state/status" \
	-o Dir::Cache::archives="$W/archives" \
	-o Debug::NoLocking=1 \
	install "$@" 2>&1 | grep -E "newly installed|upgraded" || true
ls "$W"/archives/*.deb > /dev/null 2>&1 || { echo "nothing to install (already present?)"; exit 0; }
echo "downloaded: $(ls "$W"/archives/*.deb | wc -l) packages"

cat > "$W/install.sh" << EOF
set -e
cd /var/cache/l410-stage
export DEBIAN_FRONTEND=noninteractive LANG=C LC_ALL=C
# two passes: a batch dpkg -i does not order pre-dependencies (util-linux/mount need the new
# libblkid/libmount configured first) and needs --auto-deconfigure for lockstep library updates
dpkg -i --force-confold --auto-deconfigure ./*.deb > /var/log/l410-dpkg.log 2>&1 ||
	dpkg -i --force-confold --auto-deconfigure ./*.deb >> /var/log/l410-dpkg.log 2>&1 ||
	{ dpkg --configure -a >> /var/log/l410-dpkg.log 2>&1; grep -A3 "dpkg: " /var/log/l410-dpkg.log | tail -30; exit 1; }
dpkg --configure -a >> /var/log/l410-dpkg.log 2>&1
grep -c "^Setting up" /var/log/l410-dpkg.log
dpkg -l $* | grep -E "^.i" | awk '{print \$1, \$2, \$3}'
EOF
rm -rf "$W/stage" && mkdir -p "$W/stage" && cp "$W"/archives/*.deb "$W/stage/"
bash "$H" on-debian "$W/install.sh" "$W/stage"
