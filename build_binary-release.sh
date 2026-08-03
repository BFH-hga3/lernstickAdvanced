#!/bin/sh
# ===========================================================================
# build_binary_release.sh
#
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andreas HABEGGER <andreas.habegger@proton.me>
# SPDX-FileCopyrightText: 2025 Rony STANDTKE <ronny.standtke@bfh.ch>
#
# PURPOSE
#   Produce a full BINARY release: walks the configured release branches
#   (RELEASE_STEPS_BINARY in constants), building the .iso image for each via
#   its per-branch build script. Refreshes the tmpfs before every step and
#   restores the starting branch when done.
#
#   With no RELEASE_STEPS_BINARY configured, it safely builds the CURRENTLY
#   checked-out branch using build_exam_iso.sh.
#
#   Prompts whether to shut the machine down after building (long unattended
#   release runs).
# ===========================================================================

set -e

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
export REPO_ROOT

. ./functions.sh
check_and_source_constants

if dialog --yesno "Shutdown system after building is complete?" 0 0
then
	SHUTDOWN_AFTER_BUILDING="true"
fi
clear

run_release "${RELEASE_STEPS_BINARY}" "build_exam_iso.sh"
