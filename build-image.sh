#!/usr/bin/env bash
# ==============================================================================
# build-image.sh
# Build a Fedora Cinnamon UEFI GPT image with a Btrfs root for the
# Firefly ITX-3588J (EDK2 UEFI firmware, Fedora stock kernel + in-tree DTB)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/cache"
CONFIG_DIR="${SCRIPT_DIR}/config"
OUTPUT_DIR="${SCRIPT_DIR}/output"

FEDORA_RELEASE="${FEDORA_RELEASE:-44}"
FEDORA_COMPOSE="${FEDORA_COMPOSE:-1.7}"
BASE_NAME="Fedora-Minimal-${FEDORA_RELEASE}-${FEDORA_COMPOSE}.aarch64.raw.xz"
CHECKSUM_NAME="Fedora-Spins-${FEDORA_RELEASE}-${FEDORA_COMPOSE}-aarch64-CHECKSUM"
BASE_URL="https://dl.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_RELEASE}/Spins/aarch64/images"

IMG_FILE="${OUTPUT_DIR}/fedora-${FEDORA_RELEASE}-cinnamon-firefly-itx3588j-uefi-btrfs.img"
IMG_SIZE_MIB="${IMG_SIZE_MIB:-16384}"
ESP_SIZE_MIB=512
BOOT_SIZE_MIB=1024

DTB_PATH="rockchip/rk3588-firefly-itx-3588j.dtb"
EXTRA_KERNEL_ARGS="${EXTRA_KERNEL_ARGS:-console=ttyS2,1500000n8 console=tty0}"
# HDMI0's DDC read fails on this board, so supply the monitor's EDID.
# EDID_FILE= (empty) disables the override.
EDID_FILE="${EDID_FILE-${CONFIG_DIR}/edid/dell_p2720dc.bin}"
HDMI_CONNECTOR="${HDMI_CONNECTOR:-HDMI-A-1}"
HDMI_MODE="${HDMI_MODE:-2560x1440@60}"
if [[ -n "${EDID_FILE}" ]]; then
  [[ -f "${EDID_FILE}" ]] || { echo "Error: EDID file ${EDID_FILE} not found." >&2; exit 1; }
  EDID_NAME=$(basename "${EDID_FILE}")
  EXTRA_KERNEL_ARGS+=" drm.edid_firmware=${HDMI_CONNECTOR}:edid/${EDID_NAME} video=${HDMI_CONNECTOR}:${HDMI_MODE}"
fi
FEDORA_HOSTNAME="${FEDORA_HOSTNAME:-firefly-fedora}"
FEDORA_USER="${FEDORA_USER:-${SUDO_USER:-fedora}}"
UPDATE_SYSTEM="${UPDATE_SYSTEM:-1}"
COMPRESS_IMAGE="${COMPRESS_IMAGE:-1}"

# Btrfs subvolume -> mountpoint, matching the Arch Firefly image convention.
SUBVOLS=("@:/" "@home:/home" "@snapshots:/.snapshots" "@var_log:/var/log" "@var_cache:/var/cache")
BTRFS_OPTS="compress=zstd:1,noatime"

WORK="/mnt/fedora_firefly_build_$$"
SRC="${WORK}/src"
DST="${WORK}/dst"
SRC_LOOP=""
DST_LOOP=""
BASE_RAW=""

if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root (or with sudo)." >&2
  exit 1
fi

echo "===================================================================="
echo " Fedora ${FEDORA_RELEASE} Cinnamon - Firefly ITX-3588J EDK2 UEFI Image Builder"
echo " Base:     ${BASE_NAME}"
echo " Image:    ${IMG_FILE}"
echo " Size:     ${IMG_SIZE_MIB} MiB (root grows to fill the disk on first boot)"
echo " Layout:   GPT: ESP ${ESP_SIZE_MIB} MiB FAT32, /boot ${BOOT_SIZE_MIB} MiB ext4, Btrfs root"
echo " Boot:     shim + GRUB (BLS), devicetree ${DTB_PATH}"
echo "===================================================================="

cleanup() {
  set +e
  sync
  for d in "${DST}" "${SRC}"; do
    if mountpoint -q "${d}" 2>/dev/null; then umount -R "${d}"; fi
  done
  [[ -n "${DST_LOOP}" ]] && losetup -d "${DST_LOOP}" 2>/dev/null
  [[ -n "${SRC_LOOP}" ]] && losetup -d "${SRC_LOOP}" 2>/dev/null
  [[ -n "${BASE_RAW}" ]] && rm -f "${BASE_RAW}"
  rm -rf "${WORK}"
}
trap cleanup EXIT

