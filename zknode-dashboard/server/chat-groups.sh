#!/bin/sh
# The chat servicenode runs on the VPS mixnet (there is no local
# mix-servicenode). List group metadata by SSHing to the VPS and
# reading the meta.json files inside the mix-servicenode container.
# VPS_SUDO_PASS is read from env (never hardcoded); VPSHOST/VPSUSER/VPSKEY
# can be overridden the same way (defaults: zknode-mix, ethrx-dev, vps_key).
VPSHOST="${VPSHOST:-zknode-mix}"
VPSUSER="${VPSUSER:-ethrx-dev}"
VPSKEY="${VPSKEY:-/root/.ssh/vps_key}"
: "${VPS_SUDO_PASS:?VPS_SUDO_PASS env required (VPS node ssh sudo)}"
ssh -i "$VPSKEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$VPSUSER"@"$VPSHOST" "echo '$VPS_SUDO_PASS' | sudo -S -p '' docker exec mix-servicenode find /tmp/zkchat -name meta.json -print 2>/dev/null -exec cat {} +" 2>/dev/null || true