#!/usr/bin/env bash
# luks-close.sh — unmount + lock the portable node drive.
#
#   sudo ./scripts/portable/luks-close.sh [-m /mnt/zknode] [-l ZKNODE]
set -euo pipefail

MOUNT="/mnt/zknode"
MAPPER="zknode-usb"

while [ $# -gt 0 ]; do
    case "$1" in
        -m) MOUNT="$2"; shift 2 ;;
        -l) MAPPER="zknode-usb"; shift 2 ;;
        -h|--help) echo "usage: luks-close.sh [-m /mnt/zknode]"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then echo "run as root (sudo)" >&2; exit 1; fi

if mountpoint -q "$MOUNT"; then
    umount "$MOUNT"
    echo "[+] unmounted $MOUNT"
fi
if [ -e "/dev/mapper/$MAPPER" ]; then
    cryptsetup close "$MAPPER"
    echo "[+] locked $MAPPER"
fi
echo "Done."
