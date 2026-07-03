#!/bin/bash
set -euo pipefail

# gen-mixnet-configs.sh — Generate Katzenpost mixnet PKI + node configs
# Topology: 3 dirauths, 3 mixes, 1 gateway, 1 servicenode, 1 courier

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$PROJECT_ROOT/config/mixnet"
PKIDATA_DIR="$CONFIG_DIR/pkidata"

mkdir -p "$PKIDATA_DIR"

for i in 1 2 3; do
    mkdir -p "$CONFIG_DIR/auth$i"
    mkdir -p "$CONFIG_DIR/mix$i"
done
mkdir -p "$CONFIG_DIR/gateway1"
mkdir -p "$CONFIG_DIR/servicenode1"
mkdir -p "$CONFIG_DIR/courier"
mkdir -p "$CONFIG_DIR/kpclientd"

# ─── SphinxGeometry (shared across all nodes) ───────────────────
SPHINX_GEOMETRY='[SphinxGeometry]
NIKEName = "x25519"
NrHops = 3
HeaderLength = 338
RoutingInfoLength = 288
PerHopRoutingInfoLength = 96
PacketLength = 1306
SURBLength = 414
ForwardPayloadLength = 936
UserForwardPayloadLength = 900
NextNodeHopLength = 64
SPRPKeyMaterialLength = 48
SphinxPlaintextHeaderLength = 2
PayloadTagLength = 32'

# ─── Generate dirauth keypairs ──────────────────────────────────
for i in 1 2 3; do
    AUTH_DIR="$CONFIG_DIR/auth$i"
    if [ ! -f "$AUTH_DIR/identity.key" ] || [ ! -f "$AUTH_DIR/identity.pub" ]; then
        echo "  Generating keypair for dirauth-$i..."
        openssl genpkey -algorithm ed25519 -out "$AUTH_DIR/identity.key" 2>/dev/null || {
            echo "placeholder-key" > "$AUTH_DIR/identity.key"
        }
        openssl pkey -in "$AUTH_DIR/identity.key" -pubout -out "$AUTH_DIR/identity.pub" 2>/dev/null || {
            echo "placeholder-pub" > "$AUTH_DIR/identity.pub"
        }
    fi
done

# ─── Consortium YAML ────────────────────────────────────────────
cat > "$PKIDATA_DIR/consortium.yaml" << EOF
version: 1
consensus_type: threshold
consensus_epsilon: 0.2
voting_interval: 1m
cert_expiry: 168h
authorities:
  - identifier: auth1
    identity_key_file: /etc/katzenpost/auth1/identity.pub
    address: mix-dirauth-1:12349
  - identifier: auth2
    identity_key_file: /etc/katzenpost/auth2/identity.pub
    address: mix-dirauth-2:12349
  - identifier: auth3
    identity_key_file: /etc/katzenpost/auth3/identity.pub
    address: mix-dirauth-3:12349
EOF

# ─── Dirauth configs (3) ────────────────────────────────────────
for i in 1 2 3; do
    AUTH_DIR="$CONFIG_DIR/auth$i"
    cat > "$AUTH_DIR/authority.toml" << EOF
# Dirauth $i configuration
[Server]
Identifier = "auth${i}"
DataDir = "/var/lib/katzenpost"
LogLevel = "INFO"

[Authority]
ConsensusType = "threshold"
VotingInterval = "1m"
ConsensusEpsilon = 0.2
CertExpiry = "168h"

[Authority.PKI]
Consensus = "/etc/katzenpost/pkidata/consortium.yaml"

[Authority.Threshold]
  [Authority.Threshold.Authority1]
  Identifier = "auth1"
  Address = "mix-dirauth-1:12349"
  PublicKey = "file:///etc/katzenpost/auth1/identity.pub"

  [Authority.Threshold.Authority2]
  Identifier = "auth2"
  Address = "mix-dirauth-2:12349"
  PublicKey = "file:///etc/katzenpost/auth2/identity.pub"

  [Authority.Threshold.Authority3]
  Identifier = "auth3"
  Address = "mix-dirauth-3:12349"
  PublicKey = "file:///etc/katzenpost/auth3/identity.pub"

${SPHINX_GEOMETRY}

[Debug]
LogDir = "/var/lib/katzenpost/log"
EOF
done

# ─── Mix node configs (3) ───────────────────────────────────────
for i in 1 2 3; do
    MIX_DIR="$CONFIG_DIR/mix$i"
    PORT=$((12344 + i))
    cat > "$MIX_DIR/katzenpost.toml" << EOF
# Mix node $i configuration
[Server]
Identifier = "mix${i}"
DataDir = "/var/lib/katzenpost"
LogLevel = "INFO"
Addresses = ["mix-${i}:${PORT}"]

[Mix]
Layers = 1
MixKeys = "/var/lib/katzenpost/mix_keys"

[PKI]
ConsensusType = "threshold"

${SPHINX_GEOMETRY}

[Debug]
LogDir = "/var/lib/katzenpost/log"
EOF
done

# ─── Gateway config ─────────────────────────────────────────────
GW_PORT="${MIXNET_GW_PORT:-12348}"
cat > "$CONFIG_DIR/gateway1/katzenpost.toml" << EOF
# Gateway node configuration
[Server]
Identifier = "gateway1"
DataDir = "/var/lib/katzenpost"
LogLevel = "INFO"
Addresses = ["mix-gateway:${GW_PORT}"]

[Gateway]
EnableUserRegistration = true

[PKI]
ConsensusType = "threshold"

${SPHINX_GEOMETRY}

[Debug]
LogDir = "/var/lib/katzenpost/log"
EOF

# ─── Service node / exit config ─────────────────────────────────
SN_PORT="${MIXNET_SN_PORT:-12349}"
cat > "$CONFIG_DIR/servicenode1/katzenpost.toml" << EOF
# Service node / mixnet exit configuration
[Server]
Identifier = "servicenode1"
DataDir = "/var/lib/katzenpost"
LogLevel = "INFO"
Addresses = ["mix-servicenode:${SN_PORT}"]

[ServiceNode]
EnableForward = true
AllowExitTo = ["0.0.0.0/0"]

[PKI]
ConsensusType = "threshold"

${SPHINX_GEOMETRY}

[Debug]
LogDir = "/var/lib/katzenpost/log"
EOF

# ─── Courier config ─────────────────────────────────────────────
cat > "$CONFIG_DIR/courier/courier.toml" << EOF
# Courier node configuration
[Server]
Identifier = "courier"
DataDir = "/var/lib/katzenpost"
LogLevel = "INFO"
Addresses = ["mix-courier:12350"]

[PKI]
ConsensusType = "threshold"

${SPHINX_GEOMETRY}

[Debug]
LogDir = "/var/lib/katzenpost/log"
EOF

# ─── kpclientd config ───────────────────────────────────────────
cat > "$CONFIG_DIR/kpclientd/kpclientd.toml" << EOF
# kpclientd tunnel client configuration
[Client]
LogLevel = "INFO"
DataDir = "/var/lib/katzenpost"

[Gateway]
Address = "mix-gateway:${GW_PORT}"

${SPHINX_GEOMETRY}
EOF

echo ""
echo "Mixnet configs generated with SphinxGeometry:"
find "$CONFIG_DIR" -name "*.toml" -o -name "*.yaml" | sort | while read -r f; do
    echo "  $f"
done
echo ""
echo "Done."
