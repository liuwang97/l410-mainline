#!/bin/bash
# Audio test for the L410 6.18 kernel (Hi6405 + ASP DMA + SLIMbus + TAS2562).
# Runs as root on the L410 Debian (or with dev/l410-harness.sh --script), no one listens:
# checks card/devices, codec identity, DAPM power, DMA progress, amplifier status
# and that the microphones deliver non-silent data. Prints PASS/FAIL/SKIP lines.
#
# Environment: AUDIO_DUMP_DIR (default /tmp/l410-audio) receives register dumps.

S=sudo
[ "$(id -u)" = 0 ] && S=
OUT=${AUDIO_DUMP_DIR:-/tmp/l410-audio}
mkdir -p "$OUT"
FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
skip() { echo "SKIP: $*"; }
DBG=/sys/kernel/debug
$S mount -t debugfs debugfs $DBG 2>/dev/null

echo "== kernel $(uname -r)"
$S dmesg | grep -iE "hi6405|hi64xx|slimbus|asp.pcm|asp_pcm|tas2562|DA_combine|hisi-asp|snd|asoc" > "$OUT/dmesg-audio.txt"
cat "$OUT/dmesg-audio.txt" | tail -60

# --- 1. codec controller / chip id (M1) ---
if grep -q "Hi6405 version 0x11" "$OUT/dmesg-audio.txt"; then
	pass "Hi6405 detected (version 0x11)"
else
	fail "Hi6405 version not read"
fi

# --- 2. deferred devices ---
$S cat $DBG/devices_deferred 2>/dev/null | grep -iE "codec|slimbus|asp|sound|smartpa|004c|004e|hi64" > "$OUT/deferred.txt"
if [ -s "$OUT/deferred.txt" ]; then
	fail "audio devices still deferred:"; cat "$OUT/deferred.txt"
else
	pass "no audio device deferred"
fi

# codec MCLK and ASP clocks (clock framework view, PMIC gate reg 0x42 bit 0)
for c in clk_pmuaudioclk clk_codecssi clk_asp_subsys; do
	echo "$c: prepare $($S cat $DBG/clk/$c/clk_prepare_count 2>/dev/null) enable $($S cat $DBG/clk/$c/clk_enable_count 2>/dev/null)"
done
for r in $($S sh -c "ls $DBG/regmap/*09*/registers" 2>/dev/null); do
	echo "PMIC $r: $($S grep -E '^0*42:' $r)"
done

# --- 3. card / PCM devices ---
CARD=$(awk '/hi6405/ {print $1; exit}' /proc/asound/cards 2>/dev/null)
cat /proc/asound/cards 2>/dev/null
cat /proc/asound/pcm 2>/dev/null
if [ -n "$CARD" ]; then
	pass "sound card hi6405 is card $CARD"
else
	fail "no hi6405 sound card"
	echo "RESULT: $FAILS failure(s)"
	exit 1
fi
[ -e /dev/snd/pcmC${CARD}D0p ] && pass "playback device pcmC${CARD}D0p" || fail "no playback device"
[ -e /dev/snd/pcmC${CARD}D0c ] && pass "capture device pcmC${CARD}D0c" || fail "no capture device"
# a sound server holding the PCM would make aplay -D hw: fail with EBUSY
BUSY=$($S fuser /dev/snd/pcmC${CARD}D0p /dev/snd/pcmC${CARD}D0c 2>/dev/null)
[ -n "$BUSY" ] && echo "note: PCM held by pid(s) $BUSY: $(ps -o comm= -p $BUSY 2>/dev/null | tr '\n' ' ')"

HAVE_ALSA=1
for t in aplay arecord amixer; do command -v $t > /dev/null || HAVE_ALSA=0; done
if [ $HAVE_ALSA = 1 ]; then
	aplay -l; arecord -l
	aplay -l | grep -q "card $CARD" && pass "aplay -l lists the card" || fail "aplay -l"
	arecord -l | grep -q "card $CARD" && pass "arecord -l lists the card" || fail "arecord -l"
	$S amixer -c $CARD controls > "$OUT/controls.txt"
	for c in "Speaker Playback Switch" "Headset Playback Switch" "Mic Capture Switch" \
		"Headset Mic Capture Switch" "Left ASI1 Sel" "Right ASI1 Sel" "Headphone Jack" "Headset Mic Jack"; do
		grep -q "'$c'" "$OUT/controls.txt" && pass "control '$c'" || fail "control '$c' missing"
	done