for cmd in xz sfdisk losetup partx mkfs.vfat mkfs.ext4 mkfs.btrfs btrfs rsync arch-chroot openssl blkid sha256sum setfattr getfattr; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: Required command '$cmd' is not installed." >&2
    exit 1
  fi
done
if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
  echo "Error: qemu-aarch64 binfmt is not registered (install qemu-user-static-binfmt)." >&2
  exit 1
fi

# The decompressed base (~5.3 GiB) and the populated image (~7 GiB) coexist.
mkdir -p "${OUTPUT_DIR}" /mnt
for dir in "${OUTPUT_DIR}" /mnt; do
  if (( $(df -Pk "${dir}" | awk 'NR==2 {print $4}') < 14 * 1024 * 1024 )); then
    echo "Error: Less than 14 GiB free on the filesystem holding ${dir}." >&2
    exit 1
  fi
done

# --- Account credentials ------------------------------------------------------
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-}"
if [[ -z "${SSH_PUBKEY_FILE}" && -n "${SUDO_USER:-}" ]]; then
  SUDO_HOME=$(getent passwd "${SUDO_USER}" | cut -d: -f6)
  for k in "${SUDO_HOME}/.ssh/id_ed25519.pub" "${SUDO_HOME}/.ssh/id_rsa.pub"; do
    [[ -f "$k" ]] && { SSH_PUBKEY_FILE="$k"; break; }
  done
fi

PASSWORD_HASH="${FEDORA_PASSWORD_HASH:-}"
if [[ -z "${PASSWORD_HASH}" && -t 0 ]]; then
  read -rsp "Password for Fedora user '${FEDORA_USER}' (empty = SSH key only): " PW1; echo
  if [[ -n "${PW1}" ]]; then
    read -rsp "Repeat password: " PW2; echo
    [[ "${PW1}" == "${PW2}" ]] || { echo "Error: Passwords do not match." >&2; exit 1; }
    PASSWORD_HASH=$(openssl passwd -6 -stdin <<<"${PW1}")
  fi
  unset PW1 PW2
fi
if [[ -z "${PASSWORD_HASH}" && -z "${SSH_PUBKEY_FILE}" ]]; then
  echo "Error: No password and no SSH public key; the image would have no usable login." >&2
  exit 1
fi

# --- 1. Base image --------------------------------------------------------------
mkdir -p "${CACHE_DIR}" "${OUTPUT_DIR}" "${SRC}" "${DST}"
cd "${CACHE_DIR}"
[[ -f "${CHECKSUM_NAME}" ]] || curl -fsSLO "${BASE_URL}/${CHECKSUM_NAME}"
[[ -f "${BASE_NAME}" ]] || curl -fSLO "${BASE_URL}/${BASE_NAME}"
echo "[1/8] Verifying ${BASE_NAME}..."
grep -F "(${BASE_NAME})" "${CHECKSUM_NAME}" | sha256sum -c -
cd "${SCRIPT_DIR}"

BASE_RAW="${WORK}/base.raw"
echo "[2/8] Decompressing base image..."
xz -dcT0 "${CACHE_DIR}/${BASE_NAME}" > "${BASE_RAW}"
SRC_LOOP=$(losetup -rPf --show "${BASE_RAW}")
partx -u "${SRC_LOOP}" 2>/dev/null || true

# Base layout: p1 FAT ESP, p2 ext4 /boot, p3 ext4 root.
mount -o ro "${SRC_LOOP}p3" "${SRC}"
mount -o ro,noload "${SRC_LOOP}p2" "${SRC}/boot"
mount -o ro "${SRC_LOOP}p1" "${SRC}/boot/efi"

# --- 2. New GPT image -----------------------------------------------------------
echo "[3/8] Creating GPT image..."
rm -f "${IMG_FILE}" "${IMG_FILE}.zst"
truncate -s "${IMG_SIZE_MIB}M" "${IMG_FILE}"
sfdisk --quiet "${IMG_FILE}" <<EOF
label: gpt
start=1MiB, size=${ESP_SIZE_MIB}MiB, type=U, name="EFI-SYSTEM"
size=${BOOT_SIZE_MIB}MiB, type=L, name="fedora-boot"
type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE, name="fedora-root"
EOF
DST_LOOP=$(losetup -Pf --show "${IMG_FILE}")
partx -u "${DST_LOOP}" 2>/dev/null || true

