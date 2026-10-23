#!/usr/bin/bash
# Expand the root partition and its Btrfs filesystem to the end of the disk.
set -euo pipefail

ROOT_PART=$(findmnt -n -o SOURCE --target / | sed 's/\[.*\]$//')
DISK=/dev/$(lsblk -n -o PKNAME "${ROOT_PART}")
PARTNUM=$(cat "/sys/class/block/$(basename "${ROOT_PART}")/partition")

# Move the backup GPT header to the end of a disk larger than the image.
sfdisk --relocate gpt-bak-std "${DISK}" || true
growpart "${DISK}" "${PARTNUM}" || [[ $? -eq 1 ]]   # 1 = already full size
btrfs filesystem resize max /
touch /var/lib/firefly-growroot.done
