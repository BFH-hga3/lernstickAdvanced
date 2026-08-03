#!/bin/sh
# ===========================================================================
# build_exam_vbox.sh
#
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andreas HABEGGER <andreas.habegger@proton.me>
#
# PURPOSE
#   Build the MSE exam live ISO, then wrap it into a portable VirtualBox
#   appliance (.ova): a read-only disk holding the live system plus a
#   separate, adaptively-growing persistence overlay disk (Lernstick/live-boot
#   native persistence, label "persistence" + persistence.conf).
#
#   Identity/source come from constants (defaults: MSE / vs / false). Overlay
#   size and VM parameters come from the VBOX_* variables in constants. The
#   .ova and its checksum land in OUTPUT_DIR; intermediate disks live under
#   BUILD_ARTEFACTS_DIR.
# ===========================================================================

set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
export REPO_ROOT

. ./functions.sh
check_and_source_constants

run_build              # builds the ISO (sets IMAGE / PREFIX)
build_virtualbox_ova   # wraps it into an .ova with persistence overlay
