#!/bin/sh
# Laptop peripherals on the 6.18 test kernel. Runs on the L410 Debian, e.g. via
#   dev/l410-harness.sh test <bundle> --script tests/laptop.sh
# and also under busybox in the probe-mode initramfs (as /l410-extra.sh, output via pstore),
# so: POSIX sh + busybox tools only.
# Unattended: nobody presses keys, so this checks enumeration, descriptors, EC traffic
# and readings (compared with what the vendor 4.19 kernel reports on the same machine).
# Output: one PASS/FAIL/WARN/INFO line per check, summary at the end.

S=sudo
[ "$(id -u)" = 0 ] && S=
pass=0 fail=0 warn=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
wrn() { echo "WARN $*"; warn=$((warn + 1)); }
inf() { echo "INFO $*"; }

# Reference values from the vendor kernel (Kylin 4.19.71, 2026-09-29)
KBD_HID=0018:14F3:1400
KBD_RDESC_MD5=0b59b50698d56868688aab18b8896682	# 138 bytes
TP_HID=0018:27C6:01E0
TP_RDESC_MD5=2492dad29546e2dd0b0a160dede71bf9	# 665 bytes
BAT_DESIGN_UAH=7230000
BAT_CYCLES_MIN=51

echo "== kernel $(uname -r)"
mountpoint -q /sys/kernel/debug || $S mount -t debugfs none /sys/kernel/debug 2> /dev/null

# give asynchronous probing (i2c-hid, EC battery) up to 30 s after boot
i=0
while [ $i -lt 30 ] && ! { ls -d /sys/bus/hid/devices/$KBD_HID.* && [ -d /sys/class/power_supply/echub-battery ]; } > /dev/null 2>&1; do
	sleep 1
	i=$((i + 1))
done
[ $i -gt 0 ] && inf "waited $i s for devices"

# ---------------------------------------------------------------- I2C-HID
hid_check() { # $1 = label, $2 = HID id prefix, $3 = driver, $4 = rdesc md5, $5 = i2c client
	local d drv md5
	d=$(ls -d /sys/bus/hid/devices/"$2".* 2> /dev/null | head -1)
	if [ -z "$d" ]; then
		bad "$1: no HID device $2 (i2c client $5: $(cat /sys/bus/i2c/devices/$5/name 2> /dev/null || echo missing), driver $(basename "$(readlink /sys/bus/i2c/devices/$5/driver 2> /dev/null)" 2> /dev/null))"
		return
	fi
	drv=$(basename "$(readlink "$d/driver")" 2> /dev/null)
	[ "$drv" = "$3" ] && ok "$1: $(basename "$d") bound to $drv" || bad "$1: $(basename "$d") driver '$drv', want $3"
	md5=$($S cat "$d/report_descriptor" | md5sum | cut -d' ' -f1)
	[ "$md5" = "$4" ] && ok "$1: report descriptor identical to the vendor kernel ($($S cat "$d/report_descriptor" | wc -c) bytes)" ||
		bad "$1: report descriptor md5 $md5, vendor $4"
	[ -e "/sys/kernel/debug/hid/$(basename "$d")/rdesc" ] && inf "$1: $($S head -c 200 /sys/kernel/debug/hid/$(basename "$d")/rdesc | head -1 | cut -c1-80)..."
}
hid_check keyboard $KBD_HID hid-generic $KBD_RDESC_MD5 7-003a
hid_check touchpad $TP_HID hid-multitouch $TP_RDESC_MD5 6-005d

inputs=$(cat /proc/bus/input/devices)
input_block() { # print the /proc/bus/input/devices entries matching regex $1
	printf '%s\n' "$inputs" | awk -v pat="$1" '
		/^I:/ { b = "" }
		{ b = b $0 ORS }
		/^$/ { if (b ~ pat) printf "%s", b; b = "" }
		END { if (b ~ pat) printf "%s", b }'
}
input_has() { # $1 = label, $2 = name regex, $3 = phys
	if input_block "N: Name=\"[^\"]*$2" | grep -q "P: Phys=$3"; then
		ok "input: $1"
	else
		bad "input: $1 (no device matching '$2' phys $3)"
	fi
}
input_has "keyboard" "14F3:1400 Keyboard\"" 7-003a
input_has "keyboard airplane key (Wireless Radio Control)" "14F3:1400 Wireless Radio Control" 7-003a
input_has "touchpad" "27C6:01E0 Touchpad" 6-005d

