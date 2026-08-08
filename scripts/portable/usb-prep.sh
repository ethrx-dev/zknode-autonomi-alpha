#!/usr/bin/env bash
# usb-prep.sh — build a portable LUKS-encrypted USB drive containing the
# P4P wiki mesh node. Run on the build machine (SCM4 or any Docker host)
# with the target USB drive attached.
#
# What it creates on the drive:
#   <mount>/zknode-autonomi/   the full repo (configs, identity keys, wiki)
#   <mount>/zknode-autonomi/bin/      vendored host binaries (chatd, zkchat,
#                                     llm-wiki, ant)
#   <mount>/zknode-autonomi/wikis/    wiki data set
#   <mount>/zknode-autonomi/images/   docker save tarballs (per-arch)
#   <mount>/zknode-autonomi/.env      generated for the drive
#
# Usage:
#   sudo ./scripts/portable/usb-prep.sh -d /dev/sdX [-l ZKNODE] [-p passfile]
#
# Options:
#   -d <dev>   USB block device to format (REQUIRED, e.g. /dev/sda)
#   -l <label> LUKS/ext4 label (default: ZKNODE)
#   -p <file>  file containing the passphrase (else prompted)
#   -m <path>  mount point (default: /mnt/zknode)
#   -s <path>  source repo dir (default: this script's repo)
#   -B <dir>   dir holding host binaries to vendor (default: repo/bin)
#   -W <dir>   dir holding wiki data to vendor (default: repo/wikis)
#   --no-luks  skip encryption, write plain ext4 (dev testing only)
#   -h         help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DEV=""
LABEL="ZKNODE"
PASSFILE=""
MOUNT="/mnt/zknode"
SRC="$REPO_ROOT"
SRC_BIN="$REPO_ROOT/bin"
SRC_WIKIS="$REPO_ROOT/wikis"
LUKS=1
MAPPER="zknode-usb"

usage() {
    sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d) DEV="${2:?missing arg}"; shift 2 ;;
        -l) LABEL="$2"; shift 2 ;;
        -p) PASSFILE="$2"; shift 2 ;;
        -m) MOUNT="$2"; shift 2 ;;
        -s) SRC="$2"; shift 2 ;;
        -B) SRC_BIN="$2"; shift 2 ;;
        -W) SRC_WIKIS="$2"; shift 2 ;;
        --no-luks) LUKS=0; shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

[ -n "$DEV" ] || { echo "ERROR: -d <device> is required" >&2; usage 1; }
[ -b "$DEV" ] || { echo "ERROR: $DEV is not a block device" >&2; exit 1; }
[ -d "$SRC/docker-compose.yml" ] || [ -f "$SRC/docker-compose.yml" ] || {
    echo "ERROR: source repo not found at $SRC" >&2; exit 1; }

ARCH="$(uname -m)"
[ "$ARCH" = "aarch64" ] && IMG_ARCH="arm64" || IMG_ARCH="$ARCH"

step() { echo -e "[+] $1"; }
warn() { echo -e "[!] $1"; }
err()  { echo -e "[x] $1"; }

# ─── Pre-flight ─────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    err "run as root (sudo)"
    exit 1
fi
if mountpoint -q "$DEV" 2>/dev/null; then
    err "$DEV is mounted — unmount first"; exit 1
fi
if ! command -v cryptsetup >/dev/null; then
    err "cryptsetup not installed (apt install cryptsetup)"; exit 1
fi
if ! command -v docker >/dev/null; then
    err "docker not found"; exit 1
fi

# Warn if the target looks like the boot disk
if lsblk -no TRAN "$DEV" 2>/dev/null | grep -qi '^usb$' || [ "$LUKS" = "0" ]; then
    :
else
    warn "$DEV may not be USB (lsblk transport: $(lsblk -no TRAN "$DEV" 2>/dev/null || echo unknown))"
fi

read -r -p "DESTROY ALL DATA ON $DEV and build the portable node? [y/N] " ans
[ "$ans" = "y" ] || { echo "aborted"; exit 1; }

