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

## Open items before first boot (historical)

- Booting Fedora's mainline kernel through EDK2 v1.1 with a GRUB-supplied
  device tree.
- Ethernet MAC addresses: the replacement tree has no firmware-assigned MACs,
  so NetworkManager derives a stable one per machine; the DHCP address will
  differ from Omarchy's.
- Shim fallback writing a boot entry: EFI variable writes from Linux do not
  persist with this eMMC-backed firmware, but fallback runs before
  ExitBootServices, where writes are saved on reset.

## Hardware validation (2026-10-23)

Booted from the SATA SSD (reached at 192.168.4.227) through EDK2 v1.1 with
HDMI connected:

- Kernel 7.2.11-200.fc44 with the GRUB-supplied Fedora DTB; UEFI; SELinux
  enforcing, no AVC denials; system `running`, no failed units.
- Btrfs root on `/dev/sda3` with all five subvolumes; growroot expanded it to
  237 GiB; scrub found no errors.
- Panthor initialized the Mali-G610; `end0` up via DHCP.
- Native rockchip-drm bound VOP2 and HDMI0 with no handoff panic. DDC EDID
  reads failed, giving 1024x768. The original EDID override gave
  2560x1440@59.95 (241.5 MHz) with flickering red pixels; 1920x1080 at
  148.5 MHz and 2560x1440 at 240.0 MHz were clean. With the 240 MHz EDID,
  after a reboot HDMI-A-1 runs 2560x1440@59.58, 8 bpc RGB, as the preferred
  mode, confirmed visually clean; LightDM greeter on Xorg.
- Not validated: HDMI1, DP, audio, suspend, PCIe/NVMe, the second GMAC.

## Wi-Fi and Bluetooth (added 2026-10-25)

The AP6275P support (`config/ap6275p/`) was developed on the same board
under Arch Linux ARM with `linux-aarch64` 7.2.11, the same kernel version
as this image. There:

- the BCM43752 enumerated on `0002:21:00.0`;
- `brcmfmac` started firmware 18.35.387.23.146 and scanned 2.4/5 GHz
  networks;
- Bluetooth loaded `BCM4362A2.hcd` and `hci0` was powered.

`firefly-dt-ap6275p` was run on the 7.2.11 and 6.19.10 DTBs from the
built image. All phandle references resolved, with no duplicates.

Not yet established for Fedora: an image built with these changes, and a
Fedora boot using them. The installed Fedora disk was not attached when
they were made.
- The SSD reports 3 reallocated and 3 pending sectors at 226 power-on hours
  (SMART PASSED, empty error log). Monitor with `smartctl -A /dev/sda`.

## AP6275P not responding (since early November 2026)

The module worked under Arch Linux ARM on 2026-10-25 (above). According to
the user, it stopped after a crash during HDMI1 experiments and has not
worked in any configuration since, including Firefly's stock firmware.

- Fedora with the AP6275P DTB: on every boot from 2026-11-01 onwards,
  Bluetooth failed with `hci0: command 0xfc18 tx timeout` and Wi-Fi never
  loaded firmware.
- PVE on eMMC: the vendor kernel's `rk3588-bluetooth.service` failed
  (2026-10-21 and 2026-11-15). Under Debian 7.2.9 with the same patch, the
  PCIe slot trained a bridge but nothing enumerated, and Bluetooth timed
  out after a driver rebind and after a cold power cycle. WL_REG_ON,
  BT_REG_ON and BT_WAKE were high, UART6 m1 was muxed, the PCIe reset was
  on GPIO1_B4 as in the vendor DT, and the hym8563 CLKOUT was enabled at
  32.768 kHz (register `0x0d` = `0x80`).

