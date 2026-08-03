#!/bin/sh
# ===========================================================================
# build_exam_iso.sh
#
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andreas HABEGGER <andreas.habegger@proton.me>
# SPDX-FileCopyrightText: 2025 Rony STANDTKE <ronny.standtke@bfh.ch>
#
# PURPOSE
#   Build the binary MSE exam live ISO from the currently checked-out branch.
#   This is the default single-image build: identity (ISO_PREFIX/ISO_SUFFIX)
#   and SOURCE come from constants (defaults: MSE / vs / false), so this
#   script sets no overrides.
#
#   Output ISO, checksum and log land in OUTPUT_DIR.
# ===========================================================================

set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
export REPO_ROOT

. ./functions.sh
check_and_source_constants

run_build
