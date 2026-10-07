#!/bin/sh
# T8 audio checks for the probe-mode initramfs (no network, no Debian needed).
# tests/audio-probe-inject.sh installs this as /l410-extra.sh plus the static
# /bin/l410-pcmtest (system/hardware/l410-pcmtest.c); the initramfs runs it
# during its diagnostics dump and every output line lands in the pstore console
# log with an "L410INIT: extra: " prefix.
T=/bin/l410-pcmtest
D=/sys/kernel/debug
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }

[ -x /l410-extra-base.sh ] && /l410-extra-base.sh

echo "===== audio: kernel messages"
dmesg | grep -iE "hi6405|hi64xx|slimbus|asp.pcm|asp-pcm|tas2562|DA_combine|codec|asoc|snd|sound" | tail -120

i=0
while [ $i -lt 15 ] && ! grep -q hi6405 /proc/asound/cards 2>/dev/null; do
	sleep 1
	i=$((i + 1))
done
echo "===== audio: cards"
cat /proc/asound/cards /proc/asound/pcm 2>&1
ls /dev/snd 2>&1 | tr '\n' ' '; echo
grep -iE "codec|slimbus|asp|sound|smartpa|004c|004e|hi64" $D/devices_deferred
# codec MCLK: clock framework view and the PMIC gate itself (PMIC reg 0x42 bit 0)
for c in clk_pmuaudioclk clk_codecssi clk_asp_subsys; do
	echo "$c: prepare $(cat $D/clk/$c/clk_prepare_count 2>/dev/null) enable $(cat $D/clk/$c/clk_enable_count 2>/dev/null)"
done
for r in $D/regmap/*09*/registers; do
	[ -f "$r" ] && echo "PMIC $(dirname $r): $(grep -E '^0*42:' $r)"
done
dmesg | grep -q "Hi6405 version 0x11" && echo "PASS: Hi6405 version 0x11" || fail "Hi6405 version not read"

CARD=$(awk '/hi6405/ {print $1; exit}' /proc/asound/cards 2>/dev/null)
if [ -z "$CARD" ]; then
	fail "no hi6405 sound card"
	echo "AUDIO RESULT: $FAILS failure(s)"
	exit 0
fi
echo "PASS: sound card hi6405 is card $CARD"

echo "===== audio: controls"
$T list $CARD

dapm_on() {
	for f in $D/asoc/hi6405/*/dapm/* $D/asoc/hi6405/dapm/*; do
		[ -f "$f" ] || continue
		case $(head -n 1 "$f") in *": On"*) echo "on: ${f#$D/asoc/hi6405/} $(head -n 1 "$f")" ;; esac
	done
}
irqs() { grep -E "asp_dma|hi64xx|slimbus|codec" /proc/interrupts | tr -s ' '; }

echo "===== audio: speaker playback"
$T set $CARD 'Headset Playback Switch' off
$T set $CARD 'Speaker Playback Switch' on
$T set $CARD 'Speaker Switch' on
irqs
$T play $CARD 0 4 -30 > /tmp/play.log 2>&1 &
P=$!
sleep 1
cat /proc/asound/card$CARD/pcm0p/sub0/status
sleep 1
cat /proc/asound/card$CARD/pcm0p/sub0/status
dapm_on > /tmp/dapm-play.txt
cat $D/hi6405-card/amps 2>&1
cat $D/hi6405/registers > /tmp/regs-play.txt 2>&1
wait $P || FAILS=$((FAILS + 1))
cat /tmp/play.log
irqs
echo "--- DAPM widgets on while playing"
cat /tmp/dapm-play.txt
for w in AUDIO_PLAY_DRV "Speaker Playback" S4_TX_DRV; do
	grep -q "/$w: On" /tmp/dapm-play.txt && echo "PASS: DAPM $w on" || fail "DAPM $w not on"
done
echo "--- codec registers while playing"
cat /tmp/regs-play.txt
$T set $CARD 'Speaker Playback Switch' off

echo "===== audio: internal microphones"
$T set $CARD 'Headset Mic Capture Switch' off
$T set $CARD 'Mic Capture Switch' on
$T set $CARD 'Internal Mic Switch' on
$T rec $CARD 0 3 2 || FAILS=$((FAILS + 1))
$T rec $CARD 0 2 4 || FAILS=$((FAILS + 1))
dapm_on
$T set $CARD 'Mic Capture Switch' off

echo "===== audio: idle"
sleep 3
dapm_on
cat $D/hi6405-card/amps 2>&1
dmesg | grep -iE "hi6405|hi64xx|slimbus|asp|tas2562|DA_combine" | grep -iE "err|fail|timeout|lost|underrun|overrun" | tail -30
echo "AUDIO RESULT: $FAILS failure(s)"
