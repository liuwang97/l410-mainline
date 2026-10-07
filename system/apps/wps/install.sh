#!/bin/bash
# Install the WPS RSA shim (sudo, on the L410): library, launcher wrappers in /usr/local/bin and copies of
# WPS's desktop entries in /usr/local/share/applications that point at them (XDG_DATA_DIRS lists
# /usr/local/share first, so menus and file associations use them). --remove undoes it.
set -e
H=$(dirname "$(readlink -f "$0")")
A=/usr/local/share/applications
if [ "$1" = --remove ]; then
	rm -rf /usr/local/lib/l410-wps
	for b in wps et wpp wpspdf; do rm -f /usr/local/bin/$b; done
	rm -f $A/wps-office-*.desktop
	exit 0
fi
install -D -m644 ${SO:-$H/libl410-fastrsa.so} /usr/local/lib/l410-wps/libl410-fastrsa.so
for b in wps et wpp wpspdf; do
	[ -x /usr/bin/$b ] && install -m755 $H/wps-wrapper /usr/local/bin/$b
done
install -d $A
for f in /usr/share/applications/wps-office-*.desktop; do
	sed -E 's#(^|[ =])/usr/bin/(wps|et|wpp|wpspdf)( |$)#\1/usr/local/bin/\2\3#g' $f > $A/$(basename $f)
done
grep -h "^Exec=" $A/wps-office-*.desktop
