#!/bin/bash
# tmpfs_destroy.sh – Unmount ext4 image and destroy the tmpfs
# Usage: sudo bash tmpfs_destroy.sh
# Author: Andreas HABEGGER <andreas.habegger@bfh.ch> 
set -e

TMPFS="/mytmpfs"
IMAGE="${TMPFS}/lernstick.img"
MOUNT="${TMPFS}/lernstick"

# Kill any processes still accessing the image mount
if findmnt "${MOUNT}" > /dev/null 2>&1; then
    echo "==> Killing processes still accessing ${MOUNT}"
    fuser -v -k -m "${MOUNT}" 2>/dev/null || true
    sleep 2

    echo "==> Unmounting ${MOUNT}"
    umount "${MOUNT}"
else
    echo "==> ${MOUNT} is not mounted, skipping"
fi

# Remove the ext4 image file
if [ -f "${IMAGE}" ]; then
    echo "==> Removing image file ${IMAGE}"
    rm -f "${IMAGE}"
else
    echo "==> ${IMAGE} not found, skipping"
fi

# Unmount the tmpfs itself
if findmnt "${TMPFS}" > /dev/null 2>&1; then
    echo "==> Unmounting tmpfs at ${TMPFS}"
    umount "${TMPFS}"
else
    echo "==> ${TMPFS} is not mounted, skipping"
fi

# Remove mountpoints
echo "==> Removing mountpoints"
rmdir "${MOUNT}" 2>/dev/null || true
rmdir "${TMPFS}"  2>/dev/null || true

echo ""
echo "Done. RAM released:"
free -h
