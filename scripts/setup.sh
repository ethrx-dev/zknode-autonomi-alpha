#!/bin/bash
set -euo pipefail

# setup.sh — Initialize zknode-autonomi project structure
# Creates configs via genconfig, sets up data directories, fixes permissions

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

if [ -f .env ]; then
    set -a; source .env; set +a
fi

echo "=== zknode-autonomi setup ==="
echo ""

echo "[1/4] Verifying prerequisites..."
if ! command -v docker &>/dev/null; then
    echo "ERROR: docker not found."
    exit 1
fi
echo "  docker: $(docker --version)"
echo ""

echo "[2/4] Creating data directories..."
mkdir -p data/mixnet data/antd data/proxy data/zymbit

# USB pool fallback
TRINITY_MOUNT="${TRINITY_MOUNT:-/mnt/trinity}"
if [ -d "$TRINITY_MOUNT" ]; then
    echo "  USB pool found at $TRINITY_MOUNT"
    mkdir -p "$TRINITY_MOUNT/autonomi/chunks"
    mkdir -p "$TRINITY_MOUNT/autonomi/logs"
    mkdir -p "$TRINITY_MOUNT/backup"
else
    echo "  USB pool not found — using local fallback ./data/"
    mkdir -p data/chunks data/logs
fi
echo ""

echo "[3/4] Generating mixnet configs (genconfig)..."
mkdir -p config/mixnet config/proxy config/autonomi config/walletshield

# Use genconfig to generate proper Katzenpost configs
docker run --rm --platform linux/arm64 \
    -v "$(pwd)/config/mixnet:/out" \
    "${IMAGE_MIXNET}" \
    /usr/local/bin/genconfig \
        --voting --wirekem MLKEM768 --nike x25519 \
        --baseDir /var/lib/katzenpost --outDir /out \
        --layers 3 --nodes 3 --gateways 1 --serviceNodes 1 \
        --nrVoting 3 --noMetrics --logLevel DEBUG 2>&1 | tail -3

# Fix ownership to current user
OWNER=$(stat -c "%u:%g" .env 2>/dev/null || echo "1000:1000")
docker run --rm --platform linux/arm64 \
    -v "$(pwd)/config/mixnet:/out" \
    "${IMAGE_MIXNET}" \
    sh -c "chown -R $OWNER /out/"

# Fix servicenode: disable CBOR plugins only
sed -i "s|Command = \"/var/lib/katzenpost/courier\"|Command = \"/usr/local/bin/courier\"|g" config/mixnet/servicenode1/katzenpost.toml 2>/dev/null || true
sed -i "s|Command = \"/var/lib/katzenpost/proxy_server\"|Command = \"/usr/local/bin/http-proxy-server\"|g" config/mixnet/servicenode1/katzenpost.toml 2>/dev/null || true
sed -i "/\[ServiceNode\.CBORPluginKaetzchen\]/,/^$/ { /Disable = false/ s/Disable = false/Disable = true/ }" config/mixnet/servicenode1/katzenpost.toml 2>/dev/null || true

# Fix data directory permissions (katzenpost requires 700)
for d in config/mixnet/auth1 config/mixnet/auth2 config/mixnet/auth3 \
         config/mixnet/mix1 config/mixnet/mix2 config/mixnet/mix3 \
         config/mixnet/gateway1 config/mixnet/servicenode1 \
         config/mixnet/replica*; do
    [ -d "$d" ] && chmod 700 "$d" 2>/dev/null || true
done

echo "  Mixnet configs generated and fixed"
echo ""

echo "[4/4] Creating runtime configs..."

# Proxy config — uses host networking (127.0.0.1)
cat > config/proxy/config.json << EOF
{
  "listen_addr": "0.0.0.0:1080",
  "socks_addr": "0.0.0.0:1080",
  "mgmt_addr": "0.0.0.0:9090",
  "mixnet_gateway": "127.0.0.1:30004",
  "wireguard_iface": "wg0",
  "ant_node_addr": "10.0.0.2"
}
EOF

# Autonomi node config
[ -f config/autonomi/node.toml ] || cat > config/autonomi/node.toml << EOF
# Autonomi ant-node configuration
[network]
evm_network = "${AUTONOMI_EVM_NETWORK:-arbitrum-sepolia}"

[storage]
root_dir = "/var/lib/ant-node"
chunk_store = "/var/lib/ant-node/chunks"
EOF

# Autonomi CLI config
[ -f config/autonomi/antd.toml ] || cat > config/autonomi/antd.toml << EOF
# ant CLI configuration
[server]
ant_node_endpoint = "ant-node:${ANT_NODE_PORT:-12000}"
EOF

echo "  config/proxy/config.json"
echo "  config/autonomi/node.toml"
echo "  config/autonomi/antd.toml"
echo ""

echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  ./scripts/deploy.sh --start"
echo ""
echo "Or build images first:"
echo "  docker build --build-arg TARGETARCH=$TARGETARCH -f Dockerfile.mixnet -t $IMAGE_MIXNET ."
echo "  docker build --build-arg TARGETARCH=$TARGETARCH -f Dockerfile.ant-node -t $IMAGE_ANT_NODE ."
echo "  docker build --build-arg TARGETARCH=$TARGETARCH -f Dockerfile.antd -t $IMAGE_ANTD ."
echo "  docker build --build-arg TARGETARCH=$TARGETARCH -f Dockerfile.mixnet-proxy -t $IMAGE_MIXNET_PROXY ."
