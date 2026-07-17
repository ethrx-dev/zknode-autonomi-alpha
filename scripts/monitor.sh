#!/bin/bash
set -euo pipefail

# monitor.sh — Display zknode-autonomi stack status

CONTAINERS=(
    mix-dirauth-1 mix-dirauth-2 mix-dirauth-3
    mix-1 mix-2 mix-3
    mix-gateway mix-servicenode
    mixnet-proxy
    ant-node antd
)

TOTAL=${#CONTAINERS[@]}
RUNNING=0
FAILED=()

for c in "${CONTAINERS[@]}"; do
    state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "missing")
    if [ "$state" = "running" ]; then
        RUNNING=$((RUNNING + 1))
    else
        FAILED+=("$c:$state")
    fi
done

PROXY_STATUS="DOWN"
BYTES_FWD="0"
if docker inspect mixnet-proxy &>/dev/null 2>&1; then
    STATUS_JSON=$(curl -s http://127.0.0.1:9090/status 2>/dev/null || echo "")
    if [ -n "$STATUS_JSON" ]; then
        PROXY_STATUS=$(echo "$STATUS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print('ACTIVE' if d.get('mixnet_connected') else 'INACTIVE')" 2>/dev/null || echo "UNKNOWN")
        BYTES_FWD=$(echo "$STATUS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('bytes_forwarded',0))" 2>/dev/null || echo "0")
    fi
fi

ANT_STATUS="DOWN"
ANT_PEERS=0
if docker inspect ant-node &>/dev/null 2>&1; then
    ANT_STATUS=$(docker inspect -f '{{.State.Status}}' ant-node 2>/dev/null || echo "unknown")
    ANT_PEERS=$(docker logs ant-node --tail=50 2>&1 | grep -oP '(\d+) peers' | tail -1 | grep -oP '^\d+' || echo "0")
fi

STORAGE_USED="N/A"
if [ -d ./data/chunks ]; then
    STORAGE_USED=$(du -sh ./data/chunks 2>/dev/null | cut -f1 || echo "N/A")
elif [ -d /mnt/trinity/autonomi/chunks ]; then
    STORAGE_USED=$(du -sh /mnt/trinity/autonomi/chunks 2>/dev/null | cut -f1 || echo "N/A")
fi

MIXNET_EXITS=$(docker logs mix-servicenode --tail=100 2>&1 | grep -c 'FORWARD' 2>/dev/null || echo "0")

echo ""
echo "┌────────────────────────────────────────┐"
echo "│  zknode-autonomi — Monitor             │"
echo "├────────────────────────────────────────┤"
printf "│  Services: %d/%d running" "$RUNNING" "$TOTAL"
printf "%*s│\n" $((22 - ${#RUNNING} - ${#TOTAL} - 12)) ""
echo "│  Mixnet: $(if [ $RUNNING -ge 9 ]; then echo 'CONSENSUS ✓'; else echo 'PENDING...'; fi)        │"
printf "│  Proxy: %-31s│\n" "$PROXY_STATUS, ${BYTES_FWD} bytes forwarded"
printf "│  ant-node: %-28s│\n" "$(echo $ANT_STATUS | tr '[:lower:]' '[:upper:]'), ${ANT_PEERS} peers"
printf "│  Storage: %-30s│\n" "$STORAGE_USED"
printf "│  Mixnet exits: %-24s│\n" "$MIXNET_EXITS packets"
echo "└────────────────────────────────────────┘"

if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    echo "Failed containers:"
    for f in "${FAILED[@]}"; do
        echo "  - $f"
    done
fi