# ─── LUKS setup ─────────────────────────────────────────────
if [ "$LUKS" = "1" ]; then
    step "Wiping + luksFormat $DEV (label $LABEL)..."
    wipefs -a "$DEV"
    if [ -n "$PASSFILE" ]; then
        cryptsetup luksFormat --type luks2 --batch-mode --key-file "$PASSFILE" "$DEV"
        cryptsetup open --key-file "$PASSFILE" "$DEV" "$MAPPER"
    else
        cryptsetup luksFormat --type luks2 "$DEV"
        cryptsetup open "$DEV" "$MAPPER"
    fi
    mkfs.ext4 -q -L "$LABEL" "/dev/mapper/$MAPPER"
    OPENED=1
else
    step "Plain ext4 (no encryption) on $DEV..."
    wipefs -a "$DEV"
    mkfs.ext4 -q -L "$LABEL" "$DEV"
    OPENED=0
fi

mkdir -p "$MOUNT"
mount -L "$LABEL" "$MOUNT" || mount "/dev/mapper/$MAPPER" "$MOUNT"

trap 'cd /; umount "$MOUNT" 2>/dev/null || true; [ "${OPENED:-0}" = "1" ] && cryptsetup close "$MAPPER" 2>/dev/null || true' EXIT

# ─── Stage repo ─────────────────────────────────────────────
DST="$MOUNT/zknode-autonomi"
step "Copying repo $SRC -> $DST..."
mkdir -p "$DST"
rsync -a --delete \
    --exclude='.git/' \
    --exclude='data/' \
    --exclude='katzenpost/' \
    --exclude='**/target/' \
    --exclude='.docker/' \
    --exclude='images/' \
    --exclude='.env' \
    --exclude='*.tar.gz' \
    "$SRC/" "$DST/"

# ─── Vendor host binaries ───────────────────────────────────
step "Vendoring host binaries from $SRC_BIN..."
mkdir -p "$DST/bin"
if [ -d "$SRC_BIN" ]; then
    for b in chatd zkchat llm-wiki ant; do
        if [ -x "$SRC_BIN/$b" ]; then
            cp -a "$SRC_BIN/$b" "$DST/bin/"
            step "  bin/$b"
        else
            warn "  bin/$b missing from $SRC_BIN — $(grep -c "$b" "$DST/docker-compose.yml" 2>/dev/null || echo 0) compose refs will fail"
        fi
    done
else
    warn "no $SRC_BIN dir — compose mounts of bin/* will fail on target"
fi

# ─── Vendor wiki data ───────────────────────────────────────
step "Vendoring wiki data from $SRC_WIKIS..."
mkdir -p "$DST/wikis"
if [ -d "$SRC_WIKIS" ]; then
    rsync -a --delete "$SRC_WIKIS/" "$DST/wikis/"
    step "  $(du -sh "$DST/wikis" | cut -f1) copied"
else
    warn "no $SRC_WIKIS dir — wiki will be empty"
fi

# ─── Vendor docker images ───────────────────────────────────
# Vendor images for BOTH arches so the drive boots on arm64 or amd64.
# usb-init.sh loads only the tarballs matching the target's arch.
# Resolve image names from compose (arch-suffixed refs).
IMAGES_FILE="$DST/images.list"
: > "$IMAGES_FILE"
{
    grep -ho 'image: *[^ ]*' docker-compose.yml docker-compose.zymkey.yml 2>/dev/null \
        | sed 's/^image: *//; s/["'"'"']//g' \
        | sed "s/\${IMAGE_MIXNET}/zeros\/mixnet-node/; s/\${IMAGE_MIXNET_PROXY}/zeros\/mixnet-proxy/; s/\${IMAGE_ANTD}/zeros\/antd/; s/\${IMAGE_DASHBOARD}/zknode-dashboard:latest/; s/\${IMAGE_WALLETSHIELD}/walletshield-rebuild:latest/" \
        | sort -u
} > "$IMAGES_FILE"

