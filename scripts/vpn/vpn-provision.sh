#!/usr/bin/env bash
# vpn-provision.sh — first-boot VPN provisioning for the bootable P4P wiki mesh node.
#
# Design (portable USB / live image):
#   WireGuard base, hub-and-spoke 10.66.0.0/24. The node is a spoke:
#     - fresh keypair GENERATED ON FIRST BOOT — nothing key-shaped is baked
#       into the squashfs image
#     - keys + config persist on the PERSIST partition (survives re-flash / reboot)
#     - the operator drops a hub [Peer] block at $PERSIST/vpn/peers.conf
#       (or pre-seeds it from /etc/zknode/vpn/peers.conf)
#   Boot order: network-online.target -> vpn-provision.service (this script)
#   Transport: kernel wireguard via wg-quick, automatic wireguard-go fallback
#              for kernels without the module (Wolfi path).
#
# Idempotent + safe: safe to run on every boot or by hand at any time.
set -euo pipefail

PERSIST="${PERSIST:-/persistent}"
VPN_DIR="${VPN_DIR:-$PERSIST/vpn}"
VG_IF="${VG_IF:-wg0}"
VGW_ADDR="${VGW_ADDR:-10.66.0.2/24}"
SEED_CONF="${SEED_CONF:-/etc/zknode/vpn/peers.conf}"

log() { echo "[vpn] $*"; }

mkdir -p "$VPN_DIR"
chmod 700 "$VPN_DIR"

# ─── 1) keypair — generate once, mirror never contains it ──────────
if [ ! -s "$VPN_DIR/privatekey" ]; then
  log "first boot: generating fresh WireGuard keypair"
  umask 077
  wg genkey > "$VPN_DIR/privatekey"
  wg pubkey < "$VPN_DIR/privatekey" > "$VPN_DIR/publickey"
  log "node public key: $(cat "$VPN_DIR/publickey")  (register this on the hub)"
fi
chmod 600 "$VPN_DIR/privatekey" "$VPN_DIR/publickey"

# ─── 2) operator peer block (hub) ──────────────────────────────────
# Precedence: persisted copy, then operator seed, then empty template.
PEERS=""
if [ -s "$VPN_DIR/peers.conf" ]; then
  PEERS="$VPN_DIR/peers.conf"
elif [ -s "$SEED_CONF" ]; then
  cp "$SEED_CONF" "$VPN_DIR/peers.conf"
  chmod 600 "$VPN_DIR/peers.conf"
  PEERS="$VPN_DIR/peers.conf"
else
  log "no hub peer configured yet — writing empty template; add a [Peer] block to"
  log "  $VPN_DIR/peers.conf  then run:  $0"
  cat > "$VPN_DIR/peers.conf" <<'EOF'
# Operator hub [Peer] block for this node. Example:
#
# [Peer]
# PublicKey = <hub-public-key>          # wg pubkey of the hub
# Endpoint  = hub.example.net:51820      # hub's public host:udp port
# AllowedIPs = 10.66.0.0/24             # mesh subnet routed via the tunnel
# PersistentKeepalive = 25
EOF
  chmod 600 "$VPN_DIR/peers.conf"
  PEERS="$VPN_DIR/peers.conf"
fi

# ─── 3) render /etc/wireguard/wg0.conf ─────────────────────────────
mkdir -p /etc/wireguard
{
  echo "[Interface]"
  echo "Address = $VGW_ADDR"
  echo "PrivateKey = $(cat "$VPN_DIR/privatekey")"
  echo ""
  cat "$PEERS"
} > /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

# ─── 4) bring the tunnel up ────────────────────────────────────────
if ip link show "$VG_IF" >/dev/null 2>&1; then
  log "$VG_IF already up"
  exit 0
fi

# kernel path
if modprobe -q wireguard 2>/dev/null || grep -qw wireguard /proc/modules 2>/dev/null; then
  log "kernel wireguard: wg-quick up $VG_IF"
  if wg-quick up "$VG_IF" 2>"$VPN_DIR/wg-quick.err"; then
    log "$VG_IF up (kernel)"
    exit 0
  fi
  log "wg-quick failed ($(tail -1 "$VPN_DIR/wg-quick.err" 2>/dev/null || true)) — trying wireguard-go"
fi

# userspace path (Wolfi kernels without the module)
if command -v wireguard-go >/dev/null 2>&1; then
  log "userspace wireguard-go up $VG_IF"
  wireguard-go "$VG_IF" >/dev/null 2>&1 &
  sleep 1
  wg setconf "$VG_IF" /etc/wireguard/wg0.conf
  ip addr add dev "$VG_IF" "$VGW_ADDR"   # yields connected 10.66.0.0/24 route
  ip link set "$VG_IF" up
  wg set "$VG_IF" listen-port 51820
  log "$VG_IF up (wireguard-go)"
  exit 0
fi

# ─── 5) image is missing wireguard tooling ─────────────────────────
log "ERROR: no wireguard transport available. Config rendered at:"
log "  /etc/wireguard/wg0.conf   keys at: $VPN_DIR"
log "Install wireguard-tools (+ wireguard-go for userspace fallback)."
exit 1