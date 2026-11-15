# Fedora Cinnamon for Firefly ITX-3588J (EDK2 UEFI)

Builds a Fedora Cinnamon disk image for the **Firefly ITX-3588J** (Rockchip
RK3588) that boots through the board's existing **EDK2 UEFI** firmware with
Fedora's own boot chain (shim → GRUB → BLS entries) and Fedora's stock
mainline kernel and in-tree device tree.

Fedora publishes no aarch64 Cinnamon disk image. The builder starts from the
official Fedora Minimal aarch64 image (checksum-verified), moves it onto a
new GPT layout with a Btrfs root, and installs the
`cinnamon-desktop-environment` group in a QEMU aarch64 chroot.

## Image layout

| Partition | Size | Filesystem | Mount |
| --- | --- | --- | --- |
| p1 `EFI-SYSTEM` | 512 MiB | FAT32 ESP | `/boot/efi` (shim, GRUB, `EFI/BOOT/BOOTAA64.EFI`) |
| p2 `fedora-boot` | 1 GiB | ext4 | `/boot` (kernels, initramfs, `dtb-<kver>/`, BLS entries) |
| p3 `fedora-root` | rest | Btrfs, `compress=zstd:1,noatime` | subvolumes below |

| Subvolume | Mountpoint |
| --- | --- |
| `@` | `/` |
| `@home` | `/home` |
| `@snapshots` | `/.snapshots` |
| `@var_log` | `/var/log` |
| `@var_cache` | `/var/cache` (dnf cache) |

The image is 16 GiB (`IMG_SIZE_MIB`); `firefly-growroot.service` grows p3
and the Btrfs filesystem to fill the disk on first boot.

## Device tree

`/etc/default/grub` sets
`GRUB_DEVICETREE="rockchip/rk3588-firefly-itx-3588j-ap6275p.dtb"`. Fedora's
`20-grub.install` then adds `devicetree /dtb-<kver>/rockchip/…` to every new
BLS entry. `25-firefly-ap6275p.install` then writes that file as the kernel's
own board DTB plus the Wi-Fi/Bluetooth nodes (see below). Each kernel
therefore boots with its own matching DTB across `dnf` updates. GRUB installs it in place of the firmware's tree. To try the EDK2
firmware tree instead, press `e` in the GRUB menu and delete the
`devicetree` line.

Kernel arguments (`/etc/kernel/cmdline` and `GRUB_CMDLINE_LINUX`):
`root=UUID=… ro rootflags=subvol=@ console=ttyS2,1500000n8 console=tty0
drm.edid_firmware=HDMI-A-1:edid/dell_p2720dc-240mhz.bin video=HDMI-A-1:2560x1440`.

## HDMI

The mainline driver takes over HDMI0 from EDK2 without the vendor kernel's
clock holds. Its DDC (EDID) read fails on this board (`i2c read error`,
then a 1024x768 fallback), so the image supplies the monitor's EDID from
`config/edid/` in `/usr/lib/firmware/edid/` and the initramfs.

The default `dell_p2720dc-240mhz.bin` is the Dell P2720DC EDID
(`dell_p2720dc.bin`) with its 2560x1440 timing changed from 241.50 to
240.00 MHz (59.58 Hz) and the checksum corrected. The 7.2 HDPTX PHY driver
has no table entry for 241.5 MHz; its computed fractional PLL setting
produced flickering red pixels. 240 MHz uses an integer divider
(24 MHz × 100). 1920x1080 at 148.5 MHz (a table rate) was also clean.

For another monitor, set `EDID_FILE` and `HDMI_MODE`, preferring a pixel
clock in the driver's table or a multiple of 2.4 MHz; `EDID_FILE=`
disables the override.

## Wi-Fi and Bluetooth (AP6275P)

The board's AP6275P module is a BCM43752: Wi-Fi on `pcie2x1l0`, Bluetooth on
UART6. Fedora's DTB describes neither. It also enables `sata1`, which shares
combo PHY 1 with the Wi-Fi PCIe slot. The built-in AHCI driver takes the PHY
first, so the Wi-Fi link never trains.

`config/ap6275p/firefly-dt-ap6275p` adds the vendor DT's wiring by node
path, because Fedora's DTBs have no `__symbols__`. It:

