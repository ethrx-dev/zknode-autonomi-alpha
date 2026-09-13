#!/usr/bin/env bash
# vpn-test.sh — local, no-root, end-to-end test of the VPN overlay.
# Runs two throwaway WireGuard endpoints in Docker (NET_ADMIN only):
#   hub  -> static test keypair, acts as the mesh hub (10.66.0.1)
#   node -> runs the real vpn-provision.sh against a scratch PERSIST dir,
#           generates its keypair on first boot, dials the hub, pings.
# Prereqs: docker (no root/sudo needed). Image: alpine:3.20 (small).
# Exit 0 = tunnel verified; 77 = skipped (no docker / no wg in image).
set -u
SKIP=77; FAIL=1
trap 'docker rm -f zknode-vpn-hub zknode-vpn-node >/dev/null 2>&1 || true; \
      rm -rf "${WORK:-/tmp/zknode-vpn-empty}"' EXIT

command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not available"; exit $SKIP; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PROVISIONER="$ROOT/scripts/vpn/vpn-provision.sh"
[ -x "$PROVISIONER" ] || { echo "FAIL: vpn-provision.sh missing"; exit $FAIL; }

WORK="$(mktemp -d /tmp/zknode-vpn.XXXXXX)"
echo "== work dir: $WORK =="

# Use alpine:3.20 — smallest image, wireguard-tools via apk, cached locally.
IMG=alpine:3.20
echo "== image: $IMG =="

CEP="docker exec"

# ─── hub ──────────────────────────────────────────────────────────
docker run -d --name zknode-vpn-hub --cap-add NET_ADMIN \
  alpine:3.20 sh -c '
    apk add --no-cache wireguard-tools iproute2 iputils >/dev/null 2>&1
    umask 077
    wg genkey > /hub.key; wg pubkey < /hub.key > /hub.pub
    ip link add dev wg0 type wireguard
    wg set wg0 private-key /hub.key listen-port 51820
    ip address add dev wg0 10.66.0.1/24
    ip link set wg0 up
    echo "HUB_PUB=$(cat /hub.pub)"
    wg show
    sleep 3600
  ' >/dev/null 2>&1
rc=$?; [ $rc -eq 0 ] || { echo "FAIL: hub container start"; exit $FAIL; }

# wait for hub wireguard to be ready
for i in $(seq 1 30); do
  $CEP zknode-vpn-hub sh -c '[ -f /hub.key ] && ip link show wg0 >/dev/null 2>&1' 2>/dev/null && break
  sleep 1
done

HUB_PUB=$($CEP zknode-vpn-hub sh -c 'cat /hub.pub' 2>/dev/null)
HUB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' zknode-vpn-hub 2>/dev/null)
echo "== hub pub=$HUB_PUB ip=$HUB_IP =="
[ -n "$HUB_PUB" ] && [ -n "$HUB_IP" ] || { echo "FAIL: hub keys/ip unavailable"; exit $FAIL; }

# ─── node: run the real provisioner ───────────────────────────────
# PERSIST scratch dir is mounted, seeded with the hub peer block.
PERSIST="$WORK/persist"
mkdir -p "$PERSIST/vpn"
cat > "$PERSIST/vpn/peers.conf" <<EOF
[Peer]
PublicKey = $HUB_PUB
Endpoint  = $HUB_IP:51820
AllowedIPs = 10.66.0.0/24
PersistentKeepalive = 25
EOF

docker run -d --name zknode-vpn-node --cap-add NET_ADMIN \
  -e PERSIST=/persist \
  -v "$PERSIST:/persist" \
  -v "$PROVISIONER:/usr/local/sbin/vpn-provision.sh:ro" \
  alpine:3.20 sh -c '
    apk add --no-cache wireguard-tools iproute2 iputils >/dev/null 2>&1
    /usr/local/sbin/vpn-provision.sh
    echo "NODE_PUB=$(cat /persist/vpn/publickey)"
    sleep 3600
  ' >/dev/null 2>&1
rc=$?; [ $rc -eq 0 ] || { echo "FAIL: node container start"; exit $FAIL; }

# wait for provisioner to bring wg0 up
for i in $(seq 1 30); do
  $CEP zknode-vpn-node sh -c '[ -e /persist/vpn/privatekey ] && ip link show wg0 >/dev/null 2>&1' 2>/dev/null && break
  sleep 1
done

$CEP zknode-vpn-node sh -c 'ip link show wg0' >/dev/null 2>&1 \
  || { echo "FAIL: node wg0 not up"; $CEP zknode-vpn-node sh -c 'ls -la /persist/vpn/; cat /persist/vpn/peers.conf'; exit $FAIL; }

# first-boot keygen must have happened
# shellcheck disable=SC2016
NODE_PUB=$($CEP zknode-vpn-node sh -c 'cat /persist/vpn/publickey' 2>/dev/null)
[ -n "$NODE_PUB" ] || { echo "FAIL: provisioner did not generate a keypair"; exit $FAIL; }

# ─── register node on hub (real-world: operator admits the node's
#     first-boot key against the hub), then verify handshake + ping ─
echo "== node pub=$NODE_PUB — registering on hub, waiting for handshake =="
$CEP zknode-vpn-hub sh -c "wg set wg0 peer '$NODE_PUB' allowed-ips 10.66.0.2/32" >/dev/null 2>&1

ok=0
for i in $(seq 1 30); do
  ts=$($CEP zknode-vpn-node sh -c 'wg show wg0 latest-handshakes' 2>/dev/null | awk 'NF>1 {print $2}')
  [ -n "$ts" ] && [ "$ts" != "0" ] && ok=1 && break
  sleep 1
done
[ $ok -eq 1 ] || { echo "FAIL: no handshake"; $CEP zknode-vpn-node sh -c 'wg show'; exit $FAIL; }
echo "== handshake established =="

if $CEP zknode-vpn-hub sh -c 'ping -c 3 -W 2 10.66.0.2' 2>/dev/null | grep -q ' 0% packet loss\|3 received'; then
  echo "PASS: 10.66.0.2 reachable through WireGuard tunnel"
else
  echo "FAIL: ping via tunnel failed"
  $CEP zknode-vpn-hub sh -c 'wg show; echo ---; ip route' 2>/dev/null
  exit $FAIL
fi

echo "== artifact check: keys persisted under /persist/vpn =="
$CEP zknode-vpn-node sh -c 'ls -l /persist/vpn/privatekey /persist/vpn/publickey; stat -c "%a %n" /persist/vpn/privatekey' 2>/dev/null

echo "PASS: vpn-provision.sh binds, keygens, and tunnels end-to-end"
exit 0