else
	skip "alsa-utils not installed: aplay/arecord/amixer tests skipped"
fi

DAPM=$DBG/asoc/hi6405
w() { # widget power state: On/Off
	$S sh -c "for d in $DAPM/*/dapm $DAPM/dapm; do [ -f \"\$d/$1\" ] && head -1 \"\$d/$1\"; done" 2>/dev/null | head -1
}
dma_irqs() { awk '/asp_dma_irq/ {s=0; for (i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i; print s}' /proc/interrupts; }

# --- 4. speaker playback ---
if [ $HAVE_ALSA = 1 ]; then
	$S amixer -c $CARD -q cset name='Headset Playback Switch' off
	$S amixer -c $CARD -q cset name='Speaker Playback Switch' on
	$S amixer -c $CARD -q cset name='Speaker Switch' on 2>/dev/null
	I0=$(dma_irqs)
	# low level 1 kHz tone (-30 dBFS), 4 s
	python3 -c '
import math, struct, sys
n = 48000 * 4
a = int(32767 * 10 ** (-30 / 20))
sys.stdout.buffer.write(b"".join(struct.pack("<hh", int(a * math.sin(2 * math.pi * 1000 * i / 48000)), int(a * math.sin(2 * math.pi * 1000 * i / 48000))) for i in range(n)))
' > "$OUT/tone.raw" 2>/dev/null || head -c $((48000 * 4 * 4)) /dev/zero > "$OUT/tone.raw"
	( $S aplay -D hw:$CARD,0 -t raw -f S16_LE -r 48000 -c 2 --period-size=960 --buffer-size=3840 "$OUT/tone.raw" > "$OUT/aplay.log" 2>&1; echo $? > "$OUT/aplay.rc" ) &
	sleep 2
	cat /proc/asound/card$CARD/pcm0p/sub0/status > "$OUT/pcm0p-status-1.txt" 2>&1
	sleep 0.5
	cat /proc/asound/card$CARD/pcm0p/sub0/status > "$OUT/pcm0p-status-2.txt" 2>&1
	for x in D1_D2_INPUT AUDIO_PLAY_DRV "Speaker Playback" S4_TX_DRV S4_TX_OUTPUT PLL_CLK_SUPPLY; do
		echo "widget $x: $(w "$x")"
	done > "$OUT/dapm-spk.txt"
	$S sh -c "for f in $DBG/asoc/hi6405/*/dapm/* $DBG/asoc/hi6405/dapm/*; do echo \"\$f: \$(head -1 \$f)\"; done" > "$OUT/dapm-all-playing.txt" 2>/dev/null
	$S cat $DBG/hi6405/registers > "$OUT/hi6405-regs-playing.txt" 2>/dev/null
	$S cat $DBG/hi6405-card/amps > "$OUT/amps-playing.txt" 2>/dev/null
	wait
	I1=$(dma_irqs)
	cat "$OUT/dapm-spk.txt" "$OUT/aplay.log"
	[ "$(cat "$OUT/aplay.rc")" = 0 ] && pass "speaker playback (aplay) completed" || fail "aplay failed: $(cat "$OUT/aplay.log")"
	H1=$(awk '/^hw_ptr/ {print $3}' "$OUT/pcm0p-status-1.txt"); H2=$(awk '/^hw_ptr/ {print $3}' "$OUT/pcm0p-status-2.txt")
	echo "hw_ptr $H1 -> $H2, asp_dma_irq $I0 -> $I1"
	if [ -n "$H1" ] && [ -n "$H2" ] && [ "$H2" -gt "$H1" ]; then pass "playback DMA pointer advances"; else fail "playback hw_ptr not advancing"; fi
	[ $((I1 - I0)) -ge 150 ] && pass "ASP DMA interrupts: $((I1 - I0)) in 4 s" || fail "ASP DMA interrupts: $((I1 - I0))"
	for x in AUDIO_PLAY_DRV "Speaker Playback" S4_TX_DRV; do
		grep -q "^widget $x: .*On" "$OUT/dapm-spk.txt" && pass "DAPM $x on while playing" || fail "DAPM $x not on"
	done
	# TAS2562 (from the chips): PWR_CTRL[1:0] = 00 active. Faults: INT_LIVE0/INT_LTCH0
	# (0x1f/0x24) bit 0 over-temperature, bit 1 over-current; INT_LIVE1/INT_LTCH1
	# (0x20/0x25) bits 1-3 brown-out, VBAT under/over-voltage. INT_LTCH0 bit 2 (TDM
	# clock error) latches whenever the I2S clock starts or stops around an active
	# amp and is only reported.
	cat "$OUT/amps-playing.txt"
	n=0
	while read -r dev rest; do
		n=$((n + 1))
		field() { echo "$rest" | tr ' ' '\n' | awk -F= -v r="$1" '$1 == r {print $2}'; }
		pc=$(field 02)
		v0=$(field 1f); v1=$(field 20)
		l0=$(field 24); l1=$(field 25)
		case $pc$v0$v1$l0$l1 in *[!0-9a-f]* | "") fail "amp $dev registers unreadable ($rest)"; continue ;; esac
		[ $((0x$pc & 3)) = 0 ] && pass "amp $dev active while playing (PWR_CTRL=$pc)" || fail "amp $dev not active (PWR_CTRL=$pc)"
		if [ $(((0x$v0 | 0x$l0) & 0x03)) = 0 ] && [ $(((0x$v1 | 0x$l1) & 0x0e)) = 0 ]; then
			pass "amp $dev no over-temperature/over-current/brown-out/VBAT faults"
		else
			fail "amp $dev faults: live 0x1f=$v0 0x20=$v1 latched 0x24=$l0 0x25=$l1"
		fi
		[ $((0x$v0 & 0x04)) = 0 ] || fail "amp $dev TDM clock error while playing"
		[ $((0x$l0 & 0x04)) = 0 ] || echo "note: amp $dev TDM clock error latched (clock start/stop), not live"
	done < "$OUT/amps-playing.txt"
	[ $n = 2 ] || fail "expected 2 amplifiers, got $n"
	$S amixer -c $CARD -q cset name='Speaker Playback Switch' off
