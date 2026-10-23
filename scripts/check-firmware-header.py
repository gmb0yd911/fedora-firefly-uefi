#!/usr/bin/env python3
"""Refuse whole-disk writes over a recognized Firefly EDK2 firmware image."""

import sys
from pathlib import Path

if len(sys.argv) != 2:
    sys.exit("Usage: check-firmware-header.py DEVICE_OR_IMAGE")

with Path(sys.argv[1]).open("rb") as source:
    header = source.read(16 * 1024 * 1024)

# FIT descriptions from the EDK2 RK3588 images, including the installed v1.1.
if any(marker in header for marker in (
    b"FIT Image with ATF/OP-TEE/UEFI",
    b"FIT Image with ATF/UEFI",
    b"BL33_AP_UEFI",
)):
    sys.exit(
        "EDK2 UEFI detected in the target boot area. Whole-disk deployment "
        "refused: it would erase the firmware. Preserve this installation "
        "and add an ESP in unused space, or move and validate firmware on "
        "separate storage before replacing the disk."
    )

print("No recognized EDK2 FIT image in the target's first 16 MiB.")