# 4.19 made separate Consumer Control / System Control devices; mainline hid-input keeps those
# applications on the keyboard's input device. Check the key codes wherever they are.
# These bits only show that the descriptor declares the usages: the EC never sends the F-row
# hotkeys through the Consumer collection (see the scancode check below).
key_bit() { # $1 = KEY bitmap (hex words, most significant first), $2 = key code
	echo "$1" | awk -v n="$2" '{
		w = NF - int(n / 64); if (w < 1) { print 0; exit }
		s = $w; b = n % 64; d = int(b / 4)
		if (d >= length(s)) { print 0; exit }
		v = index("0123456789abcdef", substr(s, length(s) - d, 1)) - 1
		print int(v / 2 ^ (b % 4)) % 2 }'
}
kbd_keys=$(input_block "14F3:1400" | sed -n 's/^B: KEY=//p' | tr '\n' ';')
for k in "113 MUTE" "114 VOLUMEDOWN" "115 VOLUMEUP" "224 BRIGHTNESSDOWN" "225 BRIGHTNESSUP" "116 POWER" "142 SLEEP" "247 RFKILL"; do
	c=${k% *} found=0
	IFS=';'
	for m in $kbd_keys; do [ "$(key_bit "$m" "$c")" = 1 ] && found=1; done
	unset IFS
	[ $found = 1 ] && ok "hotkey: KEY_${k#* } mapped" || bad "hotkey: KEY_${k#* } ($c) not mapped on any keyboard input device"
done
# F1-F10 hotkeys arrive as reserved Keyboard-page usages 0xA5-0xAD (the vendor kernel patched
# them into hid_keyboard[]); on mainline they need system/hardware/61-l410-keyboard.hwdb.
kbd_ev=$(input_block "14F3:1400 Keyboard\"" | sed -n 's/^H: Handlers=.*\(event[0-9]*\).*/\1/p')
if [ -z "$kbd_ev" ]; then
	bad "hotkey scancodes: no event device for the keyboard"
elif ! command -v python3 > /dev/null; then
	wrn "hotkey scancodes: no python3 here, cannot read the keymap (needs udev hwdb anyway)"
else
	km=$($S python3 - /dev/input/$kbd_ev << 'EOF'
import fcntl, struct, sys
fd = open(sys.argv[1], 'rb')
for sc in range(0x700a5, 0x700ae):
    b = bytearray(struct.pack('BBHI32s', 0, 4, 0, 0, struct.pack('<I', sc)))
    fcntl.ioctl(fd, 0x80284504, b)  # EVIOCGKEYCODE_V2
    print('%x=%d' % (sc, struct.unpack('BBHI32s', b)[3]))
EOF
)
	for k in "700a5=224 BRIGHTNESSDOWN" "700a6=225 BRIGHTNESSUP" "700a7=113 MUTE" "700a8=114 VOLUMEDOWN" \
		"700a9=115 VOLUMEUP" "700aa=248 MICMUTE" "700ad=227 SWITCHVIDEOMODE" "700ab=238 WLAN" "700ac=171 CONFIG"; do
		echo "$km" | grep -qx "${k% *}" && ok "hotkey scancode ${k%%=*} -> KEY_${k#* }" ||
			bad "hotkey scancode ${k%%=*} -> $(echo "$km" | grep "^${k%%=*}=" | cut -d= -f2), want KEY_${k#* } (61-l410-keyboard.hwdb installed?)"
	done
fi
tp=$(input_block "27C6:01E0 Touchpad")
echo "$tp" | grep -q "B: ABS=2e0800000000003" && ok "touchpad: multitouch axes as on the vendor kernel" ||
	wrn "touchpad: ABS bits $(echo "$tp" | grep 'B: ABS')"

# keyboard/touchpad IRQ lines
grep -E "huawei-keyboard|goodix-clickpad|elan-clickpad" /proc/interrupts | sed 's/  */ /g' | while read -r l; do inf "irq: $l"; done

