#!/bin/sh
# make-splashes.sh
#
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andreas HABEGGER <andreas.habegger@proton.me>
#
# Converts a source image into gfxboot-compatible splash screens for a set
# of resolutions. Output: splash_WxH.jpg, forced to baseline sRGB JPEG.
#
# gfxboot needs plain baseline (non-progressive) JPEGs in the sRGB colour
# space — embedded ICC profiles or progressive encoding can break it.

set -e

SRC="${1:-background.png}"
OUTDIR="${2:-.}"

RESOLUTIONS="
800x600
1024x600
1024x768
1280x800
1280x1024
1366x768
1600x900
1920x1080
"

if [ ! -f "$SRC" ]; then
    echo "Source image not found: $SRC" >&2
    exit 1
fi

mkdir -p "$OUTDIR"

for res in $RESOLUTIONS; do
    out="$OUTDIR/splash_${res}.jpg"
    echo "==> $SRC -> $out (${res})"
    convert "$SRC" \
        -colorspace sRGB \
        -resize "${res}^" \
        -gravity center \
        -extent "$res" \
        -strip \
        -interlace none \
        -sampling-factor 4:2:0 \
        -quality 90 \
        "$out"
done

echo "==> Done."
