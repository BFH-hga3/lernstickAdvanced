check_and_source_constants()
{
	if [ -e constants ]
	then
		. ./constants
	else
		echo "Please copy the file \"constants.example\" to \"constants\" and adopt the settings to your build environment."
		exit
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

build_image()
{
	# update time stamp in bootloaders
	# ISOLINUX/SYSLINUX
	BOOTLOGO="config/bootloaders/isolinux/bootlogo"
	BOOTLOGO_DIR="${BOOTLOGO}.dir"
	cp templates/xmlboot.config ${BOOTLOGO_DIR}
	sed -i "s|<version its:translate=\"no\">.*</version>|<version its:translate=\"no\">(Version ${TODAY})</version>|1" \
		${BOOTLOGO_DIR}/xmlboot.config
	gfxboot --archive ${BOOTLOGO_DIR} --pack-archive ${BOOTLOGO}
	cp ${BOOTLOGO} ${BOOTLOGO}.orig
	# GRUB
	GRUB_THEME_DIR="config/includes.binary/boot/grub/themes/lernstick"
	cp templates/theme.txt ${GRUB_THEME_DIR}
	sed -i "s|title-text.*|title-text: \"Lernstick-Prüfungsumgebung Debian 13 (Version ${TODAY})\"|1" \
		${GRUB_THEME_DIR}/theme.txt

	# Generate password hashes on the host BEFORE entering the chroot.
	# chroot hooks cannot access host environment variables, so we
	# pre-generate yescrypt hashes here and place them in
	# includes.chroot_before_packages where the chroot hook can read them.
	# Requires: whois (mkpasswd) installed on the BUILD HOST.
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
		--iso-volume "lernstick${ISO_SUFFIX} ${TODAY}" \
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
		PREFIX="lernstick_debian13${ISO_SUFFIX}_${TODAY}"
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
