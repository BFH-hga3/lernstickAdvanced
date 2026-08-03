# ---------------------------------------------------------------------------
# Logging helpers
#
# A single consistent log format across every script. Everything goes to
# stderr so it never contaminates stdout (e.g. command substitution).
# ---------------------------------------------------------------------------
log_info()  { echo "[INFO] : $*" >&2; }
log_warn()  { echo "[WARNING] : $*" >&2; }
log_error() { echo "[ERROR] : $*" >&2; }

check_and_source_constants()
{
	if [ -e constants ]
	then
		. ./constants
	else
		log_error "Please copy the file \"constants.example\" to \"constants\" and adopt the settings to your build environment."
		exit 1
	fi
}

# ---------------------------------------------------------------------------
# resolve_build_root()
#
# Decides WHERE the build runs and cd's into it. Two orthogonal concepts:
#
#   BUILD_ROOT  - the directory the build actually runs in. It may be a tmpfs
#                 image mount (fast, RAM-backed) or a plain directory on disk.
#                 The name deliberately does NOT encode which.
#   OUTPUT_DIR  - where finished images and logs are collected afterwards.
#
# Resolution order for BUILD_ROOT:
#   1. If BUILD_ROOT is set in constants, use it verbatim (explicit wins).
#   2. Else, if a tmpfs image is mounted at TMPFS_IMAGE_MOUNT, use that.
#   3. Else, fall back to an on-disk directory and warn.
#
# This makes the no-tmpfs path a first-class, working mode rather than the
# previous half-broken prompt that fell through without cd-ing anywhere.
# ---------------------------------------------------------------------------
resolve_build_root()
{
	# Explicit override always wins.
	if [ -n "${BUILD_ROOT}" ]
	then
		log_info "Using configured BUILD_ROOT: ${BUILD_ROOT}"
	elif [ -n "${TMPFS_IMAGE_MOUNT}" ] && findmnt "${TMPFS_IMAGE_MOUNT}" >/dev/null 2>&1
	then
		BUILD_ROOT="${TMPFS_IMAGE_MOUNT}"
		log_info "tmpfs image mounted; building in ${BUILD_ROOT}"
	else
		# No tmpfs and no explicit BUILD_ROOT. Fall back to an on-disk
		# working directory under the git-ignorable _build root (resolved
		# earlier by resolve_artefact_dirs) so the build still has a defined,
		# version-control-excluded home.
		BUILD_ROOT="${BUILD_ROOT_FALLBACK:-${_artefact_root:-${REPO_ROOT:-$(pwd)}/_build}/work}"
		log_warn "No tmpfs image mounted at '${TMPFS_IMAGE_MOUNT:-<unset>}'."
		log_warn "Building on disk in '${BUILD_ROOT}' (slower). Run build_tmpfs.sh for a RAM-backed build."
	fi

	mkdir -p "${BUILD_ROOT}" || {
		log_error "Could not create build root '${BUILD_ROOT}'."
		exit 1
	}
	cd "${BUILD_ROOT}" || {
		log_error "Could not enter build root '${BUILD_ROOT}'."
		exit 1
	}
	log_info "Build root: $(pwd)"
}

# ---------------------------------------------------------------------------
# resolve_artefact_dirs()
#
# Unifies where build artifacts are stored. Two directories, both defaulting
# under a single git-ignorable root in the repository:
#
#   OUTPUT_DIR           final deliverables: ISO, OVA, checksums, logs.
#   BUILD_ARTEFACTS_DIR  intermediate scratch: VirtualBox base/overlay disks,
#                        the working VM registration, loop mountpoints.
#
# Both default under "<repo>/_build". The leading underscore marks the tree
# for exclusion from version control (add "_*" or "/_build/" to .gitignore).
# Either may be overridden in constants to point elsewhere (e.g. a fast disk
# or a location with more space).
#
# Idempotent and safe to call from any entry point; creates the directories.
# ---------------------------------------------------------------------------
resolve_artefact_dirs()
{
	# Single git-ignorable root under the repo, unless the caller pointed the
	# individual directories elsewhere.
	_artefact_root="${ARTEFACT_ROOT:-${REPO_ROOT:-$(pwd)}/_build}"

	OUTPUT_DIR="${OUTPUT_DIR:-${_artefact_root}/output}"
	BUILD_ARTEFACTS_DIR="${BUILD_ARTEFACTS_DIR:-${_artefact_root}/artefacts}"

	for _d in "${OUTPUT_DIR}" "${BUILD_ARTEFACTS_DIR}"; do
		mkdir -p "${_d}" || {
			log_error "Could not create artifact directory '${_d}'."
			exit 1
		}
	done
	log_info "Output dir     : ${OUTPUT_DIR}"
	log_info "Artefacts dir  : ${BUILD_ARTEFACTS_DIR}"
}

