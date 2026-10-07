#!/bin/bash
# Graphics test: Kirin 990 display (DRM "kirin") + Mali-G76 (Panfrost) + Mesa.
# Runs on the 6.18 test kernel's Debian, over ssh:
#   dev/l410-harness.sh test <bundle> --script tests/graphics.sh
# (or at boot through dev/bringup/graphics-boot.service when there is no network).
# Prints one "PASS <name>" / "FAIL <name> <why>" / "SKIP <name> <why>" line per check and a
# final "RESULT: PASS|FAIL (n passed, n failed, n skipped)". "MARK" lines say what should be
# on the panel at that moment, for someone watching the screen.
#
# Needs kmscube, libdrm-tests (modetest), glmark2-es2-drm, mesa-utils (eglinfo); if missing
# they are installed from /root/gfx-debs when present (for a machine without internet access).
set -u
PASS=0 FAIL=0 SKIP=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1 ${2:-}"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP $1 ${2:-}"; SKIP=$((SKIP + 1)); }
mark() { echo "MARK $(date +%T) $*"; }
S=sudo
[ "$(id -u)" = 0 ] && S=""
T=$(mktemp -d)
DBG=""
state() { # $1 label: scanout registers from the kirin debugfs file
	[ -n "$DBG" ] || return 0
	echo "   -- kirin_state ($1)"
	$S cat $DBG 2>/dev/null | sed 's/^/      /'
}
underflows() { $S dmesg | grep -c "LDI underflow #" ; }

