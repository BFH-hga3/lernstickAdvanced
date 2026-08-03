#!/bin/sh
# ===========================================================================
# build_tmpfs.sh
#
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Andreas HABEGGER <andreas.habegger@proton.me>
# SPDX-FileCopyrightText: 2025 Rony STANDTKE <ronny.standtke@bfh.ch>
#
# PURPOSE
#   Prepare a fast, RAM-backed build area. Creates (or recreates) an ext4
#   image file inside the tmpfs, mounts it at TMPFS_IMAGE_MOUNT, and links the
#   repo's config/cache/themes into it. Run this before a build to get the
#   5-10x speedup; see tmpfs_rationale in functions.sh for why an ext4 image
#   is used rather than the tmpfs directly (xattr support).
#
#   Building without a tmpfs is still supported (see resolve_build_root); this
#   script is only needed for the RAM-backed path.
# ===========================================================================

set -e

. ./functions.sh
check_and_source_constants

# See the "why an ext4 image inside tmpfs" rationale in functions.sh
# (tmpfs_rationale). Short version: tmpfs is 5-10x faster than disk but lacks
# xattr support that some tools (e.g. flatpak) need, so we put an ext4 image
# inside the tmpfs and build in that.

if findmnt "${TMPFS}" > /dev/null
then
	log_info "found tmpfs mounted on \"${TMPFS}\""
	if findmnt "${TMPFS_IMAGE_MOUNT}" > /dev/null
	then
		log_info "found tmpfs image mounted on \"${TMPFS_IMAGE_MOUNT}\""
		log_info "killing all processes still accessing \"${TMPFS_IMAGE_MOUNT}\""
		fuser -v -k -m "${TMPFS_IMAGE_MOUNT}" || true

		# Retry the unmount instead of a fixed sleep: processes killed by
		# fuser may take a moment to release their handles.
		_unmounted="false"
		_try=0
		while [ "${_try}" -lt 10 ]
		do
			if umount "${TMPFS_IMAGE_MOUNT}" 2>/dev/null
			then
				_unmounted="true"
				break
			fi
			_try=$((_try + 1))
			sleep 1
		done
		if [ "${_unmounted}" = "true" ]
		then
			rm -f "${TMPFS_IMAGE}"
		else
			log_error "unmounting \"${TMPFS_IMAGE_MOUNT}\" failed after ${_try} tries, exiting..."
			exit 1
		fi
	else
		log_info "no tmpfs image mounted on \"${TMPFS_IMAGE_MOUNT}\" found"
	fi

	log_info "creating tmpfs mount point \"${TMPFS_IMAGE_MOUNT}\""
	mkdir -p "${TMPFS_IMAGE_MOUNT}"

	log_info "creating new tmpfs image (${TMPFS_IMAGE_SIZE}G) at \"${TMPFS_IMAGE}\""
	truncate -s "${TMPFS_IMAGE_SIZE}G" "${TMPFS_IMAGE}"

	log_info "creating ext4 file system in tmpfs image..."
	mkfs.ext4 "${TMPFS_IMAGE}"

	log_info "mounting tmpfs image to \"${TMPFS_IMAGE_MOUNT}\""
	mount "${TMPFS_IMAGE}" "${TMPFS_IMAGE_MOUNT}"
else
	log_error "There is no mounted filesystem in \"${TMPFS}\"."
	exit 1
fi

repo_root="$(pwd)"

## Copy configuration from template into the build root.
if [ -d "${TMPFS_IMAGE_MOUNT}/config" ]; then rm -rf "${TMPFS_IMAGE_MOUNT}/config"; fi
cp -a "${repo_root}/config" "${TMPFS_IMAGE_MOUNT}"

## ensure_symlink SRC DST_DIR NAME
## Ensures DST_DIR/NAME is a symlink to SRC, repairing/reporting as needed.
ensure_symlink()
{
	_src="$1"
	_link="$2"
	if [ -L "${_link}" ]
	then
		if [ -e "${_link}" ]
		then
			log_info "The link '${_link}' -> '${_src}' already exists."
			rm ${_link}
			ensure_symlink ${_src} ${_link}
		else
			log_error "The link '${_link}' is a broken link."
			exit 1
		fi
	elif [ -e "${_link}" ]
	then
		log_warn "'${_link}' exists but is not a link."
	else
		log_info "Creating proper '${_link}' -> '${_src}' link."
		ln -s "${_src}" "${_link}"
	fi
}

## Check links to cache and themes directories.
ensure_symlink "${repo_root}/cache"  "${TMPFS_IMAGE_MOUNT}/cache"
ensure_symlink "${repo_root}/themes" "${TMPFS_IMAGE_MOUNT}/themes"