mkfs.vfat -F 32 -n ESP "${DST_LOOP}p1" >/dev/null
mkfs.ext4 -q -L boot "${DST_LOOP}p2"
mkfs.btrfs -q -f -L fedora "${DST_LOOP}p3"
ESP_UUID=$(blkid -s UUID -o value "${DST_LOOP}p1")
BOOT_UUID=$(blkid -s UUID -o value "${DST_LOOP}p2")
ROOT_UUID=$(blkid -s UUID -o value "${DST_LOOP}p3")

mount "${DST_LOOP}p3" "${DST}"
for entry in "${SUBVOLS[@]}"; do btrfs -q subvolume create "${DST}/${entry%%:*}"; done
umount "${DST}"

mount -o "subvol=@,${BTRFS_OPTS}" "${DST_LOOP}p3" "${DST}"
for entry in "${SUBVOLS[@]:1}"; do
  mkdir -p "${DST}${entry#*:}"
  mount -o "subvol=${entry%%:*},${BTRFS_OPTS}" "${DST_LOOP}p3" "${DST}${entry#*:}"
done
mkdir -p "${DST}/boot"
mount "${DST_LOOP}p2" "${DST}/boot"
mkdir -p "${DST}/boot/efi"
mount "${DST_LOOP}p1" "${DST}/boot/efi"

# --- 3. Copy Fedora ---------------------------------------------------------------
echo "[4/8] Copying Fedora root, /boot and ESP..."
rsync -aHAX --numeric-ids "${SRC}/" "${DST}/" --exclude=/boot/ --exclude=/lost+found
rsync -aHAX --numeric-ids "${SRC}/boot/" "${DST}/boot/" --exclude=/efi/ --exclude=/lost+found
# The base ESP also carries Raspberry Pi firmware; only the EFI tree is needed.
rsync -rt "${SRC}/boot/efi/EFI" "${DST}/boot/efi/"
umount -R "${SRC}"
losetup -d "${SRC_LOOP}"; SRC_LOOP=""
rm -f "${BASE_RAW}"; BASE_RAW=""

# --- 4. Mounts and kernel command line --------------------------------------------
echo "[5/8] Writing fstab, kernel command line and devicetree configuration..."
# The base image pins its own filesystem UUIDs in mount units; fstab replaces them.
for unit in -.mount boot.mount boot-efi.mount; do
  rm -f "${DST}/etc/systemd/system/${unit}" "${DST}/etc/systemd/system/multi-user.target.wants/${unit}"
done
{
  echo "# Generated by fedora-firefly-uefi build-image.sh"
  for entry in "${SUBVOLS[@]}"; do
    echo "UUID=${ROOT_UUID} ${entry#*:} btrfs subvol=${entry%%:*},${BTRFS_OPTS} 0 0"
  done
  echo "UUID=${BOOT_UUID} /boot ext4 defaults 1 2"
  echo "UUID=${ESP_UUID} /boot/efi vfat umask=0077,shortname=winnt 0 2"
} > "${DST}/etc/fstab"

# grub2-mkconfig adds root= and rootflags=subvol=@ itself; GRUB_CMDLINE_LINUX
# carries only the extra arguments. os-prober would list the build host's disks.
sed -i '/^GRUB_CMDLINE_LINUX=/d;/^GRUB_DEVICETREE=/d;/^GRUB_DISABLE_OS_PROBER=/d' "${DST}/etc/default/grub"
cat >> "${DST}/etc/default/grub" <<EOF
GRUB_CMDLINE_LINUX="${EXTRA_KERNEL_ARGS}"
GRUB_DEVICETREE="${DTB_PATH}"
GRUB_DISABLE_OS_PROBER=true
EOF
# Written after /etc/default/grub: 20-grub.install regenerates it when older.
CMDLINE="root=UUID=${ROOT_UUID} ro rootflags=subvol=@ ${EXTRA_KERNEL_ARGS}"
echo "${CMDLINE}" > "${DST}/etc/kernel/cmdline"

