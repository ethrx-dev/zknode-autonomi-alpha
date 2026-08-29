#!/bin/bash
# Backup automation for zknode-autonomi
# Usage: ./scripts/backup/zknode-backup.sh [daily|weekly|monthly]
set -euo pipefail

TS=$(date +%Y%m%d_%H%M%S)
LABEL="${1:-daily}"
BACKUP_BASE="/mnt/usb_sda3/backup"
SOURCE="${ZK_SOURCE:-/home/<node-user>/zknode-autonomi}"
RETENTION_DAILY=7
RETENTION_WEEKLY=4
RETENTION_MONTHLY=3

mkdir -p "$BACKUP_BASE/zknode/$LABEL"
BACKUP_DIR="$BACKUP_BASE/zknode/$LABEL/$TS"

echo "=== zknode-backup: $LABEL @ $TS ==="
echo "Source: $SOURCE"
echo "Dest:   $BACKUP_DIR"

# Snapshot configs, compose, scripts (exclude runtime artifacts)
# Best-effort: rsync exit 23 (partial transfer, e.g. a runtime file that
# vanished mid-read) must not fail the whole backup — keys/configs are what
# matter and are present.
rsync -a --delete \
  --exclude='data/' \
  --exclude='*.log' \
  --exclude='*.socket' \
  --exclude='replica.db' \
  --exclude='courier' \
  --exclude='node_modules' \
  --exclude='chat-history.json' \
  --exclude='*.db' \
  --exclude='*.sst' \
  --exclude='*.tar.gz' \
  "$SOURCE/" "$BACKUP_DIR/" || echo "WARN: rsync partial (code $?) — continuing"

# Snapshot Docker images list
docker images --format '{{.Repository}}:{{.Tag}}' > "$BACKUP_DIR/docker-images.txt"
docker ps --format '{{.Names}} {{.Status}}' > "$BACKUP_DIR/docker-ps.txt"

# Snapshot container state
docker ps -a --format '{{.Names}} {{.Status}} {{.Image}}' > "$BACKUP_DIR/docker-ps-all.txt"

echo "Size: $(du -sh "$BACKUP_DIR" | cut -f1)"
echo "=== Backup complete ==="

# Retention cleanup
case "$LABEL" in
  daily)
    ls -dt "$BACKUP_BASE/zknode/daily/"* | tail -n +$((RETENTION_DAILY + 1)) | while read d; do
      echo "Removing old daily: $d"
      rm -rf "$d"
    done
    ;;
  weekly)
    ls -dt "$BACKUP_BASE/zknode/weekly/"* | tail -n +$((RETENTION_WEEKLY + 1)) | while read d; do
      echo "Removing old weekly: $d"
      rm -rf "$d"
    done
    ;;
  monthly)
    ls -dt "$BACKUP_BASE/zknode/monthly/"* | tail -n +$((RETENTION_MONTHLY + 1)) | while read d; do
      echo "Removing old monthly: $d"
      rm -rf "$d"
    done
    ;;
esac