- disables `sata1`;
- adds the WL_REG_ON regulator (GPIO0_C4) as the slot's supply;
- enables UART6 with RTS/CTS;
- adds a serdev Bluetooth node with BT_REG_ON/BT_WAKE and the hym8563
  32 kHz LPO.

The same script is used by
[pve-firefly-uefi](https://github.com/gmb0yd911/pve-firefly-uefi).

The Wi-Fi firmware only starts once that LPO runs, and the Bluetooth driver
enables it. So `brcmfmac` is blacklisted for automatic loading, and
`brcmfmac-after-bt.service` loads it when `hci0` appears. The builder also
installs `dtc` (for the kernel-install plugin) and enables
`bluetooth.service`.

Fedora's `linux-firmware` has no files for this module. The builder
downloads them from
[armbian/firmware](https://github.com/armbian/firmware) at commit
`9934dbd5`, checks them against `config/ap6275p/firmware.sha256` and
installs them in `/usr/lib/firmware/brcm/`:

- `brcmfmac43752-pcie.{bin,clm_blob,txt}` for Wi-Fi;
- `BCM4362A2.hcd` for Bluetooth.

They are not stored in this repository.

## Build

Host prerequisites (Arch): `qemu-user-static qemu-user-static-binfmt
arch-install-scripts btrfs-progs dosfstools e2fsprogs rsync zstd xz openssl`.

```bash
sudo ./build-image.sh
```

The builder prompts for the Fedora user's password. Settings:

| Variable | Default |
| --- | --- |
| `FEDORA_USER` | invoking user (`$SUDO_USER`) |
| `FEDORA_PASSWORD_HASH` | prompt; empty = SSH-key-only account with NOPASSWD sudo |
| `SSH_PUBKEY_FILE` | invoking user's `~/.ssh/id_ed25519.pub` |
| `FEDORA_HOSTNAME` | `firefly-fedora` |
| `UPDATE_SYSTEM` | `1` (`dnf upgrade` during build) |
| `EXTRA_KERNEL_ARGS` | `console=ttyS2,1500000n8 console=tty0` |
| `EDID_FILE` | `config/edid/dell_p2720dc-240mhz.bin`; empty disables the override |
| `HDMI_CONNECTOR` / `HDMI_MODE` | `HDMI-A-1` / `2560x1440` |
| `IMG_SIZE_MIB` | `16384` |

Output: `output/fedora-44-cinnamon-firefly-itx3588j-uefi-btrfs.img` (sparse,
about 6 GiB allocated) and `.img.zst` when there is room to compress it. The
deployer compresses a raw image in transit when the board has `zstd`. The
build needs 14 GiB free.

SELinux labels are applied offline with the image's own policy, and the
build fails if any file is left unlabeled: the build host has no SELinux, so
`rpm` cannot label what it installs. Inside the chroot, os-prober is disabled: it would otherwise add the build
host's disks to `grub.cfg`.

## Deploy

The target here is the SATA SSD, replacing Omarchy. **eMMC holds the EDK2
firmware and PVE; never write this image there** (the deployer refuses any
disk containing EDK2). The board cannot overwrite the disk it is running
from, so boot PVE from eMMC first (F12 → eMMC), or write the SSD from
another machine. Back up anything needed from Omarchy first.

```bash
./scripts/deploy-remote.sh pve /dev/sda
```

It refuses a disk that holds the running root, has mounted partitions, or
contains EDK2, and requires typing the device path to confirm.

## First boot

1. Connect the monitor to the **bottom HDMI port (HDMI0)**. The top port
   is HDMI1, which Fedora's DTB leaves disabled: EDK2 and GRUB still show
   on it, but Linux then gives a black screen.
2. In UEFI setup keep **Config Table Mode = Device Tree** and
   **Display → Force Output = Disabled** (as already saved for PVE).
   Reflashing the EDK2 image resets these to defaults.
3. F12 → the SATA disk. Shim's fallback loader creates a `Fedora` boot
   entry and resets once; after that, Fedora may be first in boot order.
   Use F12 to choose PVE on eMMC.
4. LightDM (slick-greeter) starts Cinnamon. SSH is enabled with the
   build user's key.

See [docs/bring-up.md](docs/bring-up.md) for what is and isn't validated
and how to recover.