fi

# --- 4b. headphone playback (nothing plugged in: the DMA/codec path must still run) ---
if [ $HAVE_ALSA = 1 ]; then
	$S amixer -c $CARD -q cset name='Headset Playback Switch' on
	head -c $((48000 * 4 * 2)) "$OUT/tone.raw" > "$OUT/tone2.raw"
	( $S aplay -D hw:$CARD,0 -t raw -f S16_LE -r 48000 -c 2 --period-size=960 --buffer-size=3840 "$OUT/tone2.raw" > "$OUT/aplay-hp.log" 2>&1; echo $? > "$OUT/aplay-hp.rc" ) &
	sleep 1
	cat /proc/asound/card$CARD/pcm0p/sub0/status > "$OUT/pcm0p-hp-1.txt" 2>&1
	sleep 0.5
	cat /proc/asound/card$CARD/pcm0p/sub0/status > "$OUT/pcm0p-hp-2.txt" 2>&1
	for x in AUDIO_PLAY_DRV "Headset Playback" HP_L_DRV HP_R_DRV Headphone; do
		echo "widget $x: $(w "$x")"
	done > "$OUT/dapm-hp.txt"
	wait
	cat "$OUT/dapm-hp.txt" "$OUT/aplay-hp.log"
	[ "$(cat "$OUT/aplay-hp.rc")" = 0 ] && pass "headphone playback (aplay) completed" || fail "headphone aplay failed: $(cat "$OUT/aplay-hp.log")"
	H1=$(awk '/^hw_ptr/ {print $3}' "$OUT/pcm0p-hp-1.txt"); H2=$(awk '/^hw_ptr/ {print $3}' "$OUT/pcm0p-hp-2.txt")
	if [ -n "$H1" ] && [ -n "$H2" ] && [ "$H2" -gt "$H1" ]; then pass "headphone DMA pointer advances ($H1 -> $H2)"; else fail "headphone hw_ptr not advancing"; fi
	grep -q "^widget AUDIO_PLAY_DRV: .*On" "$OUT/dapm-hp.txt" && pass "DAPM AUDIO_PLAY_DRV on (headphone case)" || fail "DAPM AUDIO_PLAY_DRV not on (headphone case)"
	if $S amixer -c $CARD cget iface=CARD,name='Headphone Jack' 2>/dev/null | grep -q ': values=on'; then
		for x in "Headset Playback" HP_L_DRV HP_R_DRV; do
			grep -q "^widget $x: .*On" "$OUT/dapm-hp.txt" && pass "DAPM $x on (headphone plugged)" || fail "DAPM $x not on (headphone plugged)"
		done
	else
		skip "no headphone plugged in: HP drivers stay off (jack pin), stream checked only"
	fi
	$S amixer -c $CARD -q cset name='Headset Playback Switch' off