# ---------------------------------------------------------------------------
# run_build()
#
# Shared entry point for every build_*.sh script. Entry scripts may override
# ISO_PREFIX / ISO_SUFFIX / SOURCE (typically after sourcing constants); any
# left unset fall back to the values in constants, and failing that to safe
# built-in defaults applied here. All the previously-duplicated boilerplate
# (build-root resolution, output-dir check, init/configure/build) lives here.
# ---------------------------------------------------------------------------
run_build()
{
	# Safe built-in defaults. These apply only if neither the entry script
	# nor constants set the variable, so a minimal constants file still
	# produces a sensible binary MSE build.
	ISO_PREFIX="${ISO_PREFIX:-MSE}"
	ISO_SUFFIX="${ISO_SUFFIX:-vs}"
	SOURCE="${SOURCE:-false}"
	log_info "Build target: ISO_PREFIX='${ISO_PREFIX}' ISO_SUFFIX='${ISO_SUFFIX}' SOURCE='${SOURCE}'"

	# Resolve where final deliverables and scratch artifacts go (safe
	# defaults under <repo>/_build), creating the directories.
	resolve_artefact_dirs

	# Decide where the build runs (tmpfs or on-disk) and cd there.
	resolve_build_root

	init_build
	configure
	build_image
}

# ---------------------------------------------------------------------------
# run_release()
#
# Shared runner for the release scripts. Walks a list of "branch:build-script"
# steps: for each, checks out the branch, refreshes the tmpfs image, and runs
# the build script. Restores a final branch when done and optionally shuts the
# machine down.
#
# Usage (from a release entry script):
#   run_release "${RELEASE_STEPS_BINARY}" "build_exam_iso.sh"
# where arg 1 is the whitespace-separated step list (may be empty) and arg 2
# is the fallback build script used when the list is empty.
#
# SAFE DEFAULT: an empty step list becomes a single step on the CURRENT branch
# using the fallback build script — i.e. "build what is checked out now".
#
# SHUTDOWN_AFTER_BUILDING (set by the caller) triggers a delayed shutdown at
# the end, preserving the original behaviour.
# ---------------------------------------------------------------------------
run_release()
{
	_steps="$1"
	_fallback_build="$2"

	# Remember the branch we started on so we can return to it unless the
	# caller pinned RELEASE_FINAL_BRANCH explicitly.
	_start_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
	_final_branch="${RELEASE_FINAL_BRANCH:-${_start_branch}}"

	# Safe default: no configured steps -> one step on the current branch
	# with the fallback build script.
	if [ -z "$(printf '%s' "${_steps}" | tr -d ' \t\n')" ]; then
		if [ -z "${_start_branch}" ] || [ "${_start_branch}" = "HEAD" ]; then
			log_warn "No RELEASE_STEPS configured and current branch is unknown/detached."
			log_warn "Running a single build on the current checkout with '${_fallback_build}'."
			_steps="HEAD:${_fallback_build}"
		else
			log_info "No RELEASE_STEPS configured; building current branch '${_start_branch}' with '${_fallback_build}'."
			_steps="${_start_branch}:${_fallback_build}"
		fi
	fi

	# Walk the steps. IFS split on whitespace handles both space- and
	# newline-separated lists.
	_step_no=0
	for _step in ${_steps}; do
		_step_no=$((_step_no + 1))
		_branch="${_step%%:*}"
		_build="${_step#*:}"

		if [ -z "${_branch}" ] || [ -z "${_build}" ] || [ "${_branch}" = "${_step}" ]; then
			log_error "Malformed release step '${_step}' (expected BRANCH:SCRIPT). Skipping."
			continue
		fi

		log_info "=== Release step ${_step_no}: branch '${_branch}' -> ${_build} ==="

		# Only check out if we are not already on the target branch (avoids
		# needless checkouts and a failure on 'HEAD' sentinel).
		if [ "${_branch}" != "HEAD" ]; then
			if ! git checkout "${_branch}"; then
				log_error "git checkout '${_branch}' failed; aborting release."
				return 1
			fi
		fi

		if [ ! -x "./${_build}" ] && [ ! -f "./${_build}" ]; then
			log_error "Build script './${_build}' not found; aborting release."
			return 1
		fi

		./build_tmpfs.sh || { log_error "build_tmpfs.sh failed; aborting."; return 1; }
		"./${_build}"     || { log_error "'${_build}' failed; aborting.";  return 1; }
	done

	# Restore the final branch (best-effort; a failure here shouldn't mask a
	# successful build).
	if [ -n "${_final_branch}" ] && [ "${_final_branch}" != "HEAD" ]; then
		log_info "Restoring branch '${_final_branch}'."
		git checkout "${_final_branch}" || log_warn "Could not restore branch '${_final_branch}'."
	fi

	# Optional shutdown, preserving prior behaviour.
	if [ -n "${SHUTDOWN_AFTER_BUILDING}" ]; then
		log_info "Shutting down in 5 minutes."
		shutdown -h +5
	fi
}

