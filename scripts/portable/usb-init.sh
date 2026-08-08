#!/usr/bin/env bash
# usb-init.sh — bring the portable P4P wiki mesh node up on a foreign host.
#
# Steps:
#   1. find the USB drive by LUKS/ext4 label
#   2. unlock (prompts for passphrase) and mount
#   3. docker load the vendored images for this machine's arch
#   4. run the staged deployment (deploy.sh)
#
# Usage:
#   sudo ./scripts/portable/usb-init.sh [-l ZKNODE] [-m /mnt/zknode] [--no-deploy]
#
# Options:
#   -l <label>   drive label (default: ZKNODE)
#   -m <path>    mount point (default: /mnt/zknode)
#   -d <dev>     skip label scan, use this block device
#   --no-deploy  only unlock+mount+load images, do not start containers
#   --open-only  only unlock+mount (no image load, no deploy)
#   -h           help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LABEL="ZKNODE"
MOUNT="/mnt/zknode"
DEV=""
MAPPER="zknode-usb"
DEPLOY=1
LOAD=1

usage() {
    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -l) LABEL="$2"; shift 2 ;;
        -m) MOUNT="$2"; shift 2 ;;
        -d) DEV="$2"; shift 2 ;;
        --no-deploy) DEPLOY=0; shift ;;
        --open-only) DEPLOY=0; LOAD=0; shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

step() { echo -e "[+] $1"; }
warn() { echo -e "[!] $1"; }
err()  { echo -e "[x] $1"; }

if [ "$(id -u)" -ne 0 ]; then
    err "run as root (sudo)"
    exit 1
fi

# ─── 1. find + unlock the drive ─────────────────────────────
REPO="$MOUNT/zknode-autonomi"

if [ -n "$DEV" ]; then
    [ -b "$DEV" ] || { err "$DEV is not a block device"; exit 1; }
elif [ -d "$REPO" ]; then
    step "$REPO already present — assuming drive mounted at $MOUNT"
    DEV="mounted"
elif [ -e "/dev/mapper/$MAPPER" ]; then
    step "/dev/mapper/$MAPPER already open"
    DEV="open"
else
    step "Scanning for LUKS device with label '$LABEL'..."
    CAND=$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null | tr '\n' ' ' | xargs -n1 2>/dev/null || true)
    DEV=""
    for cand in $CAND; do
        # open read-only to probe the fs label without a key prompt
        if cryptsetup open "$cand" "${MAPPER}-probe" --type luks --test-passphrase 2>/dev/null; then
            : # has a key; label unknown without passphrase — fall back to manual
        fi
        # prefer devices whose raw name hints at removable storage
        if lsblk -no TRAN "$cand" 2>/dev/null | grep -qi '^usb$'; then
            DEV="$cand"
            break
        fi
    done
    if [ -z "$DEV" ]; then
        echo
        echo "Could not auto-identify the drive. Candidates:"
        blkid | grep -i luks || true
        echo
        read -r -p "Enter device (e.g. /dev/sda): " DEV
    fi
    [ -b "$DEV" ] || { err "invalid device $DEV"; exit 1; }
fi

if [ "$DEV" != "mounted" ] && [ "$DEV" != "open" ] && [ ! -e "/dev/mapper/$MAPPER" ]; then
    step "Unlocking $DEV ..."
    cryptsetup open "$DEV" "$MAPPER" || { err "unlock failed"; exit 1; }
fi

if ! mountpoint -q "$MOUNT"; then
    step "Mounting $MOUNT ..."
    mkdir -p "$MOUNT"
    mount -L "$LABEL" "$MOUNT" 2>/dev/null \
        || mount "/dev/mapper/$MAPPER" "$MOUNT" \
        || { err "mount failed"; exit 1; }
fi

[ -f "$REPO/.env" ] || { err ".env not found on drive ($REPO/.env)"; exit 1; }
cd "$REPO"

# ─── 2. load vendored images ────────────────────────────────
if [ "$LOAD" = "1" ]; then
    ARCH="$(uname -m)"
    [ "$ARCH" = "aarch64" ] && IMG_ARCH="arm64" || IMG_ARCH="$ARCH"
    step "Loading vendored docker images for $IMG_ARCH ..."
    if ! command -v docker >/dev/null; then
        err "docker not found — install Docker Engine + Compose v2 first"
        exit 1
    fi
    if ls "$REPO/images/"*"__${IMG_ARCH}.tar.gz" >/dev/null 2>&1; then
        for f in "$REPO/images/"*"__${IMG_ARCH}.tar.gz"; do
            step "  docker load $f"
            docker load -i "$f"
        done
    else
        warn "no vendored images for $IMG_ARCH on drive — running docker compose up may try to pull"
    fi
    set -a
    # shellcheck disable=SC1091
    source "$REPO/.env"
    IMG_ARCH="$(uname -m | sed 's/aarch64/arm64/; s/x86_64/amd64/')"
    export IMG_ARCH
    set +a
fi

# ─── 3. deploy ──────────────────────────────────────────────
if [ "$DEPLOY" = "1" ]; then
    step "Deploying stack (staged boot) ..."
    if [ -x "$REPO/deploy.sh" ]; then
        "$REPO/deploy.sh" || warn "deploy.sh exited non-zero — check ./scripts/deploy.sh --status"
    else
        docker compose up -d || { err "compose up failed"; exit 1; }
    fi
    echo
    echo "  Dashboard:  http://127.0.0.1:${DASHBOARD_PORT:-8080}"
    echo "  Health:     ./scripts/monitor.sh"
fi

step "Done."
