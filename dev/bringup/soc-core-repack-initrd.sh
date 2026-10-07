#!/bin/bash
# T1 soc-core: add tests/soc-core-probe-extra.sh to a bundle's initrd as /l410-extra.sh
# (runs in WSL):  soc-core-repack-initrd.sh ~/l410/build/soc-core/bundle
set -e
B=${1:?bundle dir}
REPO=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)
T=$(mktemp -d)
(cd "$T" && gzip -dc "$B/initrd.img" | cpio -id --quiet)
install -m 755 "$REPO/tests/soc-core-probe-extra.sh" "$T/l410-extra.sh"
(cd "$T" && find . | cpio -o -H newc --quiet | gzip -9) > "$B/initrd.img"
rm -rf "$T"
echo "initrd repacked with soc-core diagnostics"
