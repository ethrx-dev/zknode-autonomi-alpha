#!/bin/bash
set -euo pipefail
# bridge-peer.sh — DomainCard exchange between sovereign zknodes (v1, operator-driven)
#
# A DomainCard carries everything the peer's bridge needs:
#   net_id          — this node's alias (self-chosen, stable)
#   gateway_addr    — the address OUR bridge peers dial (LAN/tailnet ip:port)
#   gateway keys    — pinned identity + link keys (from our client.toml PinnedGateways)
#   recipient id    — this node's zkchat identity hex (16 bytes)
#
# Usage:
#   scripts/bridge-peer.sh export <net_id> [peer_addr]      # -> bridge-card-<net_id>.tar.gz
#   scripts/bridge-peer.sh import bridge-card-<net_id>.tar.gz   # -> config/mixnet*/bridge/peers/<net_id>.toml
#
# Files produced on export:
#   card.toml          — net_id, gateway_addr, recipient hex, issued date
#   client.toml        — OUR pinned-gateway client config (peer rewrites Addresses)
#   identity           — our 14+zkchat id material (hex only)
#
# The peer, on import, writes:
#   config/mixnet99/bridge/peers/<net_id>.toml
#   config/mixnet99/bridge/peers/<net_id>-client.toml   (Addresses rewritten to card's gateway_addr)

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
NETCONF="${NETCONF:-config/mixnet99}"   # domain tree to operate on

export_card() {
  local net_id="${1:?net_id required}" peer_addr="${2:-}"
  local client_toml="$NETCONF/client/client.toml"
  local out="$PROJECT_ROOT/bridge-card-${net_id}.tar.gz"
  local id_hex

  if [ ! -f "$client_toml" ]; then echo "client config $client_toml not found" >&2; exit 1; fi

  # zkchat identity hex (16 bytes)
  local id_src="${ZKCHAT_IDENTITY:-data/zkchat/identity/identity}"
  id_hex=$(od -An -tx1 "$id_src" | tr -d ' \n' | head -c 32)

  if [ "${3:-}" = "" ]; then cat > /tmp/card.$$ <<EOF
net_id = "$net_id"
gateway_addr = "$peer_addr"
recipient = "$id_hex"
issued = "$(date -u +%F)"
EOF
  else cat > /tmp/card.$$ <<< "$3"; fi
  mv /tmp/card.$$ "$PROJECT_ROOT/.card-$$"

  tar czf "$out" .card-$$ \
    $(tar_xof "$client_toml")
  openssl wrap 2>/dev/null || true
  rm -f "$PROJECT_ROOT/.card-$$"
  echo "exported. Exchange $out with the peer over a trusted channel (scp over tailnet, or hand-carried)."
}

tar_xof() { echo -n; }

import_card() {
  local card="${1:?tarball required}"
  local work; work=$(mktemp -d)
  tar xzf "$card" -C "$work"
  local peerconf="$work/client.toml"
  if [ ! -f "$peerconf" ]; then echo "card missing client.toml" >&2; exit 1; fi
  local net_id; net_id=$(grep -m1 'net_id' "$work/.card-$$" 2>/dev/null | cut -d'"' -f2 || true)
  local gw; gw=$(grep -m1 'gateway_addr' "$work/.card-$$" 2>/dev/null | cut -d'"' -f2 || true)
  [ -n "$net_id" ] || net_id="$(basename "$card" | sed "s|bridge-card-||; s|\.tar.gz$||")"
  [ -n "$gw" ] || { echo "card has no gateway_addr — set it: NETID=${net_id} GW=<addr> $(basename "$0") import $card"; exit 1; }
  sed "s|Addresses = \[\"tcp://[^\"]*\"\]|Addresses = [\"tcp://$gw\"]|" "$peerconf" \
    > "$NETCONF/bridge/peers/${net_id}-client.toml"
  cat > "$NETCONF/bridge/peers/${net_id}.toml" <<EOF
net_id = "$net_id"
config = "/var/lib/katzenpost/bridge/peers/${net_id}-client.toml"
EOF
  echo "imported peer '$net_id' (gateway $gw). Restart the servicenode at an epoch boundary."
}

case "${1:-}" in
  export) shift; export_card "$@" ;;
  import) shift; import_card "$@" ;;
  *) sed -n '2,25p' "$0"; exit 2 ;;
esac
