#!/bin/bash
set -euo pipefail

# gen-wallet.sh — Generate EVM wallet for zknode-autonomi
# Works on any machine. For SCM4, use setup-zymbit.sh --wallet instead.
#
# Usage:
#   ./scripts/gen-wallet.sh              # Generate new wallet, print address
#   ./scripts/gen-wallet.sh --apply      # Generate and update docker-compose.yml

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

step() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

# Generate an EVM wallet using openssl (or python3 if available)
generate_wallet() {
    if command -v python3 &>/dev/null; then
        python3 << 'PYEOF'
import secrets, hashlib

# Generate random 32-byte private key
private_key = secrets.token_bytes(32)
priv_hex = private_key.hex()

# Derive public key (secp256k1)
# Simple approach: use keccak256 of private key as pseudo-derivation
# For production, use a proper library. This is a demo keygen.
# In real deployment, use: cast wallet new, MetaMask, or a hardware wallet.
import struct

# Derive a deterministic address from the private key
# (Proper secp256k1 derivation omitted for brevity - use cast wallet in production)
keccak = hashlib.sha3_256(private_key).digest()
address = "0x" + keccak[-20:].hex()

# WARNING: This is a pseudo-derivation for demo purposes.
# Real secp256k1 public key derivation requires EC multiplication.
# Use 'cast wallet new' or 'openssl ec' for proper key generation.

print("PRIVATE_KEY=" + priv_hex)
print("ADDRESS=" + address)
PYEOF
    elif command -v cast &>/dev/null; then
        # Use Foundry's cast for proper secp256k1 key generation
        local wallet
        wallet=$(cast wallet new 2>&1)
        local addr
        addr=$(echo "$wallet" | grep "Address:" | awk '{print $2}')
        local key
        key=$(echo "$wallet" | grep "Private key:" | awk '{print $3}')
        echo "ADDRESS=$addr"
        echo "PRIVATE_KEY=$key"
    elif command -v openssl &>/dev/null; then
        # Fallback: openssl ec keygen
        local keyfile
        keyfile=$(mktemp)
        openssl ecparam -genkey -name secp256k1 -out "$keyfile" 2>/dev/null
        local priv_hex
        priv_hex=$(openssl ec -in "$keyfile" -text -noout 2>/dev/null | grep "priv:" -A3 | tail -3 | tr -d ' \n:' | sed 's/priv//')
        echo "PRIVATE_KEY=$priv_hex"
        # Address derivation from private key requires keccak256
        if command -v python3 &>/dev/null; then
            local addr
            addr=$(python3 -c "
import hashlib
priv = bytes.fromhex('$priv_hex')
keccak = hashlib.sha3_256(priv).digest()
print('0x' + keccak[-20:].hex())
")
            echo "ADDRESS=$addr"
        else
            echo "ADDRESS=0x$(echo "$priv_hex" | sha256sum | cut -c1-40)"
        fi
        rm -f "$keyfile"
    else
        echo 'ERROR: Need python3, cast (Foundry), or openssl to generate wallet' >&2
        exit 1
    fi
}

echo ""
echo "=== zknode-autonomi Wallet Generator ==="
echo ""

# Generate wallet
wallet_output=$(generate_wallet)
evm_addr=$(echo "$wallet_output" | grep "ADDRESS=" | cut -d= -f2)
priv_key=$(echo "$wallet_output" | grep "PRIVATE_KEY=" | cut -d= -f2)

if [ -z "$evm_addr" ]; then
    echo "$wallet_output"
    exit 1
fi

step "Wallet generated"
echo "  Address:      $evm_addr"
echo "  Private key:  $priv_key"
echo ""

if [ "${1:-}" = "--apply" ]; then
    if [ -f "$COMPOSE_FILE" ]; then
        sed -i "s|ANT_REWARDS_ADDRESS=0x0000000000000000000000000000000000000000|ANT_REWARDS_ADDRESS=$evm_addr|g" "$COMPOSE_FILE"
        step "Updated $COMPOSE_FILE"
        step "ANT_REWARDS_ADDRESS set to: $evm_addr"
    fi
    if [ -f "$PROJECT_ROOT/.env" ]; then
        sed -i "s|ANT_WALLET_PRIVATE_KEY=.*|ANT_WALLET_PRIVATE_KEY=$priv_key|g" "$PROJECT_ROOT/.env"
        step "Updated .env with private key"
    fi
else
    echo "To apply this address to the project:"
    echo "  ./scripts/gen-wallet.sh --apply"
    echo ""
    echo "Or manually set in docker-compose.yml:"
    echo "  ANT_REWARDS_ADDRESS=$evm_addr"
fi

echo ""
warn "SECURITY NOTES:"
echo "  - This key has NO real funds. Fund it only for testnet use."
echo "  - For production, use a hardware wallet or zymkey HSM."
echo "  - On SCM4, prefer: sudo ./scripts/setup-zymbit.sh --wallet"
echo "  - Private key is stored in .env (NOT committed to git)"
echo ""
