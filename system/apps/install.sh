#!/bin/bash
# apps: adjustments for WPS Office and QQ, for whichever of them is installed (both come as
# vendor .deb packages from their websites; install them first, then rerun this stage).
#
#   wps/           libl410-fastrsa.so: at every start WPS decrypts the same two blobs with an
#                  RSA-4096 key through its generic 32-bit OpenSSL build (38-65 ms on a big core,
#                  116 ms on a little one, on the main thread); the shim does the private-key
#                  operation with OpenSSL's arm64 code and caches the result per boot
#   qq-desktop.sh  QQ's desktop entry with GTK's built-in Adwaita theme (parsing Breeze's
#                  gtk.css costs Electron ~80 ms at start)
set -e
: "${L410_SYSTEM:=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
. "$L410_SYSTEM/lib.sh"
S=$L410_SYSTEM/apps
if [ -x /usr/bin/wps ]; then
	so=$S/wps/libl410-fastrsa.so
	[ -f "$so" ] || { fetch_asset libl410-fastrsa.so /tmp/libl410-fastrsa.so && so=/tmp/libl410-fastrsa.so; }
	if [ -f "$so" ]; then
		SO=$so bash $S/wps/install.sh
	else
		echo "apps: no libl410-fastrsa.so; build it with $S/wps/build.sh" >&2
	fi
fi
[ -f /usr/share/applications/qq.desktop ] && bash $S/qq-desktop.sh
echo "apps: done"