# ---------------------------------------------------------------- EC
ec=/sys/bus/i2c/devices/7-0038
drv=$(basename "$(readlink $ec/driver 2> /dev/null)" 2> /dev/null)
[ "$drv" = huawei-echub ] && ok "EC: 7-0038 bound to huawei-echub" || bad "EC: 7-0038 driver '$drv'"
stats=/sys/kernel/debug/huawei-echub/stats
if $S test -r $stats; then
	inf "EC stats: $($S cat $stats | tr '\n' ' ')"
	e0=$($S awk '/^errors:/ { print $2 }' $stats)
	[ "${e0:-1}" = 0 ] && ok "EC: no failed transactions since boot" || bad "EC: $e0 failed transactions since boot"
fi

bat=/sys/class/power_supply/echub-battery
ac=/sys/class/power_supply/echub-ac
if [ -d $bat ]; then
	ok "battery: $bat registered"
	for p in status present capacity capacity_level voltage_now current_now charge_now charge_full \
		charge_full_design energy_now energy_full voltage_min_design voltage_max_design temp cycle_count health; do
		inf "battery $p = $(cat $bat/$p 2> /dev/null)"
	done
	v() { cat $bat/$1 2> /dev/null || echo -1; }
	[ "$(v present)" = 1 ] && ok "battery: present" || bad "battery: not present"
	c=$(v capacity)
	[ "$c" -ge 1 ] && [ "$c" -le 100 ] && ok "battery: capacity $c%" || bad "battery: capacity $c"
	u=$(v voltage_now)
	[ "$u" -ge 6000000 ] && [ "$u" -le 8900000 ] && ok "battery: voltage $u uV (2S pack)" || bad "battery: voltage $u uV"
	[ "$(v charge_full_design)" = $BAT_DESIGN_UAH ] && ok "battery: design capacity $BAT_DESIGN_UAH uAh as on the vendor kernel" ||
		bad "battery: design capacity $(v charge_full_design), vendor $BAT_DESIGN_UAH"
	f=$(v charge_full)
	[ "$f" -ge 5000000 ] && [ "$f" -le $BAT_DESIGN_UAH ] && ok "battery: full charge $f uAh" || bad "battery: full charge $f"
	n=$(v charge_now)
	[ "$n" -ge 0 ] && [ "$n" -le "$f" ] && ok "battery: charge $n uAh" || bad "battery: charge $n uAh (full $f)"
	t=$(v temp)
	[ "$t" -ge 100 ] && [ "$t" -le 550 ] && ok "battery: temperature $t (0.1 C)" || bad "battery: temperature $t"
	cy=$(v cycle_count)
	[ "$cy" -ge $BAT_CYCLES_MIN ] && [ "$cy" -lt 5000 ] && ok "battery: $cy cycles" || bad "battery: cycle count $cy (vendor $BAT_CYCLES_MIN)"
	case $(v status) in
	Charging | Discharging | "Not charging" | Full) ok "battery: status $(v status)" ;;
	*) bad "battery: status $(v status)" ;;
	esac
	[ "$(v health)" = Good ] && ok "battery: health Good" || wrn "battery: health $(v health)"
else
	bad "battery: $bat missing"
fi
if [ -d $ac ]; then
	a=$(cat $ac/online)
	[ "$a" = 1 ] && ok "AC: online (the rig is on mains)" || wrn "AC: online=$a (the rig normally runs on mains)"
	if [ -d $bat ]; then
		s=$(cat $bat/status)
		{ [ "$a" = 1 ] && [ "$s" != Discharging ]; } || { [ "$a" = 0 ] && [ "$s" = Discharging ]; } &&
			ok "AC/battery status consistent ($a/$s)" || bad "AC online=$a but battery $s"
	fi
else
	bad "AC: $ac missing"
fi

# EC stability: poll the battery for a while, EC must not report errors
if $S test -r $stats; then
	e0=$($S awk '/^errors:/ { print $2 }' $stats)
	x0=$($S awk '/^xfers:/ { print $2 }' $stats)
	for i in $(seq 1 12); do cat $bat/uevent > /dev/null 2>&1; sleep 5; done
	e1=$($S awk '/^errors:/ { print $2 }' $stats)
	x1=$($S awk '/^xfers:/ { print $2 }' $stats)
	[ "$e1" = "$e0" ] && [ "$x1" -gt "$x0" ] && ok "EC: $((x1 - x0)) transfers in 60 s, no errors" ||
		bad "EC: errors $e0 -> $e1, transfers $x0 -> $x1 in 60 s"
	echo "0x0280 0x90 1" | $S tee /sys/kernel/debug/huawei-echub/read > /dev/null
	inf "EC raw read of 0280/90 (battery %): $($S cat /sys/kernel/debug/huawei-echub/read)"
