#!/bin/bash
# Health check script for zknode-autonomi
# Returns JSON with service status
set -euo

NTFY_TOPIC="${NTFY_TOPIC:-}"
STATE_FILE="/tmp/zknode-health-state"

echo "{"
echo '  "timestamp": "'$(date -Iseconds)'",'

# Dirauth consensus check (all 3 should show "SIGNED")
CONSENSUS=$(docker logs mix-dirauth-1 --tail 5 2>&1 | grep -c "SIGNED" || true)
echo '  "dirauth_consensus": '$([ "$CONSENSUS" -gt 0 ] && echo "true" || echo "false")','

# Mix nodes running
MIX_OK=0
for m in mix-1 mix-2 mix-3 mix-gateway mix-servicenode mix-client; do
  docker ps --format '{{.Names}}' | grep -q "$m" && MIX_OK=$((MIX_OK + 1))
done
echo '  "mix_nodes_running": "'$MIX_OK'/6",'

# Walletshield (30s timeout: mixnet roundtrip through 5 Sphinx hops + service node + upstream RPC)
WS_OK=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 http://127.0.0.1:9200/ethereum \
  -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null || echo "000")
echo '  "walletshield_http": "'$WS_OK'",'

# Dashboard
DB_OK=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:8080/api/system 2>/dev/null || echo "000")
echo '  "dashboard_http": "'$DB_OK'",'

# Disk
DISK=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//')
echo '  "disk_used_percent": '$DISK','

# Last backup age
LAST_BACKUP=$(ls -dt /mnt/backup/zknode/daily/*/ 2>/dev/null | head -1)
if [ -n "$LAST_BACKUP" ]; then
  BACKUP_AGE=$(( ($(date +%s) - $(stat -c %Y "$LAST_BACKUP")) / 3600 ))
else
  BACKUP_AGE=-1
fi
echo '  "last_backup_age_hours": '$BACKUP_AGE','

# Mixnet connectivity (kpclientd)
KPCLIENTD=$(ss -tlnp | grep -c ":64332" || true)
echo '  "kpclientd_listening": '$([ "$KPCLIENTD" -gt 0 ] && echo "true" || echo "false")

echo '}'

# ─── ntfy.sh Push Notification ──────────────────────────
if [ -n "$NTFY_TOPIC" ]; then
  OVERALL="healthy"
  [ "$MIX_OK" -lt 5 ] && OVERALL="degraded"
  [ "$DISK" -gt 90 ] && OVERALL="degraded"
  [ "$WS_OK" != "200" ] && OVERALL="degraded"
  [ "$CONSENSUS" -eq 0 ] && OVERALL="degraded"

  LAST_STATE=""
  [ -f "$STATE_FILE" ] && LAST_STATE=$(cat "$STATE_FILE")

  if [ "$OVERALL" != "$LAST_STATE" ]; then
    echo "$OVERALL" > "$STATE_FILE"
    MSG="zknode health: $OVERALL"
    [ "$OVERALL" = "degraded" ] && MSG="$MSG | mix=$MIX_OK/6 disk=${DISK}% ws=$WS_OK"
    curl -sf -H "Title: ZKNode Alert" -d "$MSG" "https://ntfy.sh/$NTFY_TOPIC" 2>/dev/null || true
  fi
fi
