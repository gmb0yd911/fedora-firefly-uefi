# Bring-up notes and validation status

## Established before hardware boot

- Fedora 44 Minimal aarch64 (`Fedora-Minimal-44-1.7`) is MBR with ext4
  root and boots shim → `EFI/fedora/grubaa64.efi` → `/boot/grub2/grub.cfg`
  → BLS. Its filesystem mounts are systemd units pinned to its own UUIDs;
  the builder replaces them with `/etc/fstab`.
- Fedora kernels 6.19.10 (base image) and 7.2.11 (F44 updates, October
  2026) both ship `dtb/rockchip/rk3588-firefly-itx-3588j.dtb`. In the 7.2.11
  tree HDMI0 (`fde80000`), VOP, Mali GPU, both SATA controllers, PCIe 3.0
  (`fe150000`), both GMACs and eMMC are enabled; HDMI1 (`fdea0000`) and two
  PCIe 2.0 controllers are disabled. It differs from
  `../firefly-itx3588j-7.2-kernel/mainline.dtb` (different SHA256); the
  differences have not been analysed.
- `20-grub.install` honors `GRUB_DEVICETREE` per kernel version.

Image build success and these checks do not establish a hardware boot.

## Not yet validated on hardware

- Booting Fedora's mainline kernel through EDK2 v1.1 with a GRUB-supplied
  device tree.
- HDMI with HDMI connected during firmware start. The vendor 6.1 kernel
  needed seven VOP clock holds (`../firefly-itx3588j/docs/uefi-hdmi-investigation.md`);
  the mainline `dw-hdmi-qp` driver's handoff behaviour on this board is
  unknown. If the screen goes dark or the board resets during boot, boot with
  HDMI unplugged, connect it after the greeter starts, and check over SSH.
- Ethernet MAC addresses: the replacement tree has no firmware-assigned MACs,
  so NetworkManager derives a stable one per machine; the DHCP address will
  differ from Omarchy's.
- Shim fallback writing a boot entry: EFI variable writes from Linux do not
  persist with this eMMC-backed firmware, but fallback runs before
  ExitBootServices, where writes are saved on reset.

## Unlabeled files (fixed 2026-10-23)

The first image relied on `/.autorelabel`. The chroot's `rpm` could not label
files on the SELinux-less build host, so about 11,000 files (including
`systemd`) had no label. Enforcing boot failed with `Failed to allocate
manager object` before the relabel could run. The builder now labels offline
with `setfiles`, once for each Btrfs subvolume, and verifies the result.

A disk written from the unlabeled image can be recovered at the board: in
GRUB press `e`, append `enforcing=0` to the kernel options, and boot with
Ctrl-X. The pending autorelabel then runs and reboots into enforcing mode.

## Diagnostics after first boot

```bash
ssh <user>@<dhcp-address>
cat /proc/device-tree/model; uname -r; cat /proc/cmdline
findmnt -t btrfs; sudo btrfs subvolume list /
ls /sys/firmware/efi && sudo mokutil --sb-state
journalctl -b -k | grep -iE 'hdmi|vop|panthor|drm'
cat /sys/class/drm/*/status
systemctl status firefly-growroot lightdm
```

Serial console: UART2 at 1500000 baud (`console=ttyS2,1500000n8`).

## Recovery

- F12 → eMMC boots PVE, which is untouched.
- In GRUB, `e` on an entry allows removing `devicetree` (use firmware DT),
  removing `console=tty0`, or adding `systemd.unit=multi-user.target`
  to skip the desktop.
- The SATA disk can be re-imaged from PVE with `scripts/deploy-remote.sh`.
