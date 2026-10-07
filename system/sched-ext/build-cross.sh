#!/bin/bash
# Cross-build scx_lavd and scx_bpfland for the L410 on an x86-64 Debian host or WSL:
# about 80 s on the 16-core host instead of ~30 min of full load on the L410
# (build-native.sh is the native alternative). Install: copy both to /usr/local/bin/.
#
#   bash system/sched-ext/build-cross.sh [scx source tarball, default: download scx v1.1.3]
#
# Needs (installed on first use): rustup with the aarch64-unknown-linux-gnu target (scx 1.1
# wants Rust >= 1.91), clang/llvm for the BPF objects, arm64 libelf/zlib/zstd for linking.
# Output: ~/.cache/l410-scx/<src>/target/aarch64-unknown-linux-gnu/release/scx_{lavd,bpfland}
set -e
W=$HOME/.cache/l410-scx
mkdir -p $W
T=${1:-$W/scx-v1.1.3.tar.gz}
[ -f "$T" ] || curl -fL -o "$T" https://github.com/sched-ext/scx/archive/refs/tags/v1.1.3.tar.gz
# libelf, zlib and zstd for arm64 come from Debian multiarch
dpkg --print-foreign-architectures | grep -qx arm64 || { sudo dpkg --add-architecture arm64; sudo apt-get update -q; }
dpkg -s clang libelf-dev:arm64 zlib1g-dev:arm64 libzstd-dev:arm64 > /dev/null 2>&1 ||
	sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q clang llvm lld pkg-config libelf-dev:arm64 \
		zlib1g-dev:arm64 libzstd-dev:arm64 protobuf-compiler
[ -x ~/.cargo/bin/rustup ] || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
. ~/.cargo/env
rustup target add aarch64-unknown-linux-gnu > /dev/null
D=$W/$(tar -tzf "$T" | head -1 | cut -d/ -f1)
[ -d "$D" ] || tar -xzf "$T" -C $W
cd "$D"
# our patches (patches/, in order); already applied ones are skipped
for p in $(dirname "$(readlink -f "$0")")/patches/*.patch; do
	if patch -p1 -R -s -f --dry-run < "$p" > /dev/null 2>&1; then continue; fi
	patch -p1 -s < "$p" && echo "applied $(basename "$p")"
done
export PKG_CONFIG_ALLOW_CROSS=1 PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig PKG_CONFIG_SYSROOT_DIR=/
export CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc AR_aarch64_unknown_linux_gnu=aarch64-linux-gnu-ar
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
cargo build --release --target aarch64-unknown-linux-gnu -p scx_lavd -p scx_bpfland
ls -l $D/target/aarch64-unknown-linux-gnu/release/scx_lavd $D/target/aarch64-unknown-linux-gnu/release/scx_bpfland
