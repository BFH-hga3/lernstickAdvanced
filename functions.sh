check_and_source_constants()
{
	if [ -e constants ]
	then
		. ./constants
	else
		echo "Please copy the file \"constants.example\" to \"constants\" and adopt the settings to your build environment."
		exit 1
	fi
}

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
	if [ ${#MSE_USER_PASSWORD} -lt 4 ] || [ ${#MSE_ADMIN_PASSWORD} -lt 4 ]; then
		echo "ERROR: Passwords must be at least 4 characters."
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

		# move files from tmpfs to harddisk
		if [ -d "${BUILD_DIR}" ]
		then
			mv ${PREFIX}* "${BUILD_DIR}"
		fi
	else
		echo "Error: ISO file was not build" | tee -a logfile.txt
	fi

	cache_cleanup

	# When installing firmware-b43legacy-installer downloads.openwrt.org is
	# sometimes down. Building doesn't fail in this situation but we would
	# have produced an image without support for some legacy broadcom cards.
	# Therefore we must check via eyeballs what happened...
	grep downloads.openwrt.org logfile.txt

	echo "Start: ${START}" | tee -a logfile.txt
	echo "Stop : $(date)" | tee -a logfile.txt
	if [ -d "${BUILD_DIR}" ]
	then
		mv logfile.txt "${BUILD_DIR}"
	fi
}
