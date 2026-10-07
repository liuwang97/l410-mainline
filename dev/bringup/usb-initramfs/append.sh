#!/bin/bash
# Append the usb diagnostics overlay to a bundle's initrd (concatenated cpio).
#   append.sh ~/l410/build/usb/bundle
set -e
B=${1:?bundle dir}
D=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
install -m 755 "$D/l410-extra.sh" "$T/l410-extra.sh"
install -m 755 "$D/l410-udhcpc.sh" "$T/l410-udhcpc.sh"
(cd "$T" && printf '%s\n' l410-extra.sh l410-udhcpc.sh | cpio -o -H newc --quiet | gzip -9) >> "$B/initrd.img"
rm -rf "$T"
echo "appended usb overlay to $B/initrd.img ($(stat -c %s "$B/initrd.img") bytes)"
