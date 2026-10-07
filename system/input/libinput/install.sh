#!/bin/bash
# Builds libinput with the L410 touchpad scroll acceleration and installs it next to Debian's
# (run on the L410 as root). docs/tuning/touchpad-scroll.md.
#
#   sudo system/input/libinput/install.sh            build for the installed libinput10, install
#   sudo system/input/libinput/install.sh remove     back to Debian's libinput
#   sudo system/input/libinput/install.sh --so FILE  install a prebuilt library (release asset) built
#                                              this way for the same libinput10 version
#
# The library goes to /usr/local/lib/aarch64-linux-gnu, which ld.so.conf searches before
# /usr/lib/aarch64-linux-gnu, also for the compositor (secure execution still uses ld.so.cache);
# no Debian file is replaced. It is built from the Debian source of exactly the installed
# libinput10 version, with Debian's patches, and the same options as debian/rules.
#
# An apt hook (l410-libinput-check) moves the library aside as soon as libinput10 changes
# version, so a compositor built against a newer libinput never loads an older one; scrolling is
# then linear again until this script is run once more. The compositor picks the library up at
# its next start (log out and in).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
arch=aarch64-linux-gnu
dest=/usr/local/lib/$arch
stamp=$dest/l410-libinput.version
work=${L410_LIBINPUT_WORK:-/var/cache/l410-libinput}
# source packages come from the first mirror in the apt sources (or L410_DEBIAN_MIRROR)
mirror=${L410_DEBIAN_MIRROR:-$(cat /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2> /dev/null |
	awk '/^deb /{ for (i = 2; i <= NF; i++) if ($i ~ /^https?:/) { print $i; exit } }' || true)}
mirror=${mirror:-https://deb.debian.org/debian}

if [ "${1:-}" = remove ]; then
	rm -f "$dest"/libinput.so.10* "$stamp" /etc/apt/apt.conf.d/80-l410-libinput /usr/local/sbin/l410-libinput-check \
		/usr/local/share/l410/scroll-accel-*.conf
	ldconfig
	echo "removed; Debian's libinput is used after the next login (/etc/l410/scroll-accel.conf kept)"
	exit 0
fi

prebuilt=
[ "${1:-}" = --so ] && prebuilt=$(readlink -f "$2")

ver=$(dpkg-query -W -f='${Version}' "libinput10:arm64")
upstream=${ver%-*}
patchfile=$here/0001-touchpad-speed-dependent-two-finger-scroll-gain.patch
src=$work/libinput-$ver-$(sha256sum "$patchfile" | cut -c1-12)
so=$(cd /usr/lib/$arch && readlink libinput.so.10)	# libinput.so.10.13.0
echo "libinput10 $ver"

if [ -n "$prebuilt" ]; then
	built=$prebuilt
else
# the build dependencies of Debian's libinput that this library needs
apt-get install -y -q --no-install-recommends build-essential meson ninja-build pkg-config dpkg-dev curl patch \
	libudev-dev libmtdev-dev libevdev-dev libwacom-dev > /dev/null
mkdir -p "$work"
if [ ! -d "$src" ]; then
	rm -rf "$work"/libinput-*	# other versions or older patches
	pool=$mirror/pool/main/libi/libinput
	tmp=$(mktemp -d "$work/dl.XXXX")
	(
		cd "$tmp"
		curl -sfO "$pool/libinput_$ver.dsc"
		# Files: md5 size name
		awk '/^Files:/{f=1;next} f&&/^ /{print $1, $3} /^[A-Z]/&&!/^Files/{f=0}' "libinput_$ver.dsc" > files
		while read -r md5 name; do
			curl -sfO "$pool/$name"
			echo "$md5  $name" | md5sum -c --quiet -
		done < files
		mkdir src
		tar -xf "libinput_$upstream.orig.tar."* -C src --strip-components=1
		tar -xf "libinput_$ver.debian.tar."* -C src
		cd src
		if [ -f debian/patches/series ]; then
			grep -v '^#' debian/patches/series | while read -r p; do
				[ -n "$p" ] && patch -p1 -s < "debian/patches/$p"
			done
		fi
		patch -p1 < "$patchfile"
	)
	mv "$tmp/src" "$src"
	rm -rf "$tmp"
fi

if [ ! -f "$src/build/build.ninja" ]; then
	# Debian's compiler and hardening flags, as dh_auto_configure passes them
	CFLAGS="$(dpkg-buildflags --get CFLAGS)" CPPFLAGS="$(dpkg-buildflags --get CPPFLAGS)" \
		LDFLAGS="$(dpkg-buildflags --get LDFLAGS)" \
		meson setup "$src/build" "$src" --prefix=/usr --libdir="lib/$arch" --buildtype=plain \
		-Ddocumentation=false -Dudev-dir=/usr/lib/udev -Dtests=false -Ddebug-gui=false >/dev/null
fi
ninja -C "$src/build" "$so" >/dev/null
built=$src/build/$so
fi

# The same dependencies as Debian's build (libwacom, no Lua plugins)
diff <(ldd "/usr/lib/$arch/$so" | awk '{print $1}' | sort) <(ldd "$built" | awk '{print $1}' | sort)

mkdir -p "$dest" /etc/l410
install -m 644 "$built" "$dest/$so.tmp"
strip --strip-unneeded "$dest/$so.tmp"	# as Debian ships it (debug info in the build tree)
mv "$dest/$so.tmp" "$dest/$so"
ln -sf "$so" "$dest/libinput.so.10"
echo "$ver" > "$stamp"
[ -f /etc/l410/scroll-accel.conf ] || install -m 644 "$here/scroll-accel.conf" /etc/l410/
install -D -m 644 "$here/scroll-accel.conf" /usr/local/share/l410/scroll-accel-default.conf
install -m 644 "$here/scroll-accel-gentle.conf" /usr/local/share/l410/
install -m 755 "$here/l410-libinput-check" /usr/local/sbin/
cat > /etc/apt/apt.conf.d/80-l410-libinput <<'EOF'
// L410: drop the locally built libinput when Debian's changes version (system/input/libinput/install.sh)
DPkg::Post-Invoke { "/usr/local/sbin/l410-libinput-check || true"; };
EOF
ldconfig
ldconfig -p | grep -m1 'libinput.so.10 '
echo "installed $dest/$so for $ver; log out and in to load it"
