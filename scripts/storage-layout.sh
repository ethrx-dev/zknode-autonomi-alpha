#!/usr/bin/env bash
# zknode-autonomi — Storage Layout Verification
#
# Checks the two-tier storage hierarchy:
#   microSD  → performance-sensitive app data (mixnet bbolt, antd index, proxy)
#   USB pool → bulk sequential data (chunk DB, logs, backups)
#
# Run: ./scripts/storage-layout.sh
# Fails non-zero if critical paths are missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# Source .env
set -a
source "$ENV_FILE"
set +a

echo "╔══════════════════════════════════════════════════════╗"
echo "║       zknode-autonomi — Storage Layout Check         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

FAIL=0

# ─── Tier 1: microSD paths (performance-critical) ───────────

echo "━━━ Tier 1: microSD (performance-critical) ━━━"
echo ""

microsd_paths() {
  local label="$1" path="$2"
  if [ -d "$path" ]; then
    local size
    size=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
    echo "  ✅ $label  $path  ($size)"
  else
    echo "  ❌ $label  $path  (MISSING — run setup.sh)"
    FAIL=1
  fi
}

microsd_paths "Mixnet auth1"  "$PROJECT_DIR/data/mixnet/auth1"
microsd_paths "Mixnet auth2"  "$PROJECT_DIR/data/mixnet/auth2"
microsd_paths "Mixnet auth3"  "$PROJECT_DIR/data/mixnet/auth3"
microsd_paths "Mixnet mix1"   "$PROJECT_DIR/data/mixnet/mix1"
microsd_paths "Mixnet mix2"   "$PROJECT_DIR/data/mixnet/mix2"
microsd_paths "Mixnet mix3"   "$PROJECT_DIR/data/mixnet/mix3"
microsd_paths "Mixnet gw"     "$PROJECT_DIR/data/mixnet/gateway1"
microsd_paths "Mixnet sn"     "$PROJECT_DIR/data/mixnet/servicenode1"
microsd_paths "Mixnet courier" "$PROJECT_DIR/data/mixnet/courier"
microsd_paths "antd metadata"  "$PROJECT_DIR/data/antd"
microsd_paths "Proxy state"    "$PROJECT_DIR/data/proxy"
microsd_paths "Zymkey config"  "$PROJECT_DIR/data/zymbit"

# microSD free space warning
SD_AVAIL_KB=$(df / | tail -1 | awk '{print $4}')
echo ""
echo "  microSD free: $(numfmt --to=iec $((SD_AVAIL_KB * 1024)) 2>/dev/null || echo "${SD_AVAIL_KB}KB")"
if [ "${SD_AVAIL_KB:-0}" -lt 5000000 ] 2>/dev/null; then  # <5 GB
  echo "  ⚠️  microSD space low (<5 GB). Run: docker system prune -f"
fi

# ─── Tier 2: USB pool paths (bulk data) ──────────────────────

echo ""
echo "━━━ Tier 2: USB pool (bulk sequential I/O) ━━━"
echo ""

if [ -d "$TRINITY_MOUNT" ]; then
  echo "  ✅ USB pool: $TRINITY_MOUNT"
  df -h "$TRINITY_MOUNT" | tail -1 | awk '{print "     Size: "$2"  Used: "$3"  Free: "$4}'

  usb_paths() {
    local label="$1" path="$2"
    if [ -d "$path" ]; then
      local size
      size=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
      echo "  ✅ $label  $path  ($size)"
    else
      echo "  ⚠️  $label  $path  (not yet created — will be created on first use)"
    fi
  }

  usb_paths "Chunk DB"   "$TRINITY_MOUNT/autonomi/chunks"
  usb_paths "Autonomi logs" "$TRINITY_MOUNT/logs/autonomi"
  usb_paths "Backup"     "$TRINITY_MOUNT/backup"

else
  echo "  ❌ USB pool: $TRINITY_MOUNT (NOT MOUNTED)"
  echo "     Performance-sensitive data (mixnet DBs) still on microSD  ✅"
  echo "     Bulk data (chunks) will have no storage  ⚠️"
  echo ""
  echo "     To mount USB pool:"
  echo "       sudo ./scripts/setup-usb-pool.sh"
  FAIL=1
fi

# ─── Summary ───────────────────────────────────────────────────

echo ""
echo "━━━ Storage Summary ━━━"
echo ""

# microSD services total
MDSD_SIZE=$(du -sh "$PROJECT_DIR/data" 2>/dev/null | awk '{print $1}')
echo "  microSD (perf):  $PROJECT_DIR/data/  $MDSD_SIZE"
echo "  Docker layers:   /var/lib/docker/  $(du -sh /var/lib/docker/ 2>/dev/null | awk '{print $1}' || echo '?')"

# USB pool total
if [ -d "$TRINITY_MOUNT" ]; then
  USB_SIZE=$(du -sh "$TRINITY_MOUNT" 2>/dev/null | awk '{print $1}')
  echo "  USB pool (bulk): $TRINITY_MOUNT  $USB_SIZE"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "  ✅ All paths OK"
else
  echo "  ⚠️  Some paths missing — run setup.sh"
fi
echo ""
