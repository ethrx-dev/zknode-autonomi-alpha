#!/bin/bash
# zknode-autonomi recovery script
# Restores from USB backup to fresh OS install
# Usage: sudo ./zmnt-restore.sh <backup_device> <backup_timestamp>
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <backup_device> <backup_timestamp>"
  echo "  backup_device: e.g. /dev/sda3"
  echo "  backup_timestamp: e.g. 20260717_050058"
  exit 1
fi

DEVICE="$1"
TIMESTAMP="$2"
USER_HOME="${ZK_USER_HOME:-/home/<node-user>}"
ZK_DIR="$USER_HOME/zknode-autonomi"
BACKUP_MOUNT="/mnt/backup"

echo "=== zknode-autonomi Recovery ==="
echo "Backup device: $DEVICE"
echo "Backup timestamp: $TIMESTAMP"

# Mount backup
if ! mountpoint -q "$BACKUP_MOUNT"; then
  echo "Mounting $DEVICE to $BACKUP_MOUNT..."
  sudo mkdir -p "$BACKUP_MOUNT"
  sudo mount "$DEVICE" "$BACKUP_MOUNT"
fi

BACKUP_PATH="$BACKUP_MOUNT/zknode/daily/$TIMESTAMP"
if [ ! -d "$BACKUP_PATH" ]; then
  echo "ERROR: Backup not found at $BACKUP_PATH"
  echo "Available backups:"
  ls -lt "$BACKUP_MOUNT/zknode/daily/" 2>/dev/null || echo "  (none)"
  exit 1
fi

# Restore files
echo "Restoring from $BACKUP_PATH..."
sudo mkdir -p "$ZK_DIR"
sudo rsync -a --delete \
  --exclude='data/' \
  --exclude='*.log' \
  --exclude='*.socket' \
  --exclude='replica.db' \
  --exclude='node_modules' \
  "$BACKUP_PATH/" "$ZK_DIR/"

# Fix ownership
sudo chown -R ${ZK_USER:-<node-user>}:${ZK_USER:-<node-user>} "$ZK_DIR"

# Pull Docker images from backup list
if [ -f "$BACKUP_PATH/docker-images.txt" ]; then
  echo "Restoring Docker images..."
  while IFS= read -r img; do
    if [ -n "$img" ]; then
      docker pull "$img" 2>/dev/null || echo "  Skipping $img (not found in registry)"
    fi
  done < "$BACKUP_PATH/docker-images.txt"
fi

# Setup backup timers
echo "Setting up backup timers..."
sudo cp "$ZK_DIR/scripts/backup/zknode-backup.service" /etc/systemd/system/
sudo cp "$ZK_DIR/scripts/backup/zknode-backup.timer" /etc/systemd/system/
sudo cp "$ZK_DIR/scripts/backup/zknode-backup-weekly.timer" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now zknode-backup.timer
sudo systemctl enable --now zknode-backup-weekly.timer

echo "=== Recovery complete ==="
echo "Next steps:"
echo "  1. cd $ZK_DIR"
echo "  2. docker compose up -d"
echo "  3. curl http://127.0.0.1:8080/api/system"