# Update the base kernel's existing BLS entry to match.
for e in "${DST}"/boot/loader/entries/*.conf; do
  kver=$(sed -n 's/^version //p' "$e")
  sed -i "s|^options .*|options ${CMDLINE}|" "$e"
  sed -i '/^devicetree /d' "$e"
  echo "devicetree /dtb-${kver}/${DTB_PATH}" >> "$e"
done

# Board configuration.
install -Dm644 "${CONFIG_DIR}/dracut-build-generic.conf" "${DST}/etc/dracut.conf.d/90-firefly-build-generic.conf"
install -Dm644 "${CONFIG_DIR}/NetworkManager-stable-mac.conf" "${DST}/etc/NetworkManager/conf.d/90-firefly-stable-mac.conf"
install -Dm755 "${CONFIG_DIR}/firefly-growroot.sh" "${DST}/usr/local/sbin/firefly-growroot"
install -Dm644 "${CONFIG_DIR}/firefly-growroot.service" "${DST}/etc/systemd/system/firefly-growroot.service"
if [[ -n "${EDID_FILE}" ]]; then
  install -Dm644 "${EDID_FILE}" "${DST}/usr/lib/firmware/edid/${EDID_NAME}"
  sed "s|@EDID_NAME@|${EDID_NAME}|" "${CONFIG_DIR}/dracut-edid.conf.in" > "${DST}/etc/dracut.conf.d/90-firefly-edid.conf"
fi
echo "${FEDORA_HOSTNAME}" > "${DST}/etc/hostname"

# --- 5. Packages and accounts inside the aarch64 chroot ---------------------------
echo "[6/8] Installing Cinnamon and updating Fedora in QEMU chroot (slow)..."
RESOLV_BACKUP=""
if [[ -L "${DST}/etc/resolv.conf" || -e "${DST}/etc/resolv.conf" ]]; then
  RESOLV_BACKUP=$(readlink "${DST}/etc/resolv.conf" || true)
  rm -f "${DST}/etc/resolv.conf"
fi
printf 'nameserver 9.9.9.9\nnameserver 1.1.1.1\n' > "${DST}/etc/resolv.conf"

PUBKEY=""
[[ -n "${SSH_PUBKEY_FILE}" ]] && PUBKEY=$(<"${SSH_PUBKEY_FILE}")

arch-chroot "${DST}" /usr/bin/env \
  UPDATE_SYSTEM="${UPDATE_SYSTEM}" FEDORA_USER="${FEDORA_USER}" \
  PASSWORD_HASH="${PASSWORD_HASH}" PUBKEY="${PUBKEY}" \
  /bin/bash -euo pipefail <<'CHROOT'
dnf() { command dnf -y --setopt=install_weak_deps=True "$@"; }

if [[ "${UPDATE_SYSTEM}" == 1 ]]; then
  dnf upgrade --refresh
fi
# Fedora publishes no aarch64 Cinnamon disk image; install its environment group.
if dnf environment info cinnamon-desktop-environment &>/dev/null; then
  dnf group install cinnamon-desktop-environment
else
  dnf group install cinnamon-desktop
fi
dnf install cloud-utils-growpart btrfs-progs

systemctl set-default graphical.target
systemctl enable lightdm.service sshd.service firefly-growroot.service
systemctl disable initial-setup.service 2>/dev/null || true

if ! id "${FEDORA_USER}" &>/dev/null; then
  useradd -m -G wheel -c "${FEDORA_USER}" "${FEDORA_USER}"
fi
if [[ -n "${PASSWORD_HASH}" ]]; then
  usermod -p "${PASSWORD_HASH}" "${FEDORA_USER}"
else
  # SSH-key-only account: allow sudo without the (locked) password.
  echo "${FEDORA_USER} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/90-${FEDORA_USER}"
  chmod 0440 "/etc/sudoers.d/90-${FEDORA_USER}"
fi
if [[ -n "${PUBKEY}" ]]; then
  install -d -m700 -o "${FEDORA_USER}" -g "${FEDORA_USER}" "/home/${FEDORA_USER}/.ssh"
  echo "${PUBKEY}" > "/home/${FEDORA_USER}/.ssh/authorized_keys"
  chown "${FEDORA_USER}:" "/home/${FEDORA_USER}/.ssh/authorized_keys"
  chmod 600 "/home/${FEDORA_USER}/.ssh/authorized_keys"
fi

# Rebuild every initramfs generically: hostonly detection inside the chroot
# sees the build host's mounts, and the base initramfs targets an ext4 root.
for kver in $(ls /lib/modules); do
  [[ -f "/boot/vmlinuz-${kver}" ]] && dracut -f --no-hostonly "/boot/initramfs-${kver}.img" "${kver}"
done
dnf clean all
CHROOT

rm -f "${DST}/etc/resolv.conf"
if [[ -n "${RESOLV_BACKUP}" ]]; then ln -s "${RESOLV_BACKUP}" "${DST}/etc/resolv.conf"; fi
# Later kernels installed on the board may use normal host-only initramfs images.
rm -f "${DST}/etc/dracut.conf.d/90-firefly-build-generic.conf"

# The build host runs without SELinux, so rpm leaves every file it installs
# unlabeled; an enforcing boot then fails before a first-boot relabel can run.
# Label offline with the image's own policy. setfiles does not cross into
# other Btrfs subvolumes, so each mountpoint is listed.
echo "Applying SELinux labels..."
LABEL_PATHS=(/boot)
for entry in "${SUBVOLS[@]}"; do LABEL_PATHS+=("${entry#*:}"); done
arch-chroot "${DST}" setfiles -F -e /proc -e /sys -e /dev -e /run -e /tmp -e /boot/efi \
  /etc/selinux/targeted/contexts/files/file_contexts "${LABEL_PATHS[@]}" || true
# arch-chroot bind-mounts over /etc/resolv.conf, so label the symlink itself here.
setfattr -h -n security.selinux -v system_u:object_r:net_conf_t:s0 "${DST}/etc/resolv.conf"
unlabeled=$(for p in "${LABEL_PATHS[@]}"; do find "${DST}${p}" -xdev -print0; done \
  | xargs -0 getfattr -h -n security.selinux --absolute-names 2>&1 \
  | grep 'No such attribute' | grep -v '/var/lib/nfs/rpc_pipefs' || true)
if [[ -n "${unlabeled}" ]]; then
  echo "Error: Files without SELinux labels:" >&2
  head -20 <<<"${unlabeled}" >&2
  exit 1
fi

# --- 6. Verify boot configuration -------------------------------------------------
echo "[7/8] Verifying boot entries..."
status=0
shopt -s nullglob
entries=("${DST}"/boot/loader/entries/*.conf)
[[ ${#entries[@]} -gt 0 ]] || { echo "Error: no BLS entries." >&2; status=1; }
for e in "${entries[@]}"; do
  kver=$(sed -n 's/^version //p' "$e")
  dtb=$(sed -n 's/^devicetree //p' "$e")
  opts=$(sed -n 's/^options //p' "$e")
  echo "  ${kver}: devicetree=${dtb:-<none>}"
  [[ -n "${dtb}" && -f "${DST}/boot${dtb}" ]] || { echo "    Error: device tree missing." >&2; status=1; }
  [[ -f "${DST}/boot/vmlinuz-${kver}" && -f "${DST}/boot/initramfs-${kver}.img" ]] || { echo "    Error: kernel/initramfs missing." >&2; status=1; }
  [[ "${opts}" == "${CMDLINE}" ]] || { echo "    Error: unexpected options: ${opts}" >&2; status=1; }
done
if grep -q 'osprober' "${DST}/boot/grub2/grub.cfg"; then
  echo "Error: grub.cfg contains os-prober entries." >&2; status=1
fi
[[ -f "${DST}/boot/efi/EFI/BOOT/BOOTAA64.EFI" ]] || { echo "Error: ESP fallback loader missing." >&2; status=1; }
chroot_lightdm=$(readlink "${DST}/etc/systemd/system/display-manager.service" || true)
echo "  display-manager -> ${chroot_lightdm:-<none>}"
[[ "${chroot_lightdm}" == *lightdm.service ]] || { echo "Error: LightDM not enabled." >&2; status=1; }
[[ ${status} -eq 0 ]] || exit 1

echo "[8/8] Unmounting..."
umount -R "${DST}"
losetup -d "${DST_LOOP}"; DST_LOOP=""

if [[ "${COMPRESS_IMAGE}" == 1 ]]; then
  # Compressed output is roughly 30% of the allocated image.
  need_kib=$(( $(du -k "${IMG_FILE}" | cut -f1) * 4 / 10 ))
  if (( $(df -Pk "${OUTPUT_DIR}" | awk 'NR==2 {print $4}') < need_kib )); then
    echo "Warning: Not enough free space to compress; keeping only the raw image." >&2
    COMPRESS_IMAGE=0
  elif ! zstd -T0 -q -f "${IMG_FILE}" -o "${IMG_FILE}.zst"; then
    rm -f "${IMG_FILE}.zst"
    echo "Warning: Compression failed; keeping only the raw image." >&2
    COMPRESS_IMAGE=0
  fi
fi
[[ -n "${SUDO_USER:-}" ]] && chown "${SUDO_USER}:" "${IMG_FILE}"* 2>/dev/null || true

echo "===================================================================="
echo " Built: ${IMG_FILE}"
[[ "${COMPRESS_IMAGE}" == 1 ]] && echo "        ${IMG_FILE}.zst"
echo " Root UUID: ${ROOT_UUID}   Boot UUID: ${BOOT_UUID}   ESP UUID: ${ESP_UUID}"
echo " User: ${FEDORA_USER} ($([[ -n "${PASSWORD_HASH}" ]] && echo password || echo 'SSH key only, NOPASSWD sudo'))"
echo " SELinux labels applied offline; no first-boot relabel is needed."
echo "===================================================================="