fi

# --- 5. microphone capture (internal DMICs) ---
if [ $HAVE_ALSA = 1 ]; then
	$S amixer -c $CARD -q cset name='Headset Mic Capture Switch' off
	$S amixer -c $CARD -q cset name='Mic Capture Switch' on
	$S amixer -c $CARD -q cset name='Internal Mic Switch' on 2>/dev/null
	$S arecord -D hw:$CARD,0 -t raw -f S16_LE -r 48000 -c 2 -d 3 --period-size=960 --buffer-size=3840 "$OUT/mic.raw" > "$OUT/arecord.log" 2>&1
	RC=$?
	cat "$OUT/arecord.log"
	[ $RC = 0 ] && pass "arecord completed" || fail "arecord rc=$RC"
	if [ -s "$OUT/mic.raw" ]; then
		python3 - "$OUT/mic.raw" > "$OUT/mic-check.txt" << 'EOF'
import struct, sys, math
d = open(sys.argv[1], 'rb').read()
n = len(d) // 2
s = struct.unpack('<%dh' % n, d[:n * 2])
s = s[48000 * 2 // 2:]  # skip the first 0.5 s
for ch in (0, 1):
    x = s[ch::2]
    if not x:
        print("FAIL: mic channel %d empty" % ch); continue
    peak = max(abs(v) for v in x)
    rms = math.sqrt(sum(v * v for v in x) / len(x))
    distinct = len(set(x[:4800]))
    ok = peak > 4 and distinct > 8
    print("%s: mic channel %d peak=%d rms=%.1f distinct=%d" % ("PASS" if ok else "FAIL", ch, peak, rms, distinct))
EOF
		cat "$OUT/mic-check.txt"
		FAILS=$((FAILS + $(grep -c "^FAIL" "$OUT/mic-check.txt")))
	else
		fail "no capture data"
	fi
fi

# --- 6. jack state (cannot be exercised unattended) ---
if [ $HAVE_ALSA = 1 ]; then
	for j in 'Headphone Jack' 'Headset Mic Jack'; do
		echo "jack '$j': $($S amixer -c $CARD cget iface=CARD,name="$j" 2>/dev/null | grep ': values')"
	done
	skip "headset plug/unplug events need a person"
fi

$S cat $DBG/hi6405/registers > "$OUT/hi6405-regs-idle.txt" 2>/dev/null
grep -iE "error|fail|timeout|lost" "$OUT/dmesg-audio.txt" | grep -viE "retry|deferred" | head -20 > "$OUT/errors.txt"
if [ -s "$OUT/errors.txt" ]; then echo "--- audio errors in dmesg"; cat "$OUT/errors.txt"; fi
$S dmesg | grep -E "BUG:|WARNING:|Oops|kirin-clk: clk_pmuaudioclk|no PMIC access" -A3 | head -40 > "$OUT/kernel-warn.txt"
if [ -s "$OUT/kernel-warn.txt" ]; then echo "--- kernel warnings / PMIC clock handover"; cat "$OUT/kernel-warn.txt"; fi
echo "dumps in $OUT"
# register dumps back to the harness log
for f in hi6405-regs-playing.txt amps-playing.txt dapm-all-playing.txt; do
	[ -s "$OUT/$f" ] && { echo "===== $f"; cat "$OUT/$f"; }
done
echo "RESULT: $FAILS failure(s)"
[ $FAILS = 0 ]