- PVE vendor kernel, 2026-11-16: the Beryllium wiki fix
  (<https://wiki.beryllium.gr/itx-3588j/Bluetooth-Fix>) was tested. That
  fix is `brcm_patchram_plus` on `/dev/ttyS6`, already Armbian's setting,
  after an rfkill power cycle. The vendor driver ran its full BT power
  sequence. The chip still did not answer HCI Reset (`01 03 0c 00`) in
  45 s.

The test DTBs left in `/boot/dtb-7.2.11-200.fc44.aarch64/rockchip/` are not
the HDMI1 experiment:

- `-test.dtb` (Nov 1) is an earlier AP6275P patch built from another
  source. It also disables `tsadc`, the SoC's thermal sensor, so do not
  boot it.
- `-test1.dtb` and `-test2.dtb` (Nov 4) are recovery attempts: an `lpo`
  clock on the PCIe node, a longer WL_REG_ON delay and Bluetooth autobaud.

The DTB that crashed was not found, so what damaged the module is unknown.
Do not enable HDMI1 again before that is understood.

New images are built with `AP6275P=0`. To remove the setup from the
installed SSD, run this on the booted Fedora system rather than offline,
so SELinux labels stay correct:

```bash
sudo systemctl disable brcmfmac-after-bt.service
sudo rm /etc/kernel/install.d/25-firefly-ap6275p.install \
  /etc/modprobe.d/brcmfmac-after-bt.conf
sudo sed -i 's|^GRUB_DEVICETREE=.*|GRUB_DEVICETREE="rockchip/rk3588-firefly-itx-3588j.dtb"|' /etc/default/grub
sudo sed -i 's|/rk3588-firefly-itx-3588j-ap6275p.dtb$|/rk3588-firefly-itx-3588j.dtb|' /boot/loader/entries/*.conf
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

## Unlabeled files (fixed 2026-10-23)

The first image relied on `/.autorelabel`. The chroot's `rpm` could not label
files on the SELinux-less build host, so about 11,000 files (including
`systemd`) had no label. Enforcing boot failed with `Failed to allocate
manager object` before the relabel could run. The builder now labels offline
with `setfiles`, once for each Btrfs subvolume, and verifies the result.

A disk written from the unlabeled image can be recovered at the board: in
GRUB press `e`, append `enforcing=0` to the kernel options, and boot with
Ctrl-X. The pending autorelabel then runs and reboots into enforcing mode.

## Black screen on the top HDMI port (2026-11-15)

After U-Boot testing and an EDK2 v1.1 reflash, the system booted and
LightDM ran, but the display stayed black after GRUB even though the UEFI
menu had shown on the same monitor. Force Output and Config Table Mode
were reset to the documented values; that did not help.

- `card0-HDMI-A-1` was `disconnected` and the `dw-hdmi-qp-hpd` interrupt
  count stayed at 0, even when the cable was replugged; Xorg fell back to a
  headless 1024x768 screen.
- The HDMI0 HPD level in SYS_GRF `SOC_STATUS1` (`0xfd58c384`, bit 16)
  was 0. The monitor was on the top port, which is HDMI1 (`fdea0000`),
  disabled in Fedora's DTB.
- Moving the cable to the bottom port (HDMI0) set bit 16 to 1 and gave
  `connected`, an HPD interrupt and 2560x1440 at 240 MHz.
- Bit 24 (HDMI1 HPD level) read 1 with the cable on either port, so it
  does not show where the monitor is while HDMI1 is disabled.

LightDM does not reconfigure its Xorg server when the monitor appears after
it starts. If the cable is moved while Fedora is running, run
`sudo systemctl restart lightdm`.

To check whether HDMI0 sees hot-plug, read bit 16 (root, read-only;
1 = monitor detected):

```bash
sudo python3 -c 'import mmap,os,struct
m=mmap.mmap(os.open("/dev/mem",os.O_RDONLY|os.O_SYNC),4096,mmap.MAP_SHARED,mmap.PROT_READ,offset=0xfd58c000)
print("HDMI0 HPD", struct.unpack("<I",m[0x384:0x388])[0]>>16&1)'
```

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