# The harness feeds this script to "bash -s" on stdin, and kmscube/modetest quit (and
# eat script text) when stdin is readable: the whole test runs as one function whose
# stdin is a pipe that never delivers data.
main() {
echo "== kernel $(uname -r), $(date)"

# ---- test tools ------------------------------------------------------------
missing=0
for p in kmscube libdrm-tests glmark2-es2-drm mesa-utils-bin; do
	dpkg -s $p > /dev/null 2>&1 || missing=1
done
if [ $missing = 1 ] && $S sh -c 'ls /root/gfx-debs/*.deb' > /dev/null 2>&1; then
	$S sh -c 'dpkg -i /root/gfx-debs/*.deb' > $T/dpkg.log 2>&1 || { echo "dpkg failed:"; tail -5 $T/dpkg.log; }
fi

# ---- DRM devices -----------------------------------------------------------
KMS="" RENDER=""
for c in /sys/class/drm/card[0-9]; do
	[ -e "$c/device/driver" ] || continue
	drv=$(basename "$(readlink "$c/device/driver")")
	echo "   $(basename $c): $drv"
	if [ "$drv" = kirin990-dss ]; then
		KMS=/dev/dri/$(basename $c)
		n=${c##*card}
		$S test -r /sys/kernel/debug/dri/$n/kirin_state && DBG=/sys/kernel/debug/dri/$n/kirin_state
	fi
done
for r in /sys/class/drm/renderD*; do
	[ -e "$r/device/driver" ] || continue
	drv=$(basename "$(readlink "$r/device/driver")")
	echo "   $(basename $r): $drv"
	[ "$drv" = panfrost ] && RENDER=/dev/dri/$(basename $r)
done
$S dmesg > $T/dmesg.txt 2>&1

# ---- GPU -------------------------------------------------------------------
if [ -n "$RENDER" ]; then pass "panfrost-render-node ($RENDER)"; else fail panfrost-render-node "no panfrost renderD*"; fi
gpuid=$(grep -m1 -E "panfrost .*mali-g76 id 0x7" $T/dmesg.txt)
if [ -n "$gpuid" ]; then
	pass "panfrost-gpu-id"
	grep -E "panfrost .*(mali-g76 id|features|shader_present|clock rate)|Initialized panfrost" $T/dmesg.txt | head -6 | sed 's/^/   /'
	for d in /sys/class/devfreq/*; do
		[ -e "$d/device/driver" ] && [ "$(basename "$(readlink $d/device/driver)")" = panfrost ] &&
			echo "   devfreq $(basename $d): cur $(cat $d/cur_freq) gov $(cat $d/governor) avail $(cat $d/available_frequencies)"
	done
else
	fail panfrost-gpu-id "no 'mali-g76 id 0x7...' in dmesg"
	grep -i panfrost $T/dmesg.txt | tail -5 | sed 's/^/   /'
fi

# ---- display ---------------------------------------------------------------
if [ -n "$KMS" ]; then pass "kirin-kms-node ($KMS)"; else fail kirin-kms-node "no card bound to kirin990-dss"; fi
grep -E "kirin990-dss.*(firmware mode|scans out|selftest|holding)" $T/dmesg.txt | head -12 | sed 's/^/   /'
state boot
if [ -n "$KMS" ] && [ -r /sys/class/drm/$(basename $KMS)-eDP-1/status ]; then
	st=$(cat /sys/class/drm/$(basename $KMS)-eDP-1/status)
	modes=$(tr '\n' ' ' < /sys/class/drm/$(basename $KMS)-eDP-1/modes)
	if [ "$st" = connected ] && [ -n "$modes" ]; then pass "edp-connector ($modes)"; else fail edp-connector "status $st modes '$modes'"; fi
fi
if [ -n "$KMS" ] && command -v modetest > /dev/null; then
	if $S modetest -M kirin -c > $T/modetest.txt 2>&1 && grep -q "connected" $T/modetest.txt; then
		pass modetest-connectors
		grep -A3 "^Connectors" $T/modetest.txt | sed 's/^/   /'
	else
		fail modetest-connectors "$(head -3 $T/modetest.txt | tr '\n' ' ')"
	fi
else
	skip modetest-connectors "modetest not installed or no KMS node"
fi

# ---- eDP bridge (SN65DSI86 on I2C4 0x2c), read-only status -------------------
if command -v i2cget > /dev/null; then
	bus=$(i2cdetect -l 2>/dev/null | awk '/fa04d000/ { sub("i2c-", "", $1); print $1 }' | head -1)
	if [ -n "$bus" ]; then
		r() { i2cget -f -y $bus 0x2c $1 2>/dev/null || echo "--"; }
		echo "   sn65dsi86 (i2c-$bus): id $(for a in 0 1 2 3 4 5 6 7; do printf '%s ' $(r $a); done)"
		echo "   sn65dsi86: 0x0a pll $(r 0x0a) 0x10 dsi $(r 0x10) 0x12 dsiclk $(r 0x12) 0x93 dp $(r 0x93) 0x94 rate $(r 0x94) 0x96 train $(r 0x96) 0x5a $(r 0x5a) 0x5b bpp $(r 0x5b) irq f0-f8: $(for a in 0xf0 0xf1 0xf2 0xf3 0xf4 0xf5 0xf6 0xf7 0xf8; do printf '%s ' $(r $a); done)"
	fi
fi

# ---- backlight --------------------------------------------------------------
BL=""
for b in /sys/class/backlight/*; do [ -e "$b/max_brightness" ] && BL=$b && break; done
if [ -n "$BL" ]; then
	max=$(cat $BL/max_brightness)
	old=$(cat $BL/brightness)
	mark "backlight to 30% for 3 s, then back to $old/$max"
	echo $((max * 3 / 10)) | $S tee $BL/brightness > /dev/null
	set30=$(cat $BL/actual_brightness)
	sleep 3
	echo $old | $S tee $BL/brightness > /dev/null
	if [ "$set30" = $((max * 3 / 10)) ]; then pass "backlight ($(basename $BL) max $max, was $old)"; else fail backlight "set $((max * 3 / 10)) read $set30"; fi
else
	fail backlight "no /sys/class/backlight device"
fi

# ---- Mesa / EGL -------------------------------------------------------------
if command -v eglinfo > /dev/null && [ -n "$RENDER" ]; then
	$S eglinfo -B -p gbm > $T/eglinfo.txt 2>&1 || true
	if grep -q "Mali-G76 (Panfrost)" $T/eglinfo.txt; then
		pass "eglinfo-gbm-panfrost"
		grep -m3 -E "OpenGL ES profile (renderer|version)|OpenGL core profile version" $T/eglinfo.txt | sed 's/^/   /'
	else
		fail eglinfo-gbm-panfrost "$(grep -m2 -i "renderer\|error" $T/eglinfo.txt | tr '\n' ' ')"
	fi
else
	skip eglinfo-gbm-panfrost "eglinfo missing or no render node"
fi

# ---- KMS + GPU: kmscube (take the panel from getty/sddm first) --------------
stop_display_users() {
	$S systemctl stop sddm.service > /dev/null 2>&1 || true
	$S systemctl stop getty@tty1.service > /dev/null 2>&1 || true
}
if command -v kmscube > /dev/null && [ -n "$KMS" ] && [ -n "$RENDER" ]; then
	stop_display_users
	u0=$(underflows)
	mark "kmscube: spinning coloured cube, 600 frames (~10 s)"
	t0=$(date +%s.%N)
	$S timeout 60 kmscube -D $KMS -c 600 > $T/kmscube.txt 2>&1
	rc=$?
	t1=$(date +%s.%N)
	dt=$(awk "BEGIN { printf \"%.1f\", $t1 - $t0 }")
	grep -iE "renderer|fps|frames" $T/kmscube.txt | head -4 | sed 's/^/   /'
	tail -3 $T/kmscube.txt | sed 's/^/   kmscube: /'
	u1=$(underflows)
	state after-kmscube
	if [ $rc = 0 ] && [ "$u1" = "$u0" ]; then
		pass "kmscube (600 frames in ${dt}s)"
	else
		fail kmscube "rc=$rc, ${dt}s, underflows $u0 -> $u1: $(tail -2 $T/kmscube.txt | tr '\n' ' ')"
	fi
else
	skip kmscube "kmscube missing or no KMS/render node"
fi

# ---- page flips follow the panel refresh (vsync) ---------------------------
if command -v modetest > /dev/null && [ -n "$KMS" ]; then
	stop_display_users
	conn=$(awk '/^Connectors:/ { f = 1; next } f && $3 == "connected" { print $1; exit }' $T/modetest.txt)
	mark "modetest test pattern (colour bars) with page flips, 6 s"
	timeout -s INT 6 modetest -M kirin -s ${conn:-37}:2160x1440 -v > $T/flip.txt 2>&1
	freq=$(grep -oE "freq: [0-9.]+Hz" $T/flip.txt | tail -1 | grep -oE "[0-9.]+")
	echo "   modetest page flip rate: ${freq:-?} Hz"
	if [ -n "$freq" ] && awk "BEGIN { exit !($freq > 50 && $freq < 70) }"; then
		pass "vsync-page-flips (${freq} Hz)"
	else
		fail vsync-page-flips "flip rate ${freq:-unknown}: $(tail -2 $T/flip.txt | tr '\n' ' ')"
	fi
fi

# ---- GPU DVFS: does a frequency request reach the hardware? ------------------
# Pin devfreq to the lowest and to the highest OPP, run the same GPU-bound scene
# off-screen and compare frame rates; also read clk_g3d back (LPM3 publishes the
# OPP it actually runs in SCTRL, which the clock driver reports).
DF=""
for d in /sys/class/devfreq/*; do
	[ -e "$d/device/driver" ] && [ "$(basename "$(readlink $d/device/driver)")" = panfrost ] && DF=$d
done
if [ -n "$DF" ] && command -v glmark2-es2-drm > /dev/null; then
	stop_display_users
	fmin=$(cat $DF/available_frequencies | tr ' ' '\n' | grep . | sort -n | head -1)
	fmax=$(cat $DF/available_frequencies | tr ' ' '\n' | grep . | sort -n | tail -1)
	run_at() { # $1 freq
		echo 0 > $DF/min_freq 2>/dev/null; echo $fmax > $DF/max_freq 2>/dev/null
		if [ $1 = $fmin ]; then echo $1 > $DF/max_freq; else echo $1 > $DF/min_freq; fi
		sleep 1
		local fps
		fps=$(timeout 60 glmark2-es2-drm --off-screen -s 1080x720 -b refract:duration=6 2>&1 |
			grep -oE "FPS: [0-9]+" | grep -oE "[0-9]+")
		echo "${fps:-0} $(cat $DF/cur_freq) $(cat /sys/kernel/debug/clk/clk_g3d/clk_rate 2>/dev/null || echo ?)"
	}
	mark "GPU DVFS check: two short off-screen runs (screen unchanged)"
	read -r fps_lo cur_lo clk_lo <<< "$(run_at $fmin)"
	read -r fps_hi cur_hi clk_hi <<< "$(run_at $fmax)"
	echo 0 > $DF/min_freq 2>/dev/null; echo $fmax > $DF/max_freq 2>/dev/null
	dmesg | grep "kirin-clk: clk_g3d" | tail -6 | sed 's/^/   /'
	echo "   at min: devfreq $cur_lo clk_g3d $clk_lo refract $fps_lo fps"
	echo "   at max: devfreq $cur_hi clk_g3d $clk_hi refract $fps_hi fps"
	# clk_g3d reads back the frequency LPM3 granted (hw vote result register)
	if [ "$clk_lo" = "$fmin" ] && [ "$clk_hi" = "$fmax" ]; then
		pass "gpu-dvfs (granted $clk_lo -> $clk_hi Hz, refract ${fps_lo:-?} -> ${fps_hi:-?} fps)"
	else
		fail gpu-dvfs "requested $fmin/$fmax, granted ${clk_lo:-?}/${clk_hi:-?}, refract ${fps_lo:-?}/${fps_hi:-?} fps"
	fi
else
	skip gpu-dvfs "no panfrost devfreq or glmark2"
fi

# ---- glmark2 on DRM ----------------------------------------------------------
if command -v glmark2-es2-drm > /dev/null && [ -n "$KMS" ] && [ -n "$RENDER" ]; then
	stop_display_users
	u0=$(underflows)
	mark "glmark2-es2-drm: benchmark scenes full screen (~5 min)"
	$S timeout 900 glmark2-es2-drm > $T/glmark2.txt 2>&1
	rc=$?
	u1=$(underflows)
	score=$(grep -oE "glmark2 Score: [0-9]+" $T/glmark2.txt | grep -oE "[0-9]+$")
	grep -E "GL_RENDERER|GL_VERSION|Surface Size" $T/glmark2.txt | sed 's/^/   /'
	grep -E "^\[" $T/glmark2.txt | head -40 | sed 's/^/   /'
	state after-glmark2
	if [ $rc = 0 ] && [ -n "$score" ] && [ "$score" -ge 100 ] && grep -q "Panfrost" $T/glmark2.txt && [ "$u1" = "$u0" ]; then
		pass "glmark2-es2-drm (score $score)"
	else
		fail glmark2-es2-drm "rc=$rc score=${score:-none} underflows $u0 -> $u1 $(grep -m2 -iE "error|fail" $T/glmark2.txt | tr '\n' ' ')"
	fi
else
	skip glmark2-es2-drm "glmark2-es2-drm missing or no KMS/render node"
fi
# ---- weston (Wayland, DRM backend, GL renderer) ------------------------------
if command -v weston > /dev/null && [ -n "$KMS" ] && [ -n "$RENDER" ]; then
	stop_display_users
	u0=$(underflows)
	rm -f /tmp/gfx-weston.log
	mark "weston desktop (grey background, panel) on tty7, weston-simple-egl window, then glmark2-es2-wayland (~5 min)"
	$S systemd-run --quiet --unit=gfx-weston --collect \
		-p PAMName=login -p User=root -p TTYPath=/dev/tty7 -p StandardInput=tty \
		-p Environment=XDG_RUNTIME_DIR=/run/user/0 \
		/usr/bin/weston --backend=drm --renderer=gl --continue-without-input \
		--log=/tmp/gfx-weston.log > /dev/null 2>&1
	$S chvt 7 2>/dev/null || true
	sock=""
	for i in $(seq 30); do
		sock=$(ls /run/user/0/wayland-[0-9] 2>/dev/null | head -1)
		[ -n "$sock" ] && break
		sleep 1
	done
	if [ -n "$sock" ]; then
		grep -iE "GL renderer|GL version|EGL version|Output .* enabled|DRM: head|backend" /tmp/gfx-weston.log | head -8 | sed 's/^/   /'
		W="env XDG_RUNTIME_DIR=/run/user/0 WAYLAND_DISPLAY=$(basename $sock)"
		# simple-egl renders until killed; still running after 8 s = client OK
		$S timeout 8 $W weston-simple-egl > $T/simple-egl.txt 2>&1
		rc=$?
		tail -2 $T/simple-egl.txt | sed 's/^/   simple-egl: /'
		if [ $rc = 124 ]; then pass "weston + weston-simple-egl"; else fail weston-simple-egl "exited rc=$rc"; fi
		if command -v glmark2-es2-wayland > /dev/null; then
			$S timeout 900 $W glmark2-es2-wayland --fullscreen > $T/glmark2w.txt 2>&1
			rc=$?
			score=$(grep -oE "glmark2 Score: [0-9]+" $T/glmark2w.txt | grep -oE "[0-9]+$")
			if [ $rc = 0 ] && [ -n "$score" ] && grep -q "Panfrost" $T/glmark2w.txt; then
				pass "glmark2-es2-wayland (score $score)"
			else
				fail glmark2-es2-wayland "rc=$rc score=${score:-none} $(grep -m2 -iE "error|fail" $T/glmark2w.txt | tr '\n' ' ')"
			fi
		fi
	else
		fail weston "no wayland socket: $(tail -5 /tmp/gfx-weston.log 2>/dev/null | tr '\n' ' ')"
	fi
	state after-weston
	$S systemctl stop gfx-weston.service > /dev/null 2>&1 || true
	$S chvt 1 2>/dev/null || true
	u1=$(underflows)
	[ "$u1" = "$u0" ] || echo "   underflows during weston: $u0 -> $u1"
else
	skip weston "weston missing or no KMS/render node"
fi

mark "tests done, console back"
$S systemctl start getty@tty1.service > /dev/null 2>&1 || true

n=$(underflows)
if [ "$n" = 0 ]; then pass no-underflow; else fail no-underflow "$n LDI underflows"; $S dmesg | grep -m3 "LDI underflow" | sed 's/^/   /'; fi

rm -rf $T
[ $FAIL = 0 ] && R=PASS || R=FAIL
echo "RESULT: $R ($PASS passed, $FAIL failed, $SKIP skipped)"
[ $FAIL = 0 ]
}

main < <(sleep 3600)
