#!/bin/bash
# launch: faster application start (docs/tuning/launch-latency.md).
#
#   l410-rcu-expedited.conf   expedited RCU grace periods: sandboxes and cgroup moves wait on
#                             synchronize_rcu() at every start
#   fonts                     fonts-noto pulls in ~2000 rarely used font files (noto-extra,
#                             ui-extra) that every fontconfig client scans; core, ui-core, CJK,
#                             mono and emoji stay
#   hostnamectl               WPS runs a bare `hostnamectl` at every start, which bus-activates
#                             systemd-hostnamed; answered from a per-boot cache
#   l410-chromium-warm        one Chromium process stays resident without windows (user unit)
#   l410-systemsettings-resident
#                             System Settings stays resident and only shows its window; needs
#                             the patched build (systemsettings-build.sh) in /usr/local/bin
set -e
: "${L410_SYSTEM:=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
. "$L410_SYSTEM/lib.sh"
S=$L410_SYSTEM/launch

install -D -m 644 $S/l410-rcu-expedited.conf /etc/tmpfiles.d/l410-rcu-expedited.conf
live && systemd-tmpfiles --create /etc/tmpfiles.d/l410-rcu-expedited.conf || true

keep="fonts-noto-core fonts-noto-ui-core fonts-noto-mono fonts-noto-cjk fonts-noto-cjk-extra fonts-noto-color-emoji"
inst $keep
apt-mark manual $keep > /dev/null
apt-get purge -y -q fonts-noto fonts-noto-extra fonts-noto-ui-extra fonts-noto-unhinted > /dev/null 2>&1 || true

install -m 755 $S/hostnamectl /usr/local/bin/hostnamectl

if dpkg -s chromium > /dev/null 2>&1; then
	install -m 644 $S/l410-chromium-warm.service /etc/systemd/user/
	systemctl --global enable l410-chromium-warm.service
fi

# resident System Settings: the patched build goes to /usr/local/bin (shadowing Debian's); the
# apt hook moves it aside when Debian's systemsettings changes version
ver=$(dpkg-query -W -f='${Version}' systemsettings 2> /dev/null || true)
if [ -n "$ver" ] && [ ! -x /usr/local/bin/systemsettings ]; then
	asset=systemsettings-${ver#*:}
	if grep -qs " $asset\$" "$L410_SYSTEM/assets.sha256" && fetch_asset "$asset" /usr/local/bin/systemsettings; then
		chmod 755 /usr/local/bin/systemsettings
		install -d /usr/local/lib/l410-launch
		echo "$ver" > /usr/local/lib/l410-launch/systemsettings.version
	else
		echo "launch: no resident systemsettings for $ver; build it with $S/systemsettings-build.sh" >&2
	fi
fi
install -D -m 755 $S/l410-systemsettings-check /usr/local/lib/l410-launch/l410-systemsettings-check
cat > /etc/apt/apt.conf.d/80-l410-systemsettings << 'C'
// L410: drop the patched systemsettings when Debian's changes version (system/launch/install.sh)
DPkg::Post-Invoke { "/usr/local/lib/l410-launch/l410-systemsettings-check || true"; };
C
install -m 644 $S/l410-systemsettings-resident.service /etc/systemd/user/
systemctl --global enable l410-systemsettings-resident.service
echo "launch: rcu_expedited, fonts, hostnamectl cache, resident Chromium/System Settings"
