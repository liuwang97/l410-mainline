# Helpers shared by system/install.sh and the per-area install scripts (sourced, not run).
#
# L410_CHROOT=1   running inside the image being built by rootfs/mkrootfs.sh: no running systemd,
#                 no hardware, no user session. Only files, packages and unit enablement.
# L410_USER       desktop user; default: the user who ran sudo, else the first user with uid 1000+.

: "${L410_CHROOT:=0}"
export DEBIAN_FRONTEND=noninteractive

l410_user() {
	if [ -n "$L410_USER" ]; then
		echo "$L410_USER"
	elif [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != root ]; then
		echo "$SUDO_USER"
	else
		getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 { print $1; exit }'
	fi
}

# install missing packages (no recommends: each area lists what it needs)
inst() {
	local need="" p
	for p in "$@"; do dpkg -s "$p" > /dev/null 2>&1 || need="$need $p"; done
	[ -z "$need" ] && return 0
	[ -n "$(find /var/lib/apt/lists -maxdepth 1 -name '*Packages*' -print -quit)" ] || apt-get update -q
	apt-get install -y -q --no-install-recommends $need
}

# true when we may touch the running system (start units, write sysfs, reload udev)
live() { [ "$L410_CHROOT" != 1 ]; }

# systemctl that only enables in a chroot and also starts/restarts on a live system
enable_now() { if live; then systemctl enable --now "$@"; else systemctl enable "$@"; fi; }

# run a command as the desktop user with its session bus, when there is one
as_user() {
	local u uid
	u=$(l410_user); uid=$(id -u "$u")
	if live && [ -S /run/user/$uid/bus ]; then
		runuser -u "$u" -- env XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus "$@"
	else
		runuser -u "$u" -- "$@"
	fi
}

say() { printf '== %s\n' "$*"; }

# fetch_asset NAME DEST: a prebuilt arm64 binary from the l410-mainline GitHub release, checked
# against system/assets.sha256 (each one is built by the script in the directory that uses it)
L410_ASSETS_URL=${L410_ASSETS_URL:-https://github.com/liuwang97/l410-mainline/releases/download/userspace-2026.10}
fetch_asset() {
	local name=$1 dest=$2 sum
	sum=$(awk -v n="$name" '$2 == n { print $1 }' "$L410_SYSTEM/assets.sha256" 2> /dev/null)
	[ -n "$sum" ] || { echo "no checksum for $name in assets.sha256" >&2; return 1; }
	inst curl ca-certificates
	curl -fsSL --retry 3 -o "$dest.part" "$L410_ASSETS_URL/$name" || { rm -f "$dest.part"; return 1; }
	if ! echo "$sum  $dest.part" | sha256sum -c --quiet -; then
		rm -f "$dest.part"
		echo "$name: checksum mismatch" >&2
		return 1
	fi
	mv "$dest.part" "$dest"
}
