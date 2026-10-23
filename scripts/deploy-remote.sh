#!/usr/bin/env bash
# ==============================================================================
# deploy-remote.sh
# Stream the Fedora Cinnamon UEFI image to a whole disk on the Firefly over SSH
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$(dirname "${SCRIPT_DIR}")/output"

SSH_TARGET="${1:-}"
TARGET_DEV="${2:-}"
if [[ -z "${SSH_TARGET}" || -z "${TARGET_DEV}" ]]; then
  echo "Usage: $0 SSH_TARGET /dev/DISK   (for example: $0 pve /dev/sda)" >&2
  exit 1
fi
[[ $TARGET_DEV =~ ^/dev/(sd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$ ]] || {
  echo "Error: Specify a whole disk device, such as /dev/sda." >&2
  exit 1
}

ssh_target() {
  ssh -F "${SSH_CONFIG:-${HOME}/.ssh/config}" -o ConnectTimeout=10 "${SSH_TARGET}" "$@"
}

IMG_FILE=$(ls -1 "${OUTPUT_DIR}"/fedora-*-cinnamon-firefly-itx3588j-uefi-btrfs.img.zst \
                 "${OUTPUT_DIR}"/fedora-*-cinnamon-firefly-itx3588j-uefi-btrfs.img 2>/dev/null | head -n1 || true)
if [[ -z "${IMG_FILE}" ]]; then
  echo "Error: No image in ${OUTPUT_DIR}. Run sudo ./build-image.sh first." >&2
  exit 1
fi

echo "===================================================================="
echo " Fedora Cinnamon: Remote UEFI Image Deployer"
echo " Host:         ${SSH_TARGET}"
echo " Target Drive: ${TARGET_DEV}"
echo " Source Image: ${IMG_FILE}"
echo "===================================================================="

ssh_target "hostname && uname -r"

# Never overwrite a disk that carries the EDK2 firmware (eMMC on this board).
ssh_target "sudo -n python3 - '${TARGET_DEV}'" < "${SCRIPT_DIR}/check-firmware-header.py"

# Refuse, rather than force-unmount, when the disk is in use.
ssh_target bash -s -- "${TARGET_DEV}" <<'CHECKSAFETY'
  set -euo pipefail
  dev="$1"
  [[ -b "${dev}" ]] || { echo "ERROR: ${dev} does not exist." >&2; exit 1; }
  root_src=$(findmnt -n -o SOURCE / | sed 's/\[.*\]$//')
  root_disk=$(lsblk -n -o PKNAME "${root_src}" 2>/dev/null | head -n1)
  if [[ "/dev/${root_disk}" == "${dev}" || "${root_src}" == "${dev}" ]]; then
    echo "ERROR: ${dev} holds the running root (${root_src}). Boot the board from" >&2
    echo "another disk (for example PVE on eMMC) before replacing it." >&2
    exit 1
  fi
  if lsblk -n -o MOUNTPOINTS "${dev}" | grep -q '[^[:space:]]'; then
    echo "ERROR: Partitions of ${dev} are mounted:" >&2
    lsblk -o NAME,FSTYPE,LABEL,MOUNTPOINTS "${dev}" >&2
    exit 1
  fi
  if grep -qs "^${dev}" /proc/swaps; then
    echo "ERROR: ${dev} is in use as swap." >&2; exit 1
  fi
  echo "Target disk:"
  lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN "${dev}"
  lsblk -o NAME,SIZE,FSTYPE,LABEL "${dev}"
CHECKSAFETY

echo ""
echo "===================================================================="
echo " WARNING: ALL DATA ON ${TARGET_DEV} ON ${SSH_TARGET} WILL BE ERASED."
echo "===================================================================="
read -rp "Type the device path (${TARGET_DEV}) to proceed: " CONFIRM
if [[ "${CONFIRM}" != "${TARGET_DEV}" ]]; then
  echo "Cancelled."
  exit 0
fi

echo "Streaming image to ${TARGET_DEV}..."
if [[ "${IMG_FILE}" == *.zst ]]; then
  zstd -dc "${IMG_FILE}" | ssh_target "sudo dd of=${TARGET_DEV} bs=4M status=progress conv=fsync"
elif ssh_target "command -v zstd >/dev/null"; then
  # Compress in transit so the raw image's unallocated space is not sent as zeros.
  zstd -T0 -3 -c "${IMG_FILE}" | ssh_target "zstd -dc | sudo dd of=${TARGET_DEV} bs=4M status=progress conv=fsync"
else
  ssh_target "sudo dd of=${TARGET_DEV} bs=4M status=progress conv=fsync" < "${IMG_FILE}"
fi

# Move the backup GPT to the disk end now; the root partition and Btrfs
# filesystem are grown by firefly-growroot.service on first boot.
ssh_target "sudo sfdisk --relocate gpt-bak-std ${TARGET_DEV} && sudo partprobe ${TARGET_DEV} || true; lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL ${TARGET_DEV}"

echo "===================================================================="
echo " Deployed to ${TARGET_DEV} on ${SSH_TARGET}."
echo " Reboot, press F12 and pick the disk; it boots EFI\\BOOT\\BOOTAA64.EFI."
echo "===================================================================="
