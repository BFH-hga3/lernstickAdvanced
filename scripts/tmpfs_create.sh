#!/bin/bash
# tmpfs_create.sh – Create a tmpfs and mount a 50G ext4 image inside it
# Usage: sudo bash tmpfs_create.sh
# Author: Andreas HABEGGER <andreas.habegger@bfh.ch> 
#
set -e

TMPFS="/mytmpfs"
TMPFS_SIZE="51G"
IMAGE="${TMPFS}/lernstick.img"
IMAGE_SIZE="50G"
MOUNT="${TMPFS}/lernstick"

echo "==> Creating tmpfs mountpoint at ${TMPFS}"
mkdir -p "${TMPFS}"

echo "==> Mounting tmpfs (${TMPFS_SIZE}) at ${TMPFS}"
mount -t tmpfs -o size=${TMPFS_SIZE} tmpfs "${TMPFS}"

echo "==> Creating image mountpoint at ${MOUNT}"
mkdir -p "${MOUNT}"

echo "==> Creating ${IMAGE_SIZE} sparse file at ${IMAGE}"
truncate -s ${IMAGE_SIZE} "${IMAGE}"

echo "==> Formatting ${IMAGE} as ext4"
mkfs.ext4 "${IMAGE}"

echo "==> Mounting ${IMAGE} at ${MOUNT}"
mount "${IMAGE}" "${MOUNT}"

echo ""
echo "Done. Verify:"
findmnt | grep mytmpfs
df -h "${TMPFS}" "${MOUNT}"
