#!/bin/bash
# Build the L410 Debian root filesystem on an x86-64 Debian or Ubuntu host (WSL 2 works), as a
# tarball for rootfs/deploy.sh. The arm64 maintainer scripts run under qemu-user, so allow
# 30-60 minutes for the full desktop.
#
#   sudo rootfs/mkrootfs.sh --user NAME [options] [OUT]
#
#   OUT                 output tarball (default l410-debian-<suite>-<date>.tar.xz)
#   --user NAME         desktop user, member of sudo (required)
#   --password PASS     its password (default: asked on the terminal); L410_PASSWORD works too
#   --ssh-key FILE      authorized_keys for that user (openssh-server is always installed)
#   --hostname NAME     default l410
#   --autologin         SDDM logs the user straight into Plasma
#   --suite SUITE       Debian suite (default forky: Plasma 6.7; trixie has 6.3)
#   --mirror URL        Debian mirror (default https://deb.debian.org/debian)
#   --snapshot STAMP    install the archive as it was at STAMP, e.g. 20261001T120000Z, from
#                       snapshot.debian.org (the package set this repository was tested with)
#   --base              base system only (rootfs/packages-base.txt), no desktop
#   --tmpdir DIR        where the image is assembled (default: next to OUT). It needs about
#                       10 GB; WSL and many distributions mount /tmp as a small tmpfs
#
# Host packages: mmdebstrap qemu-user-static arch-test (binfmt for arm64 registered; check with
# `arch-test arm64`).
#
# Everything that is installed or configured comes from rootfs/packages*.txt and system/; the
# same system/install.sh runs again on the machine for the parts that need the hardware.
set -e
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
TOP=$(dirname "$HERE")
USERNAME= PASSWORD=${L410_PASSWORD:-} SSHKEY= HOSTNAME_=l410 AUTOLOGIN=0
SUITE=forky MIRROR=https://deb.debian.org/debian SNAPSHOT= BASE=0 OUT=
usage() { sed -n '2,27p' "$0"; exit 2; }
while [ $# -gt 0 ]; do
	case $1 in
	--user) USERNAME=$2; shift 2 ;;
	--password) PASSWORD=$2; shift 2 ;;
	--ssh-key) SSHKEY=$(readlink -f "$2"); shift 2 ;;
	--hostname) HOSTNAME_=$2; shift 2 ;;
	--autologin) AUTOLOGIN=1; shift ;;
	--suite) SUITE=$2; shift 2 ;;
	--mirror) MIRROR=$2; shift 2 ;;
	--snapshot) SNAPSHOT=$2; shift 2 ;;
	--base) BASE=1; shift ;;
	--tmpdir) WORK=$2; shift 2 ;;
	-h|--help) usage ;;
	-*) echo "unknown option $1" >&2; usage ;;
	*) OUT=$1; shift ;;
	esac
done
[ -n "$USERNAME" ] || usage
[ "$(id -u)" = 0 ] || { echo "run as root (mmdebstrap needs it for device nodes and ownership)" >&2; exit 1; }
arch-test arm64 > /dev/null || { echo "this host cannot run arm64 binaries: install qemu-user-static" >&2; exit 1; }
if [ -z "$PASSWORD" ]; then
	read -r -s -p "password for $USERNAME: " PASSWORD; echo
	[ -n "$PASSWORD" ] || exit 1
fi
OUT=${OUT:-l410-debian-$SUITE-$(date +%Y%m%d).tar.xz}
OUT=$(readlink -f "$OUT")
WORK=${WORK:-$(dirname "$OUT")}
mkdir -p "$WORK"
export TMPDIR=$(mktemp -d "$WORK/l410-mkrootfs.XXXX")
trap 'rm -rf "$TMPDIR"' EXIT

COMP="main contrib non-free non-free-firmware"
if [ -n "$SNAPSHOT" ]; then
	BASEURL=https://snapshot.debian.org/archive
	MIRROR=$BASEURL/debian/$SNAPSHOT
	SECMIRROR=$BASEURL/debian-security/$SNAPSHOT
	OPTS="[check-valid-until=no] "
else
	SECMIRROR=${MIRROR%/debian}/debian-security
	OPTS=
fi
# the same sources serve the bootstrap and stay in the image; deb-src is there for
# system/mesa/build.sh and system/launch/systemsettings-build.sh (apt-get source / build-dep)
SOURCES=$TMPDIR/sources.list
cat > "$SOURCES" << EOF2
deb $OPTS$MIRROR $SUITE $COMP
deb $OPTS$MIRROR $SUITE-updates $COMP
deb $OPTS$SECMIRROR $SUITE-security $COMP
deb-src $OPTS$MIRROR $SUITE main
EOF2
pkgs() { grep -hv '^#' "$@" | tr -s ' \n' ',' | sed 's/^,//; s/,$//'; }
PKGS=$(pkgs "$HERE/packages-base.txt")
[ $BASE = 1 ] || PKGS=$PKGS,$(pkgs "$HERE/packages-desktop.txt")

# the system/ tree is copied into the image and run there with --chroot (no running systemd,
# no hardware); system/install.sh repeats the hardware parts at the first boot
export L410_USER=$USERNAME L410_PASSWORD=$PASSWORD L410_HOSTNAME=$HOSTNAME_ L410_AUTOLOGIN=$AUTOLOGIN
export L410_SSHKEY=$SSHKEY L410_BASE=$BASE L410_TOP=$TOP
export XZ_OPT=${XZ_OPT:--T0 -6}	# compress on all cores
mmdebstrap --arch=arm64 --variant=important \
	--include="$PKGS" \
	--aptopt='APT::Install-Recommends "true"' \
	--aptopt='Acquire::Check-Valid-Until "false"' \
	--aptopt='Acquire::Retries "5"' \
	--customize-hook='mkdir -p "$1/opt/l410" && cp -a "$L410_TOP/system" "$L410_TOP/boot" "$L410_TOP/tests" "$L410_TOP/tools" "$1/opt/l410/"' \
	--customize-hook='[ -z "$L410_SSHKEY" ] || cp "$L410_SSHKEY" "$1/opt/l410/authorized_keys"' \
	--customize-hook='chroot "$1" env L410_USER="$L410_USER" L410_PASSWORD="$L410_PASSWORD" L410_HOSTNAME="$L410_HOSTNAME" L410_AUTOLOGIN="$L410_AUTOLOGIN" L410_BASE="$L410_BASE" bash /opt/l410/system/install.sh --chroot' \
	--customize-hook='rm -f "$1/opt/l410/authorized_keys" "$1/etc/apt/apt.conf.d/99mmdebstrap"' \
	"$SUITE" "$OUT" "$SOURCES"
ls -l "$OUT"