# ---------------------------------------------------------------------------
# tmpfs_rationale (documentation only)
#
# Experience has shown that using a file system in RAM speeds up the build
# process 5 to 10 times compared to SSDs or spinning disks. Unfortunately
# tmpfs doesn't support extended attributes, which some tools need during
# installation (e.g. flatpak). Therefore we don't use the tmpfs mount
# directly; instead we create an image file inside the tmpfs, format it with
# a file system that supports xattrs (ext4), and build inside that image.
#
# This rationale previously lived duplicated in build_tmpfs.sh and
# build_cleanup; it is centralised here so both can reference it.
# ---------------------------------------------------------------------------

init_build()
{
	START=$(date)
	TODAY=$(date +%Y-%m-%d)
}

configure_cd()
{
	ISO_SUFFIX="_bootcd"
	SYSTEM_SUFFIX=" Boot-CD"
	# mv config/chroot_local-packageslists/lernstick_squeeze.list config/chroot_local-packageslists/lernstick_squeeze
	# mv config/chroot_local-packageslists/bootcd config/chroot_local-packageslists/bootcd.list
}

configure()
{
	echo ""
}

get_version_number()
{
	echo $1 | sed 's/.*_\(.*\)_.*/\1/' | sed 's/%3a/:/'
}

cache_cleanup()
{
	echo "removing deprecated packages from cache"
	for DIR in cache/packages.*
	do
		echo "checking directory ${DIR}"
		for FILE in ${DIR}/*
		do
			BASE_NAME=$(basename ${FILE})
			PACKAGE_NAME=$(echo ${BASE_NAME} | sed 's/_.*//')
			if ! ls ${DIR}/${PACKAGE_NAME}_* > /dev/null 2>&1
			then
				echo "package $PACKAGE_NAME not found"
				break
			fi
			VERSIONS=$(ls ${DIR}/${PACKAGE_NAME}_*)
			COUNTER=$(echo ${VERSIONS} | wc -w)
			if [ ${COUNTER} -gt 1 ]
			then
				PACKAGE_VERSION="$(get_version_number ${BASE_NAME})"
				for VERSION in ${VERSIONS}
				do
					OTHER_VERSION="$(get_version_number ${VERSION})"
					if dpkg --compare-versions "${PACKAGE_VERSION}" lt "${OTHER_VERSION}"
					then
						echo "removing deprecated cache file ${FILE} (newer version ${OTHER_VERSION} found)"
						rm ${FILE}
						break
					fi
				done
			fi
		done
	done
}

