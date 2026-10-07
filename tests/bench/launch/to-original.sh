#!/bin/bash
# switch the tested apps to the pre-optimisation state (reversible with to-current.sh)
. ~/l410-bench/launch-lat/env.sh
systemctl --user stop l410-chromium-warm.service l410-systemsettings-resident.service
pkill -x chromium; pkill -x systemsettings
sudo install -m755 /usr/local/bin/scx_lavd.orig-1.1.3 /usr/local/bin/scx_lavd.run && sudo mv /usr/local/bin/scx_lavd /usr/local/bin/scx_lavd.a76 && sudo mv /usr/local/bin/scx_lavd.run /usr/local/bin/scx_lavd
sudo systemctl restart scx-lavd
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q fonts-noto fonts-noto-extra fonts-noto-ui-extra >/dev/null 2>&1; fc-cache; echo "fonts $(fc-list | wc -l)"
sleep 6; tr "\0" " " < /proc/$(pgrep -x scx_lavd)/cmdline; echo