fi

# ---------------------------------------------------------------- mute LED
led=/sys/class/leds/platform::mute
if [ -d "$led" ]; then
	ok "mute LED: registered (trigger: $(grep -o '\[[^]]*\]' "$led/trigger"))"
	e0=$($S awk '/^errors:/ { print $2 }' $stats 2> /dev/null)
	echo 1 | $S tee "$led/brightness" > /dev/null && sleep 1 && echo 0 | $S tee "$led/brightness" > /dev/null
	e1=$($S awk '/^errors:/ { print $2 }' $stats 2> /dev/null)
	[ "$e0" = "$e1" ] && ok "mute LED: on/off accepted by the EC" || bad "mute LED: EC errors $e0 -> $e1"
else
	bad "mute LED: $led missing"
fi

# ---------------------------------------------------------------- lid and EC sync GPIOs
lid=$(input_block 'N: Name="echub_lid"')
if [ -n "$lid" ]; then
	echo "$lid" | grep -q "B: SW=1" && ok "lid: switch input device with SW_LID" || bad "lid: no SW_LID bit"
	ev=$(echo "$lid" | grep -o "event[0-9]*" | head -1)
	if [ -n "$ev" ] && command -v evtest > /dev/null; then
		# exit code 10: switch is set (lid closed), 0: open
		$S evtest --query /dev/input/$ev EV_SW SW_LID
		case $? in
		0) ok "lid: SW_LID reads open (the rig's lid is open)" ;;
		10) wrn "lid: SW_LID reads closed" ;;
		*) bad "lid: evtest query on $ev failed" ;;
		esac
	fi
else
	bad "lid: no echub_lid input device"
fi
gpio=$($S cat /sys/kernel/debug/gpio 2> /dev/null)
l=$(echo "$gpio" | grep -i "lid")
if [ -n "$l" ]; then
	inf "lid gpio: $l"
	echo "$l" | grep -q " hi" && ok "lid: open (line high, as on the vendor kernel)" || wrn "lid: line low = closed?"
else
	wrn "lid: line not in /sys/kernel/debug/gpio"
fi
s=$(echo "$gpio" | grep -i "sync")
[ -n "$s" ] && inf "sync gpio: $s"
echo "$s" | grep -q "out hi" && ok "EC state sync: driven high (running)" || bad "EC state sync: '$s'"
a=$(echo "$gpio" | grep -i "ac-detect")
[ -n "$a" ] && inf "AC gpio: $a"

# ---------------------------------------------------------------- USB camera (3196:0203)
if [ -d /sys/bus/usb/devices ]; then
	cam=$(grep -l "^3196$" /sys/bus/usb/devices/*/idVendor 2> /dev/null | head -1)
	if [ -n "$cam" ]; then
		cd=$(dirname "$cam")
		inf "camera: $(cat $cd/product 2> /dev/null) at $(basename $cd), drivers: $(ls -d $cd/*:*/driver 2> /dev/null | xargs -r -n1 readlink | xargs -r -n1 basename | sort -u | tr '\n' ' ')"
		ls /dev/video* > /dev/null 2>&1 && ok "camera: $(ls /dev/video* | tr '\n' ' ')" || wrn "camera: no /dev/video* (uvcvideo module?)"
	else
		inf "camera: 3196:0203 not enumerated (USB track)"
	fi
fi

# ---------------------------------------------------------------- kernel log
log=$($S dmesg | grep -v "L410INIT" | grep -i -E "huawei-echub|echub|i2c_hid|i2c-hid|hid-multitouch|gpio-keys|7-003a|6-005d|7-0038")
echo "$log" | sed 's/^/LOG /' | head -40
echo "$log" | grep -i -E "error|fail|timeout|bad PEC" | grep -v -i "6-0015" > /dev/null &&
	wrn "kernel log has errors for laptop devices (see LOG lines)" || ok "kernel log: no errors for laptop devices"

echo "== laptop: $pass passed, $fail failed, $warn warnings"
[ $fail = 0 ]
