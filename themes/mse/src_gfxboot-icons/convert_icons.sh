#!/bin/sh
#
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andreas HABEGGER <andreas.habegger@proton.me>
#
# gfxboot is strict and silently fails to display non-conforming JPEGs rather than erroring. The requirements are: baseline (non-progressive), RGB colorspace, 4:2:0 chroma subsampling. Most image editors (GIMP, Photoshop, macOS Preview, online tools) save progressive JPEGs or use 4:4:4/4:2:2 subsampling by default, which breaks gfxboot.
# This script converts the icon_* and screenshot_gnome_* into a supported format
#
#

set -e

for f in icon_*.jpg; do
  convert "$f" -colorspace sRGB -type TrueColor \
    -sampling-factor 4:2:0 -interlace none -quality 92 "$f"
done


convert screenshot_gnome_200.jpg \
	-resize 200x -colorspace sRGB -type TrueColor \
	-sampling-factor 4:2:0 -interlace none -quality 90 \
	screenshot_gnome_200.jpg

convert screenshot_gnome_200.jpg \
	-resize 300x -colorspace sRGB -type TrueColor \
	-sampling-factor 4:2:0 -interlace none -quality 90 \
	screenshot_gnome_300.jpg
