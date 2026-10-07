#!/bin/bash
# Build scx_lavd and scx_bpfland natively on the L410 (about 30 min of full load; build-cross.sh
# does it in about 80 s on a PC) with the patches in patches/, and install them to /usr/local/bin.
# Runs as the desktop user (sudo for apt/install). Needs Debian forky or newer:
# scx v1.1.x wants Rust >= 1.91 (forky: 1.95); on trixie it falls back to rustup.
#
#   bash scx-build.sh [--src <scx-vX.tar.gz>] [--tag v1.1.3] [--fg]
#
# --src   a source tarball, when GitHub is unreachable from the L410
# --fg    build in the foreground (default: a transient user unit scx-build, nice 19, so an
#         ssh drop does not stop it; follow with journalctl --user -fu scx-build)
set -e
TAG=v1.1.3 SRC="" FG=0 INNER=${SCX_INNER:-0}
while [ $# -gt 0 ]; do
	case $1 in
	--src) SRC=$2; shift 2 ;;
	--tag) TAG=$2; shift 2 ;;
	--fg) FG=1; shift ;;
	--inner) INNER=1; shift ;;
	*) echo "usage: $0 [--src tarball] [--tag vX] [--fg]" >&2; exit 2 ;;
	esac
done
D=$HOME/src/scx

if [ $INNER = 0 ]; then
	sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q build-essential clang llvm lld pkg-config libelf-dev \
		libseccomp-dev libbpf-dev bpftool protobuf-compiler zlib1g-dev libzstd-dev git rustc cargo curl
	rv=$(rustc --version | awk '{ print $2 }')
	if [ "$(printf '%s\n1.91.0\n' "$rv" | sort -V | head -1)" != 1.91.0 ]; then
		echo "rustc $rv < 1.91: installing a rustup toolchain for this user"
		export RUSTUP_DIST_SERVER=${RUSTUP_DIST_SERVER:-https://mirrors.ustc.edu.cn/rust-static}
		export RUSTUP_UPDATE_ROOT=$RUSTUP_DIST_SERVER/rustup
		[ -x $HOME/.cargo/bin/rustup ] || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
	fi
	# crates through the USTC mirror (the apt sources use it too)
	mkdir -p $HOME/.cargo
	grep -q ustc $HOME/.cargo/config.toml 2> /dev/null || cat >> $HOME/.cargo/config.toml << 'EOF'
[source.crates-io]
replace-with = "ustc"
[source.ustc]
registry = "sparse+https://mirrors.ustc.edu.cn/crates.io-index/"
[net]
git-fetch-with-cli = true
EOF
	mkdir -p $HOME/src
	if [ -n "$SRC" ]; then
		rm -rf $D; mkdir -p $D; tar -xzf "$SRC" -C $D --strip-components=1
	elif [ ! -d $D/.git ] || [ "$(git -C $D describe --tags 2> /dev/null)" != $TAG ]; then
		rm -rf $D
		git clone --depth 1 --branch $TAG https://github.com/sched-ext/scx $D
	fi
	if [ $FG = 0 ]; then
		systemctl --user reset-failed scx-build 2> /dev/null || true
		systemd-run --user --unit=scx-build -p Nice=19 -E SCX_INNER=1 -E PATH=$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin \
			bash "$(readlink -f "$0")" --inner
		echo "building in user unit scx-build: journalctl --user -fu scx-build"
		exit 0
	fi
fi

# --- the build itself
export PATH=$HOME/.cargo/bin:$PATH
cd $D
# our patches (patches/, in order); already applied ones are skipped
for p in "$(dirname "$(readlink -f "$0")")"/patches/*.patch; do
	patch -p1 -R -s -f --dry-run < "$p" > /dev/null 2>&1 && continue
	patch -p1 -s < "$p" && echo "applied $(basename "$p")"
done
echo "scx $(git describe --tags 2> /dev/null || echo "$TAG (tarball)"), $(rustc --version), $(clang --version | head -1)"
t0=$(date +%s)
cargo build --release -p scx_lavd -p scx_bpfland
sudo install -m 0755 target/release/scx_lavd target/release/scx_bpfland /usr/local/bin/
echo "scx-build done in $(($(date +%s) - t0)) s: $(/usr/local/bin/scx_lavd --version 2>&1 | head -1)"