# ---------------------------------------------------------------------------
# stage_theme()
#
# Stages the selected boot theme (both the gfxboot/BIOS half and the
# GRUB2/UEFI half) from a canonical, version-controlled source directory
# into the live-build tree, then stamps the build date into each.
#
# The theme is selected in the constants file:
#   THEME="mse"                 # or "lernstick", or any themes/<name>
#   THEME_TITLE="MSE Lernstick: Exam Viewing Session -- Debian 13"
#   GRUB_THEME_NAME="mse"       # optional; defaults to ${THEME}
#
# Expected on-disk layout (outside the lb-managed config/ tree):
#   themes/<name>/gfxboot/   -> becomes bootlogo.dir  (xmlboot.config, splash_*,
#                               icon_*, font_size_*.fnt, *.translation)
#   themes/<name>/grub/      -> becomes GRUB themes/<GRUB_THEME_NAME>/
#                               (theme.txt, background.png, *.pf2, ...)
#
# Both halves are fully reconstructed from source on every build, so no theme
# state is left lingering in the lb-managed config/ tree between runs.
# ---------------------------------------------------------------------------
stage_theme()
{
	# --- resolve and validate configuration ---------------------------------
	: "${THEME:?THEME not set in constants (e.g. THEME=\"lernstick\")}"
	#THEME_DIR="${REPO_ROOT:-.}/themes/${THEME}"
	THEME_DIR="themes/${THEME}" ## this works due to `ln -s` in run_cleanup
	# GRUB folder name defaults to the theme name unless overridden.
	GRUB_THEME_NAME="${GRUB_THEME_NAME:-${THEME}}"

	if [ ! -d "${THEME_DIR}" ]; then
		echo "[ERROR] Theme directory '${THEME_DIR}' does not exist."
		echo "        Set THEME in constants to a valid themes/<name> directory."
		exit 1
	fi
	if [ ! -d "${THEME_DIR}/gfxboot" ]; then
		echo "[ERROR] Missing gfxboot assets: '${THEME_DIR}/gfxboot'."
		exit 1
	fi
	if [ ! -d "${THEME_DIR}/grub" ]; then
		echo "[ERROR] Missing GRUB assets: '${THEME_DIR}/grub'."
		exit 1
	fi

	echo "[INFO] Staging theme '${THEME}' from ${THEME_DIR}"

	# --- gfxboot (BIOS / ISOLINUX) ------------------------------------------
	BOOTLOGO="config/bootloaders/isolinux/bootlogo"
	BOOTLOGO_DIR="${BOOTLOGO}.dir"

	if ! command -v gfxboot >/dev/null 2>&1; then
		echo "[ERROR] gfxboot not found on build host. Run: apt install gfxboot gfxboot-dev"
		exit 1
	fi

	# Reconstruct bootlogo.dir entirely from the theme source.
	rm -rf "${BOOTLOGO_DIR}"
	mkdir -p "${BOOTLOGO_DIR}"
	cp -a "${THEME_DIR}/gfxboot/." "${BOOTLOGO_DIR}/"

	if [ ! -e "${BOOTLOGO_DIR}/xmlboot.config" ]; then
		echo "[ERROR] No xmlboot.config in ${THEME_DIR}/gfxboot"
		exit 1
	fi

	# Stamp the build date into the version string, then pack the archive.
	sed -i "s|<version its:translate=\"no\">.*</version>|<version its:translate=\"no\">(Version ${TODAY})</version>|1" \
		"${BOOTLOGO_DIR}/xmlboot.config"
	gfxboot --archive "${BOOTLOGO_DIR}" --pack-archive "${BOOTLOGO}"
	echo "[INFO] Packed gfxboot bootlogo for theme '${THEME}'"

	# --- GRUB2 (UEFI) -------------------------------------------------------
	GRUB_THEME_DIR="config/includes.binary/boot/grub/themes/${GRUB_THEME_NAME}"

	# Reconstruct the GRUB theme directory entirely from the theme source.
	rm -rf "${GRUB_THEME_DIR}"
	mkdir -p "${GRUB_THEME_DIR}"
	cp -a "${THEME_DIR}/grub/." "${GRUB_THEME_DIR}/"

	if [ -e "${GRUB_THEME_DIR}/theme.txt" ]; then
		# Title text is theme-specific; take it from constants with a fallback.
		_grub_title="${THEME_TITLE:-Lernstick: Exam Version -- Debian 13}"
		sed -i "s|title-text.*|title-text: \"${_grub_title} (Version ${TODAY})\"|1" \
			"${GRUB_THEME_DIR}/theme.txt"
		echo "[INFO] Added date and ID string to GRUB title"
	else
		echo "[ERROR] No file 'theme.txt' exists in ${GRUB_THEME_DIR}"
		exit 1
	fi
       

	# Substitute the theme name into the GRUB config (build-time, declarative).
	# Template line in the source grub.cfg:
	#   set theme="/boot/grub/themes/@GRUB_THEME_NAME@/theme.txt"
	GRUB_CFG="config/includes.binary/boot/grub/grub.cfg"
	if [ -e "${GRUB_CFG}" ]; then
		sed -i "s|@GRUB_THEME_NAME@|${GRUB_THEME_NAME}|g" "${GRUB_CFG}"
		# Fail loudly if a placeholder slipped through unsubstituted.
		if grep -q '@GRUB_THEME_NAME@' "${GRUB_CFG}"; then
			echo "[ERROR] Unsubstituted @GRUB_THEME_NAME@ remains in ${GRUB_CFG}"
			exit 1
		fi
		echo "[INFO] Set GRUB theme path to themes/${GRUB_THEME_NAME}"
	else
		echo "[ERROR] GRUB config not found: ${GRUB_CFG}"
		exit 1
	fi

	# --- Theme icon (.ico) --------------------------------------------------
	# The theme ships an .ico at the top of themes/<THEME>/ (alongside the
	# gfxboot/ and grub/ folders). Copy it into the ISO binary tree so it is
	# present on the built image. Icon filename defaults to <THEME>.ico but
	# can be overridden in constants via THEME_ICON_NAME.
	THEME_ICON_NAME="${THEME_ICON_NAME:-${THEME}.ico}"
	THEME_ICON="${THEME_DIR}/${THEME_ICON_NAME}"
	BINARY_DIR="config/includes.binary"

	if [ -e "${THEME_ICON}" ]; then
		mkdir -p "${BINARY_DIR}"
		cp "${THEME_ICON}" "${BINARY_DIR}/"
		echo "[INFO] Staged theme icon '${THEME_ICON_NAME}' to ${BINARY_DIR}/"

		# --- Freedesktop volume icon & name ------------------------------
		# Give the mounted ISO a branded icon and display name in file
		# managers, using an image bundled on the medium itself (no host-side
		# install required). live-build masters the ISO with Rock Ridge
		# enabled by default, so the leading-dot filenames and the PNG all
		# survive on the medium.
		#
		# Primary mechanism: .xdg-volume-info at the volume root. This is a
		# first-class GVfs feature (g_vfs_mount_info_query_xdg_volume_info),
		# so it IS honored on GNOME/Nautilus and other GVfs-based managers.
		# It is an XDG key file with a [Volume Info] group:
		#     Name     - display name (locale-aware; Name[de]=... works too)
		#     IconFile - path to an image on the medium, resolved relative
		#                to the volume root (this is what carries our logo)
		#     Icon     - fallback themed-icon NAME (used only if IconFile is
		#                absent/unresolvable)
		# When IconFile is set, GVfs builds the icon straight from that file
		# on the disc, so the logo displays on a stock GNOME system.
		#
		# Secondary: a .directory desktop entry is also written for KDE /
		# Dolphin, which reads that instead. The two do not conflict.
		#
		# The PNG is derived from the theme .ico. Its name defaults to
		# .VolumeIcon.png but can be overridden via THEME_VOLICON_NAME.
		# The visible name defaults to THEME_TITLE.
		THEME_VOLICON_NAME="${THEME_VOLICON_NAME:-.VolumeIcon.png}"
		_volicon_src="${THEME_ICON}"
		_volicon_dst="${BINARY_DIR}/${THEME_VOLICON_NAME}"
		_volname="${THEME_TITLE:-${THEME}}"

		if command -v convert >/dev/null 2>&1; then
			# An .ico may contain several sizes; take the largest frame so
			# the volume icon is as crisp as possible, force sRGB, strip
			# any profile, and emit a clean truecolor+alpha PNG.
			_largest=$(identify -format '%p %w\n' "${_volicon_src}" 2>/dev/null \
				| sort -k2 -n | tail -1 | cut -d' ' -f1)
			_largest="${_largest:-0}"
			if convert "${_volicon_src}[${_largest}]" \
				-colorspace sRGB -strip -type TrueColorAlpha \
				PNG32:"${_volicon_dst}" 2>/dev/null; then
				echo "[INFO] Converted theme icon to volume PNG '${THEME_VOLICON_NAME}'"

				# Primary: .xdg-volume-info (GNOME/GVfs). IconFile is
				# resolved relative to the volume root.
				cat > "${BINARY_DIR}/.xdg-volume-info" <<-EOF
					[Volume Info]
					Name=${_volname}
					IconFile=${THEME_VOLICON_NAME}
				EOF
				echo "[INFO] Wrote '.xdg-volume-info' (IconFile=${THEME_VOLICON_NAME})"

				# Secondary: .directory for KDE/Dolphin. Icon path is
				# relative to the volume root so it resolves off the medium.
				cat > "${BINARY_DIR}/.directory" <<-EOF
					[Desktop Entry]
					Icon=./${THEME_VOLICON_NAME}
					Name=${_volname}
				EOF
				echo "[INFO] Wrote KDE volume '.directory' (Icon=./${THEME_VOLICON_NAME})"
			else
				echo "[WARN] Failed to convert '${THEME_ICON_NAME}' to PNG; skipping volume-info files"
			fi
		else
			echo "[WARN] 'convert' (ImageMagick) not on build host; skipping volume PNG and volume-info files"
		fi
	else
		echo "[WARN] Theme icon not found: '${THEME_ICON}' (skipping icon staging)"
	fi

}

