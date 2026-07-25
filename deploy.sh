#!/bin/bash
# zknode-autonomi boot sequencer
# Runs at system startup to start containers in dependency order
# avoiding CPU overload from all containers starting simultaneously.

set -e

LOG=/var/log/zknode-boot.log
exec > "$LOG" 2>&1
echo "[$(date)] zknode boot sequencer starting"

# Fix zymkey symlink (HSM device)
ZYMKEY_DEV="/dev/ttyACM0"
if [ -e "$ZYMKEY_DEV" ] && [ ! -e /dev/zymkey ]; then
    ln -sf "$ZYMKEY_DEV" /dev/zymkey
    echo "[$(date)] zymkey symlink created: $ZYMKEY_DEV"
fi

# Ensure walletshield data dir exists
mkdir -p /home/zero-tech/zknode-autonomi/data/walletshield

# Phase 1: Directory Authorities (need consensus first)
echo "[$(date)] Phase 1: Starting dirauths"
for i in 1 2 3; do
    docker start mix-dirauth-$i
    sleep 4
done
sleep 10

# Phase 2: Mix nodes (need dirauth consensus)
echo "[$(date)] Phase 2: Starting mix nodes"
for i in 1 2 3; do
    docker start mix-$i
    sleep 3
done
sleep 5

# Phase 3: Gateway and servicenode (need mix network)
echo "[$(date)] Phase 3: Starting gateway and servicenode"
docker start mix-gateway
sleep 3
docker start mix-servicenode
sleep 10

# Phase 4: Client and walletshield (need gateway + servicenode)
echo "[$(date)] Phase 4: Starting client and walletshield"
docker start mix-client
sleep 3
docker start walletshield
sleep 5

# Phase 5: Dashboard and support services
echo "[$(date)] Phase 5: Starting dashboard and support"
docker start zknode-dashboard
for c in antd reticulum zkifc; do
    docker start "$c" 2>/dev/null || true
    sleep 2
done

echo "[$(date)] zknode boot sequencer complete"
