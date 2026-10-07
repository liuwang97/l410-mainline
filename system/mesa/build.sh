#!/bin/bash
# Build Debian's Mesa libgallium with the panfrost AFBC patch (mesa-patch.py), on the L410 as
# the desktop user (sudo for apt). It takes the source of exactly the installed Mesa
# (needs a deb-src line in the apt sources), keeps Debian's version string and front-end options
# so libEGL_mesa, libGLX_mesa and dri_gbm load it, and cuts the gallium drivers down to panfrost
# (+kmsro), softpipe and llvmpipe.
#
#   bash system/mesa/build.sh             -> ~/src/mesa/mesa-<ver>/build-l410/.../libgallium-<ver>.so
#   NOLLVM=1 bash system/mesa/build.sh    without LLVM (panfrost + softpipe only), so a GL process
#                                         no longer maps the 130 MB libLLVM (~15 ms per process);
#                                         needs one normal build first for the shader tools
# Then: sudo system/mesa/install.sh --so <that file>
set -e
H=$(dirname "$(readlink -f "$0")")
ver=$(dpkg-query -W -f='${Version}' mesa-libgallium:arm64)
up=${ver%-*}; up=${up#*:}
sudo DEBIAN_FRONTEND=noninteractive apt-get build-dep -y -q mesa="$ver"
mkdir -p ~/src/mesa && cd ~/src/mesa
[ -d mesa-$up ] || apt-get source -q mesa="$ver"
cd mesa-$up
echo "${ver#*:}" > VERSION
python3 "$H/mesa-patch.py"
lib=libgallium-${ver#*:}.so
common=(--prefix=/usr --libdir=lib/aarch64-linux-gnu --buildtype=plain
	-Dc_args="-O2 -g1" -Dcpp_args="-O2 -g1"
	-Ddri-drivers-path=/usr/lib/aarch64-linux-gnu/dri -Dplatforms=x11,wayland
	-Dvulkan-drivers= -Dvulkan-layers= -Dglvnd=enabled -Db_ndebug=true -Dbuild-tests=false
	-Dglx-direct=true -Dgbm=enabled -Dgles1=disabled -Dgles2=enabled -Dteflon=false
	-Dgallium-va=disabled -Dgallium-rusticl=false -Dvideo-codecs= -Dlmsensors=disabled
	-Dvalgrind=disabled)
if [ "${NOLLVM:-0}" = 1 ]; then
	B=build-l410-nollvm
	T=$HOME/src/mesa/tools-$up/bin
	mkdir -p $T
	cp build-l410/src/compiler/clc/mesa_clc build-l410/src/compiler/spirv/vtn_bindgen2 \
		build-l410/src/panfrost/clc/panfrost_compile $T/
	export PATH=$T:$PATH
	[ -d $B ] || meson setup $B "${common[@]}" -Dgallium-drivers=panfrost,softpipe -Dllvm=disabled \
		-Dmesa-clc=system -Dprecomp-compiler=system
else
	B=build-l410
	[ -d $B ] || meson setup $B "${common[@]}" -Dgallium-drivers=panfrost,softpipe,llvmpipe -Dllvm=enabled
fi
nice -n 10 ninja -C $B src/gallium/targets/dri/$lib
ls -l $PWD/$B/src/gallium/targets/dri/$lib
