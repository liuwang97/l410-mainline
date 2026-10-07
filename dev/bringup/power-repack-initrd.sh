#!/bin/bash
# T2 power: add tests/power-probe-extra.sh to a bundle's initrd as /l410-extra.sh
# (runs in WSL):  power-repack-initrd.sh ~/l410/build/power/bundle
set -e
B=${1:?bundle dir}
REPO=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
T=$(mktemp -d)
(cd "$T" && gzip -dc "$B/initrd.img" | cpio -id --quiet)
install -m 755 "$REPO/tests/power-probe-extra.sh" "$T/l410-extra.sh"
(cd "$T" && find . | cpio -o -H newc --quiet | gzip -9) > "$B/initrd.img"
rm -rf "$T"
echo "initrd repacked with power diagnostics"
