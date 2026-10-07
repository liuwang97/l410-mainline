#!/bin/bash
# Add the T8 audio probe-mode test to a built bundle's initramfs (run in WSL):
#   tests/audio-probe-inject.sh ~/l410/build/<name>/bundle
# Installs tests/audio-probe.sh as /l410-extra.sh (an existing extra.sh is kept
# and called first) and a static build of system/hardware/l410-pcmtest.c.
# Only this bundle's initrd.img changes.
set -e
B=${1:?bundle dir}
REPO=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d /tmp/l410-audio-ir.XXXXXX)
trap 'rm -rf "$W"' EXIT
mkdir "$W/ir"
aarch64-linux-gnu-gcc -static -O2 -Wall -o "$W/l410-pcmtest" "$REPO/system/hardware/l410-pcmtest.c" -lm
aarch64-linux-gnu-strip "$W/l410-pcmtest"
(cd "$W/ir" && gzip -dc "$B/initrd.img" | cpio -id --quiet)
if [ -f "$W/ir/l410-extra.sh" ] && ! grep -q "T8 audio checks" "$W/ir/l410-extra.sh"; then
	mv "$W/ir/l410-extra.sh" "$W/ir/l410-extra-base.sh"
fi
install -m 755 "$REPO/tests/audio-probe.sh" "$W/ir/l410-extra.sh"
install -m 755 "$W/l410-pcmtest" "$W/ir/bin/l410-pcmtest"
(cd "$W/ir" && find . | cpio -o -H newc --quiet | gzip -9) > "$B/initrd.img.new"
mv "$B/initrd.img.new" "$B/initrd.img"
echo "audio probe test added to $B/initrd.img ($(stat -c %s "$B/initrd.img") bytes)"
