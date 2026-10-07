#!/bin/bash
# Concatenate tests/*.sh into one script for `l410-harness.sh test ... --script <out>`.
# Each track test runs in its own subshell with a time limit; the summary lists PASS/FAIL per track.
#   mk-suite.sh [out-file] [track...]     (default: all tests)
set -e
REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-/tmp/l410-suite.sh}
shift || true
if [ $# -gt 0 ]; then
	TESTS=()
	for t in "$@"; do TESTS+=("$REPO/tests/$t.sh"); done
else
	TESTS=("$REPO"/tests/*.sh)
fi
{
	echo '#!/bin/bash'
	echo 'SUMMARY=""'
	for t in "${TESTS[@]}"; do
		[ -f "$t" ] || continue
		n=$(basename "$t" .sh)
		echo "echo '########## $n'"
		echo "cat > /tmp/l410-t-$n.sh << 'L410_TEST_EOF'"
		cat "$t"
		echo 'L410_TEST_EOF'
		# own transient unit: when the test ends (or hits 15 min), systemd kills whatever it left
		# running (weston, test daemons), so nothing keeps the harness ssh session open
		echo "systemd-run --quiet --wait --pipe --collect -p RuntimeMaxSec=900 --unit=l410-test-$n bash /tmp/l410-t-$n.sh < /dev/null; rc=\$?"
		echo "SUMMARY=\"\$SUMMARY\n$n: \$([ \$rc = 0 ] && echo PASS || echo FAIL rc=\$rc)\""
	done
	echo 'echo "########## SUMMARY"'
	echo 'printf "$SUMMARY\n"'
} > "$OUT"
echo "$OUT"
