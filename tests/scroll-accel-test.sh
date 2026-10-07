#!/bin/bash
# Runs tests/scroll-accel-test.c against a libinput with the L410 scroll acceleration
# (system/input/libinput/) on the L410, as root. The uinput touchpad gets a udev seat of its own,
# so the compositor (seat0) never sees it and the swipes do not scroll the desktop.
#
#   sudo tests/scroll-accel-test.sh [-l libinput.so dir] [-c curve.conf] -- const 20 50 100 ...
#   sudo tests/scroll-accel-test.sh -c system/input/libinput/scroll-accel.conf -- -v flick 300
#
# Without -l the installed libinput is used (/usr/local/lib/aarch64-linux-gnu once installed by
# system/input/libinput/install.sh); without -c the curve the library would read itself.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
libdir= conf=
while [ $# -gt 0 ] && [ "$1" != -- ]; do
	case $1 in
	-l) libdir=$(realpath "$2"); shift 2 ;;
	-c) conf=$(realpath "$2"); shift 2 ;;
	*) echo "unknown option $1" >&2; exit 2 ;;
	esac
done
[ "${1:-}" = -- ] && shift

out=$(mktemp -d)
rule=/run/udev/rules.d/99-l410-scrolltest.rules
cleanup() {
	rm -rf "$out" "$rule"
	udevadm control --reload-rules || true
}
trap cleanup EXIT

gcc -O2 -Wall -o "$out/scroll-accel-test" "$here/tests/scroll-accel-test.c" -linput -lm

mkdir -p /run/udev/rules.d
cat > "$rule" <<'EOF'
SUBSYSTEM=="input", ATTRS{name}=="l410-scrolltest touchpad", ENV{ID_SEAT}="seat-l410test"
EOF
udevadm control --reload-rules
LD_LIBRARY_PATH=$libdir L410_SCROLL_ACCEL_CONFIG=$conf "$out/scroll-accel-test" "$@"
