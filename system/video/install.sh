#!/bin/bash
# video: hardware video decoding through the hisi-vdec driver (docs/hardware/vcodec.md).
#
#   chromium-video-decode     /etc/chromium.d/: Chromium's own V4L2 stateless decoder for
#                             H.264, HEVC Main, VP8 and VP9 profile 0
#   gstreamer1.0-plugins-bad  GStreamer's v4l2codecs decoders, which playbin and decodebin
#                             pick over the software ones
#
# Needs a kernel with hisi-vdec (v6.18.54-l410.2 or later); with an older one Chromium and
# GStreamer find no V4L2 decoder and decode in software as before.
set -e
: "${L410_SYSTEM:=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
. "$L410_SYSTEM/lib.sh"
S=$L410_SYSTEM/video
install -D -m 644 $S/chromium-video-decode /etc/chromium.d/l410-video-decode
inst gstreamer1.0-plugins-bad