mkdir -p "$DST/images"
for A in arm64 amd64; do
    step "Vendoring docker images for $A ..."
    found=0
    while IFS= read -r img; do
        [ -n "$img" ] || continue
        # skip build-only services (nomadnet) and generic base images already present
        case "$img" in
            zknode-dashboard:*|nomadnet*) continue ;;
        esac
        # only arch-specific refs get the suffix; static refs kept as-is
        case "$img" in
            zeros/*) tagged="$img:$A" ;;
            *)       tagged="$img" ;;
        esac
        if docker image inspect "$tagged" >/dev/null 2>&1; then
            fname="$(echo "$tagged" | tr '/:' '__').tar.gz"
            step "  save $tagged -> images/$fname"
            docker save "$tagged" | gzip > "$DST/images/$fname"
            found=1
        else
            warn "  image NOT found locally, skipping: $tagged"
        fi
    done < "$IMAGES_FILE"
    [ "$found" = "1" ] || warn "  no images vendored for $A — target will need docker pull/build"
done

# ─── Write .env ─────────────────────────────────────────────
# IMAGE_* tags reference IMG_ARCH so the TARGET host's arch is used;
# usb-init.sh sets IMG_ARCH from $(uname -m) before deploy.
step "Writing $DST/.env ..."
cat > "$DST/.env" <<EOF
# Generated by usb-prep.sh ($(date -u +%Y-%m-%dT%H:%MZ))
# IMG_ARCH is resolved by usb-init.sh on the target host.
ZK_ROOT=$MOUNT/zknode-autonomi
ZK_BIN=\${ZK_ROOT}/bin
ZK_WIKIS=\${ZK_ROOT}/wikis
ZK_LLM_WIKI_HOME=\${ZK_ROOT}/.llm-wiki
ZK_ANT_SHARE=\${ZK_ROOT}/data/ant-share
ZK_ANT_NODE=\${ZK_ROOT}/data/ant-node
ZK_ANTD_NODE1=\${ZK_ROOT}/data/antd-node-1
ZK_ANTD_LOGS=\${ZK_ROOT}/data/antd-logs
AUTONOMI_CHUNK_DB=\${ZK_ROOT}/data/chunks
ZK_POOL=\${ZK_ROOT}/pool

IMG_ARCH=arm64
IMAGE_MIXNET=zeros/mixnet-node:\${IMG_ARCH}
IMAGE_MIXNET_PROXY=zeros/mixnet-proxy:\${IMG_ARCH}
IMAGE_ANTD=zeros/antd:\${IMG_ARCH}
IMAGE_DASHBOARD=zknode-dashboard:latest
IMAGE_WALLETSHIELD=ws-deploy:latest
IMAGE_RETICULUM=zeros/reticulum:\${IMG_ARCH}
IMAGE_STORAGE_PROVED=zeros/storage-proved-rs:\${IMG_ARCH}

MIXNET_MEM_LIMIT=256m
PROXY_MEM_LIMIT=256m

DASHBOARD_PORT=8080
LLM_WIKI_PORT=18765
WS_PORT=9200
WALLETSHIELD_PORT=9200
STORAGE_PROVED_PORT=9201
ANTD_PORT=12000

AUTONOMI_EVM_NETWORK=mainnet
ANT_NETWORK_MODE=testnet
ANT_EVM_NETWORK=arbitrum-sepolia
WALLETSHIELD_UPSTREAM=https://ethereum-rpc.publicnode.com
ANT_REWARDS_ADDRESS=${ANT_REWARDS_ADDRESS:-0xf21CEFD6773491323B05162f62bE5106B27893aa}
EOF

# ─── Summary ────────────────────────────────────────────────
step "Done. Drive summary:"
echo
du -sh "$DST" "$DST/images" 2>/dev/null || true
echo
echo "  Target host steps:"
echo "    1. plug in the drive"
echo "    sudo /mnt/zknode/zknode-autonomi/scripts/portable/usb-init.sh"
echo
echo "  Or copy the unit + enable autoboot:"
echo "    sudo cp $DST/scripts/portable/zknode-boot.service /etc/systemd/system/"
echo "    sudo systemctl enable --now zknode-boot"
