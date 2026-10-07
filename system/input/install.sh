#!/bin/bash
# input: touchpad scrolling (docs/tuning/touchpad-scroll.md).
#
#   chromium-touchpad-scroll  /etc/chromium.d/: Chromium on Wayland multiplied two-finger
#                             scrolling by 12; WaylandUnscaledTouchpadScrolling passes it through
#   libinput/                 libinput with a speed-dependent scroll gain (ChromeOS-like curve,
#                             /etc/l410/scroll-accel.conf), installed in /usr/local/lib next to
#                             Debian's; an apt hook disables it when libinput10 changes version
#
# The library is taken from the release when it was built for the installed libinput10,
# otherwise built here from Debian's source (needs network, a few minutes on the L410).
set -e
: "${L410_SYSTEM:=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
. "$L410_SYSTEM/lib.sh"
S=$L410_SYSTEM/input
install -D -m 644 $S/chromium-touchpad-scroll /etc/chromium.d/l410-touchpad-scroll

inst libinput10 curl
ver=$(dpkg-query -W -f='${Version}' libinput10:arm64)
asset=libinput.so.10-$ver
if grep -qs " $asset$" "$L410_SYSTEM/assets.sha256" && fetch_asset "$asset" /tmp/$asset; then
	bash $S/libinput/install.sh --so /tmp/$asset
	rm -f /tmp/$asset
elif live; then
	bash $S/libinput/install.sh
else
	echo "input: no prebuilt libinput for $ver; run system/install.sh input on the L410 to build it" >&2
fi
