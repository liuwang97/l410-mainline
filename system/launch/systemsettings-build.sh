#!/bin/bash
# Build Debian's systemsettings (the installed version) with systemsettings-resident.py, on the
# L410 as the desktop user (sudo for apt). Needs a deb-src line in the apt sources.
# Output: ~/src/ss/systemsettings-<version>/build-l410/bin/systemsettings; install it with
#   sudo install -m 755 <that file> /usr/local/bin/systemsettings
# and rebuild after a Plasma upgrade (the copy in /usr/local/bin shadows Debian's).
set -e
H=$(dirname "$(readlink -f "$0")")
ver=$(dpkg-query -W -f='${Version}' systemsettings)
up=${ver%-*}; up=${up#*:}
mkdir -p ~/src/ss && cd ~/src/ss
[ -d systemsettings-$up ] || apt-get source -q systemsettings="$ver"
sudo DEBIAN_FRONTEND=noninteractive apt-get build-dep -y -q systemsettings="$ver"
cd systemsettings-$up
python3 $H/systemsettings-resident.py
cmake -S . -B build-l410 -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/usr \
	-DBUILD_TESTING=OFF -DKDE_INSTALL_USE_QT_SYS_PATHS=ON > build-l410.log 2>&1 || { tail -30 build-l410.log; exit 1; }
nice -n 10 cmake --build build-l410 --target systemsettings
ls -l $PWD/build-l410/bin/systemsettings
