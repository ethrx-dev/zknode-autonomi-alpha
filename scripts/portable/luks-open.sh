#!/usr/bin/env bash
# luks-open.sh — unlock + mount the portable node drive on a foreign host.
# Convenience wrapper around usb-init.sh --open-only.
#
#   sudo ./scripts/portable/luks-open.sh [-l ZKNODE] [-m /mnt/zknode] [-d /dev/sdX]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/usb-init.sh" --open-only "$@"