# ---------------------------------------------------------------------------
# generate_password_hashes()
#
# Generates yescrypt password hashes on the BUILD HOST before the chroot is
# entered. chroot hooks cannot read host environment variables, so the hashes
# are written into includes.chroot_before_packages where a chroot hook can
# pick them up. Requires: whois (provides mkpasswd) on the build host.
# ---------------------------------------------------------------------------
generate_password_hashes()
{
	echo "Generating MSE password hashes on host..."
	if [ -z "${MSE_USER_PASSWORD}" ] || [ -z "${MSE_ADMIN_PASSWORD}" ]; then
		echo "ERROR: MSE_USER_PASSWORD and/or MSE_ADMIN_PASSWORD not set in constants."
		echo "       Set both variables in your constants file before building."
		exit 1
	fi
	if [ ${#MSE_ADMIN_PASSWORD} -lt 8 ]; then
		echo "ERROR: Admin passwords must be at least 8 characters."
		exit 1
	fi
	if [ ${#MSE_USER_PASSWORD} -lt 4 ]; then
		echo "ERROR: User passwords must be at least 4 characters."
		exit 1
	fi
	
	if ! command -v mkpasswd >/dev/null 2>&1; then
		echo "ERROR: mkpasswd not found on build host. Run: apt install whois"
		exit 1
	fi
	MSE_HASH_DIR="config/includes.chroot_before_packages/etc/mse"
	mkdir -p "${MSE_HASH_DIR}"
	mkpasswd --method=yescrypt "${MSE_USER_PASSWORD}" > "${MSE_HASH_DIR}/user.hash"
	mkpasswd --method=yescrypt "${MSE_ADMIN_PASSWORD}" > "${MSE_HASH_DIR}/admin.hash"
	chmod 600 "${MSE_HASH_DIR}/user.hash" "${MSE_HASH_DIR}/admin.hash"
	echo "    Hash written: ${MSE_HASH_DIR}/user.hash"
	echo "    Hash written: ${MSE_HASH_DIR}/admin.hash"
}

build_image()
{
	# Stage the selected boot theme (gfxboot + GRUB) from themes/<name>/ and
	# stamp the build date into both halves.
	stage_theme

	# Generate password hashes on the host before entering the chroot.
	generate_password_hashes

	# update configuration
	rm -f config/binary
	rm -f config/bootstrap
	rm -f config/build
	rm -f config/chroot
	rm -f config/common
	rm -f config/source
	lb clean
	lb config \
		--apt-indices false \
		--apt-recommends true \
		--architectures amd64 \
		--archive-areas "main contrib non-free non-free-firmware" \
		--bootloaders "syslinux,grub-efi" \
		--chroot-squashfs-compression-level 22 \
		--chroot-squashfs-compression-type zstd \
		--debootstrap-options "--include=ca-certificates,openssl" \
		--distribution trixie \
		--firmware-chroot false \
		--iso-volume "${ISO_PREFIX}-${ISO_SUFFIX}_${TODAY}" \
		--linux-packages linux-image-6.18.15+deb13 \
		--mirror-binary ${MIRROR_SYSTEM} \
		--mirror-binary-security ${MIRROR_SECURITY_SYSTEM} \
		--mirror-bootstrap ${MIRROR_BUILD} \
		--security true \
		--source ${SOURCE} \
		--updates true \
		--verbose

	# build image (and produce a log file)
	lb build 2>&1 | tee logfile.txt

	ISO_FILE="live-image-amd64.hybrid.iso"
	if [ -f ${ISO_FILE} ]
	then
		PREFIX="${ISO_PREFIX}_deb-13-${ISO_SUFFIX}_${TODAY}"
		IMAGE="${PREFIX}.iso"
		mv ${ISO_FILE} ${IMAGE}
		# we must update the zsync file because we renamed the iso file
		echo "Updating zsync file..." | tee -a logfile.txt
		rm -f *.zsync
		zsyncmake -C ${IMAGE} -u ${IMAGE}
		echo "Creating MD5 for iso..." | tee -a logfile.txt
		md5sum ${IMAGE} > ${IMAGE}.md5

		if [ "${SOURCE}" = "true" ]
		then
			# debian live sources
			mv live-image-source.live.tar ${PREFIX}-source.live.tar

			# debian sources
			DEBIAN_TAR="${PREFIX}-source.debian.tar"
			mv live-image-source.debian.tar ${DEBIAN_TAR}
			md5sum ${DEBIAN_TAR} > ${DEBIAN_TAR}.md5
		fi

		# move finished artifacts from the build root to the output dir
		if [ -d "${OUTPUT_DIR}" ]
		then
			mv ${PREFIX}* "${OUTPUT_DIR}"
		fi
	else
		echo "Error: ISO file was not built" | tee -a logfile.txt
	fi

	cache_cleanup

	# When installing firmware-b43legacy-installer downloads.openwrt.org is
	# sometimes down. Building doesn't fail in this situation but we would
	# have produced an image without support for some legacy broadcom cards.
	# Therefore we must check via eyeballs what happened...
	grep downloads.openwrt.org logfile.txt

	echo "Start: ${START}" | tee -a logfile.txt
	echo "Stop : $(date)" | tee -a logfile.txt
	if [ -d "${OUTPUT_DIR}" ]
	then
		mv logfile.txt "${OUTPUT_DIR}"
	fi
}

# ---------------------------------------------------------------------------
# build_virtualbox_ova()
#
# Wraps the finished live ISO into a portable VirtualBox appliance (.ova):
#
#   * a READ-ONLY base disk holding the live system, produced by converting
#     the hybrid ISO to a dynamically-allocated VDI (VBoxManage convertfromraw
#     --variant Standard). The ISO is a hybrid image, so it is bootable as a
#     raw disk; the VM boots it exactly like a USB stick.
#   * a separate PERSISTENCE OVERLAY disk: a dynamically-allocated (adaptive,
#     thin-provisioned) VDI whose single partition carries the GPT name and
#     ext4 label "persistence" plus a persistence.conf at its root, which is
#     exactly what Debian live-boot/Lernstick probes for. The VM boots with
#     the "persistence" kernel parameter (set in the boot config) so writes
#     land on this overlay and survive reboots.
#
# The overlay size is configured in constants:
#   VBOX_OVERLAY_SIZE_GB   overlay capacity in GB (default 8)
#   VBOX_OVERLAY_CONF      persistence.conf body (default "/ union" = full
#                          overlay). Set to e.g. "/home\n/etc union" for
#                          selective persistence.
#   VBOX_VM_NAME           appliance/VM name (default from ISO_PREFIX)
#   VBOX_VM_RAM_MB         guest RAM in MB (default 2048)
#   VBOX_VM_VRAM_MB        video RAM in MB (default 32)
#
# The overlay grows adaptively: --variant Standard means the .vdi only
# consumes host space as the guest actually writes into it, up to the
# configured capacity. Nothing is pre-allocated.
#
# Requires on the build host: VBoxManage, parted, mkfs.ext4, and privileges
# to loop-mount (for writing persistence.conf). Degrades to a clear error if
# any are missing, without touching the already-built ISO.
#
# Call AFTER build_image(), with IMAGE / PREFIX referring to the built ISO.
# Typically invoked from a dedicated build_*_vbox.sh entry script.
# ---------------------------------------------------------------------------
build_virtualbox_ova()
{
	# Ensure artifact directories exist even when this is invoked directly
	# (not via run_build). Idempotent; honours constants / defaults.
	resolve_artefact_dirs

	# --- locate the source ISO ---------------------------------------------
	# Prefer an explicitly passed path; else the just-built ${IMAGE}; else the
	# newest matching ISO in OUTPUT_DIR.
	_iso="${1:-${IMAGE}}"
	if [ -z "${_iso}" ] || [ ! -f "${_iso}" ]; then
		if [ -n "${PREFIX}" ] && [ -f "${OUTPUT_DIR}/${PREFIX}.iso" ]; then
			_iso="${OUTPUT_DIR}/${PREFIX}.iso"
		fi
	fi
	if [ -z "${_iso}" ] || [ ! -f "${_iso}" ]; then
		log_error "build_virtualbox_ova: no source ISO found (looked for '${1:-${IMAGE}}')."
		return 1
	fi
	log_info "VirtualBox: using source ISO '${_iso}'"

	# --- resolve configuration ---------------------------------------------
	_vm_name="${VBOX_VM_NAME:-${ISO_PREFIX:-live}-vs}"
	_overlay_gb="${VBOX_OVERLAY_SIZE_GB:-8}"
	_overlay_conf="${VBOX_OVERLAY_CONF:-/ union}"
	_ram="${VBOX_VM_RAM_MB:-2048}"
	_vram="${VBOX_VM_VRAM_MB:-32}"

	# Intermediate VM artifacts (base/overlay disks, working VM registration)
	# go in the shared scratch dir, NOT the build root — so they land under
	# the git-ignorable _build tree and never pollute the working copy.
	# Cleaned up on entry so repeated runs start fresh.
	_vbox_dir="${BUILD_ARTEFACTS_DIR}/vbox"
	_base_vdi="${_vbox_dir}/${_vm_name}-base.vdi"
	_overlay_raw="${_vbox_dir}/${_vm_name}-overlay.raw"
	_overlay_vdi="${_vbox_dir}/${_vm_name}-overlay.vdi"
	_ova_out="${OUTPUT_DIR}/${PREFIX:-${_vm_name}}.ova"

	# --- preflight: required tools -----------------------------------------
	_missing=""
	for _t in VBoxManage parted mkfs.ext4; do
		command -v "${_t}" >/dev/null 2>&1 || _missing="${_missing} ${_t}"
	done
	if [ -n "${_missing}" ]; then
		log_error "build_virtualbox_ova: missing required tool(s):${_missing}"
		log_error "Install VirtualBox (VBoxManage) and parted/e2fsprogs on the build host."
		return 1
	fi
	# Loop-mounting to write persistence.conf needs root.
	if [ "$(id -u)" -ne 0 ]; then
		log_warn "build_virtualbox_ova: not running as root; loop-mount for persistence.conf may fail."
	fi

	rm -rf "${_vbox_dir}"
	mkdir -p "${_vbox_dir}"

	# --- 1) base read-only disk from the ISO -------------------------------
	# The hybrid ISO is a valid raw disk image; convert straight to an
	# adaptive VDI. It is attached read-only to the VM, so the guest never
	# writes to it (all writes go to the overlay).
	log_info "VirtualBox: converting ISO -> adaptive base VDI"
	if ! VBoxManage convertfromraw "${_iso}" "${_base_vdi}" \
		--format VDI --variant Standard; then
		log_error "build_virtualbox_ova: convertfromraw (base) failed."
		return 1
	fi

	# --- 2) persistence overlay: raw -> partition -> label -> conf ---------
	log_info "VirtualBox: creating ${_overlay_gb}G adaptive persistence overlay"

	# Sparse raw file of the requested capacity (stays thin on disk).
	if ! truncate -s "${_overlay_gb}G" "${_overlay_raw}"; then
		log_error "build_virtualbox_ova: could not create overlay raw file."
		return 1
	fi

	# One GPT partition spanning the disk, GPT name "persistence".
	parted -s "${_overlay_raw}" mklabel gpt
	parted -s "${_overlay_raw}" mkpart persistence ext4 1MiB 100%

	# Format that partition ext4 with filesystem LABEL "persistence".
	# The partition starts at the 1MiB offset; size = capacity minus that MiB.
	_off_b=$((1024 * 1024))
	_fs_blocks=$(( (_overlay_gb * 1024 - 1) * 1024 ))   # 1K blocks
	if ! mkfs.ext4 -q -F -L persistence -E offset=${_off_b} \
		"${_overlay_raw}" "${_fs_blocks}"; then
		log_error "build_virtualbox_ova: mkfs.ext4 on overlay failed."
		return 1
	fi

	# Write persistence.conf into the partition root (loop-mount by offset).
	# live-boot ignores a "persistence"-labelled volume that lacks this file.
	_mnt="${_vbox_dir}/mnt"
	mkdir -p "${_mnt}"
	if mount -o loop,offset=${_off_b} "${_overlay_raw}" "${_mnt}" 2>/dev/null; then
		# shellcheck disable=SC2059
		printf "${_overlay_conf}\n" > "${_mnt}/persistence.conf"
		log_info "VirtualBox: wrote persistence.conf ($(head -1 "${_mnt}/persistence.conf"))"
		sync
		umount "${_mnt}"
	else
		log_error "build_virtualbox_ova: could not loop-mount overlay to write persistence.conf."
		log_error "Run as root, or ensure loop devices are available."
		return 1
	fi
	rmdir "${_mnt}" 2>/dev/null || true

	# Convert the finished raw overlay to an adaptive VDI, then drop the raw.
	log_info "VirtualBox: converting overlay raw -> adaptive VDI"
	if ! VBoxManage convertfromraw "${_overlay_raw}" "${_overlay_vdi}" \
		--format VDI --variant Standard; then
		log_error "build_virtualbox_ova: convertfromraw (overlay) failed."
		return 1
	fi
	rm -f "${_overlay_raw}"

	# --- 3) assemble the VM ------------------------------------------------
	# Remove any stale VM of the same name so re-runs are idempotent.
	VBoxManage unregistervm "${_vm_name}" --delete >/dev/null 2>&1 || true

	log_info "VirtualBox: creating VM '${_vm_name}'"
	VBoxManage createvm --name "${_vm_name}" --ostype Debian_64 \
		--basefolder "${_vbox_dir}" --register

	VBoxManage modifyvm "${_vm_name}" \
		--memory "${_ram}" --vram "${_vram}" \
		--firmware efi \
		--boot1 disk --boot2 none --boot3 none --boot4 none \
		--nic1 nat --audio none --usb on

	# SATA controller carries both disks: base read-only, overlay read-write.
	VBoxManage storagectl "${_vm_name}" --name "SATA" --add sata --controller IntelAhci --portcount 2

	VBoxManage storageattach "${_vm_name}" --storagectl "SATA" \
		--port 0 --device 0 --type hdd --medium "${_base_vdi}" \
		--mtype readonly

	VBoxManage storageattach "${_vm_name}" --storagectl "SATA" \
		--port 1 --device 0 --type hdd --medium "${_overlay_vdi}" \
		--mtype normal

	# --- 4) export the appliance -------------------------------------------
	rm -f "${_ova_out}"
	log_info "VirtualBox: exporting OVA -> ${_ova_out}"
	if ! VBoxManage export "${_vm_name}" --output "${_ova_out}" \
		--vsys 0 \
		--product "${THEME_TITLE:-${_vm_name}}" \
		--vendor "BFH MSE"; then
		log_error "build_virtualbox_ova: OVA export failed."
		return 1
	fi

	# Checksum next to the OVA, consistent with the ISO artifacts.
	( cd "${OUTPUT_DIR}" && md5sum "$(basename "${_ova_out}")" > "$(basename "${_ova_out}").md5" )

	# Unregister (keep the exported OVA; drop the working VM registration).
	VBoxManage unregistervm "${_vm_name}" --delete >/dev/null 2>&1 || true

	log_info "VirtualBox: done -> ${_ova_out}"
}
