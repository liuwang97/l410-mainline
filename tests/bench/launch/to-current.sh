#!/bin/bash
. ~/l410-bench/launch-lat/env.sh
[ -f /usr/local/bin/scx_lavd.a76 ] && sudo mv /usr/local/bin/scx_lavd.a76 /usr/local/bin/scx_lavd
sudo systemctl restart scx-lavd
sudo DEBIAN_FRONTEND=noninteractive apt-get remove -y -q fonts-noto fonts-noto-extra fonts-noto-ui-extra fonts-noto-unhinted >/dev/null 2>&1; fc-cache; echo "fonts $(fc-list | wc -l)"
systemctl --user start --no-block l410-chromium-warm.service l410-systemsettings-resident.service
sleep 6; tr "\0" " " < /proc/$(pgrep -x scx_lavd)/cmdline; echo
