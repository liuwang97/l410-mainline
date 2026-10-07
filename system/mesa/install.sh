#!/bin/bash
# mesa: panfrost converts a private AFBC texture to u-interleaved on its first CPU write instead
# of a staging copy, a GPU blit and a flush on every write (docs/tuning/launch-latency.md). Qt
# Quick popups such as the Plasma start menu made ~2500 GPU submissions for their first frame.
#
#   sudo system/mesa/install.sh [--so FILE] [--remove]
#
# The patched libgallium goes to /usr/local/lib/l410-mesa, listed in /etc/ld.so.conf.d before the
# multiarch directory; Debian's package stays untouched. A Mesa upgrade changes the library name
# (libgallium-<version>.so), so a stale copy is simply not used any more; an apt hook says so,
# then rebuild with build.sh. Without --so, the prebuilt file from the release is used when it
# matches the installed Mesa. Log out and in afterwards (KWin and plasmashell together).
set -e
: "${L410_SYSTEM:=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
. "$L410_SYSTEM/lib.sh"
H=$L410_SYSTEM/mesa
L=/usr/local/lib/l410-mesa C=/etc/ld.so.conf.d/00-l410-mesa.conf
if [ "$1" = --remove ]; then
	rm -f $C /etc/apt/apt.conf.d/99l410-mesa-check; rm -rf $L; ldconfig
	echo "removed; log out and in to drop it from running processes"; exit 0
fi
inst mesa-libgallium
ver=$(dpkg-query -W -f='${Version}' mesa-libgallium:arm64)
lib=libgallium-${ver#*:}.so
SO=
if [ "$1" = --so ]; then
	SO=$(readlink -f "$2")
elif grep -qs " $lib$" "$L410_SYSTEM/assets.sha256" && fetch_asset $lib /tmp/$lib; then
	SO=/tmp/$lib
fi
if [ -z "$SO" ]; then
	echo "mesa: no patched $lib (Mesa $ver); build it with system/mesa/build.sh, then rerun with --so" >&2
	exit 0
fi
[ "$(basename "$SO")" = $lib ] || { echo "$SO is not $lib (installed Mesa $ver)" >&2; exit 1; }
install -D -m 644 "$SO" $L/$lib
echo $L > $C
ldconfig
install -m 755 $H/l410-mesa-check $L/
install -m 644 $H/99l410-mesa-check /etc/apt/apt.conf.d/
rm -f /tmp/$lib
echo "mesa: $L/$lib"
