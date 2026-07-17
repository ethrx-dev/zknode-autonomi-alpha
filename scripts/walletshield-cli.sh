#!/bin/bash
set -euo pipefail

# walletshield-cli — Metadata-protected EVM RPC through the mixnet
#
# Connects to the node's walletshield API through the mixnet SOCKS5 proxy
# so that all traffic is metadata-private (IP, timing, etc. are hidden
# by the post-quantum mixnet).
#
# Usage:
#   ./walletshield-cli.sh <command> [args...]
#
# Commands:
#   proxy              Start local HTTP proxy 127.0.0.1:${LOCAL_PORT:-9999}
#                      Forward browser/wallet traffic through the mixnet.
#   block              Get latest block number
#   balance <addr>     Get ETH balance for address
#   probe              Send test probes through mixnet to walletshield
#   rpc <method> [params]  Generic JSON-RPC call
#   status             Show walletshield and proxy connectivity
#   env                Print SOCKS5 proxy environment variables

# ── Configuration ──────────────────────────────────────────────────────────
NODE="${NODE:-zknode.local}"           # Node hostname or IP
SOCKS_PORT="${SOCKS_PORT:-1080}"       # Mixnet SOCKS5 proxy port
WALLETSHIELD_PORT="${WALLETSHIELD_PORT:-9200}"  # walletshield HTTP API port
LOCAL_PORT="${LOCAL_PORT:-9999}"       # Local HTTP proxy port (proxy command)
RPC_URL="${RPC_URL:-http://${NODE}:${WALLETSHIELD_PORT}}"
SOCKS5="socks5h://${NODE}:${SOCKS_PORT}"

# ── Helpers ────────────────────────────────────────────────────────────────
json_rpc() {
    local method="$1"
    local params="${2:-}"
    [ -z "$params" ] && params="[]"
    curl --silent --max-time 30 \
        --proxy "$SOCKS5" \
        -X POST "$RPC_URL" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params},\"id\":1}"
}

die() { echo "error: $*" >&2; exit 1; }

# ── Commands ───────────────────────────────────────────────────────────────

cmd_proxy() {
    echo "Starting local HTTP proxy on 127.0.0.1:${LOCAL_PORT}"
    echo "Forwarding through mixnet SOCKS5: ${SOCKS5}"
    echo "→ walletshield: ${RPC_URL}"
    echo ""
    echo "Configure your browser or wallet to use:"
    echo "  HTTP Proxy: 127.0.0.1:${LOCAL_PORT}"
    echo ""
    echo "All requests are tunneled through the post-quantum mixnet."
    echo "Press Ctrl+C to stop."
    echo ""

    # Simple TCP forwarder: local → SOCKS5 → node:walletshield_port
    # Uses nc to relay, restarts on failure
    while true; do
        nc -lk -p "$LOCAL_PORT" -e /bin/sh -c "
            while IFS= read -r line; do
                echo \"\$line\"
            done | curl --proxy '$SOCKS5' -X POST '$RPC_URL' -H 'Content-Type: application/json' -d @-
        " 2>/dev/null || {
            echo "warning: nc relay failed, retrying in 2s..." >&2
            sleep 2
        }
    done
}

cmd_block() {
    echo "Latest block number:"
    json_rpc "eth_blockNumber" | grep -oP '"result":"\K[^"]+' | while read -r hex; do
        printf "%d (0x%s)\n" "$((16#${hex#0x}))" "${hex#0x}"
    done
}

cmd_balance() {
    local addr="${1:-}"
    [ -z "$addr" ] && die "usage: walletshield-cli.sh balance <0xADDRESS>"
    echo "ETH balance for ${addr}:"
    json_rpc "eth_getBalance" "[\"${addr}\",\"latest\"]" | grep -oP '"result":"\K[^"]+' | while read -r hex; do
        printf "%s wei (%s ETH)\n" "$hex" "$(echo "scale=18; $((16#${hex#0x})) / 10^18" | bc 2>/dev/null || echo "?")"
    done
}

cmd_rpc() {
    local method="${1:-}"
    [ -z "$method" ] && die "usage: walletshield-cli.sh rpc <method> [params_json]"
    local params="${2:-[]}"
    json_rpc "$method" "$params"
}

cmd_probe() {
    echo "Sending 3 test probes through mixnet to walletshield..."
    echo ""
    local transmitted=0 received=0
    for i in 1 2 3; do
        transmitted=$((transmitted + 1))
        echo -n "  Probe $i: "
        local start
        start=$(date +%s%N)
        if json_rpc "eth_blockNumber" >/dev/null 2>&1; then
            received=$((received + 1))
            local elapsed
            elapsed=$(echo "scale=3; ($(date +%s%N) - $start) / 1000000000" | bc)
            echo "OK (${elapsed}s)"
        else
            echo "FAIL"
        fi
        [ "$i" -lt 3 ] && sleep 2
    done
    local loss=0
    [ "$transmitted" -gt 0 ] && loss=$(( (transmitted - received) * 100 / transmitted ))
    echo ""
    echo "  ${transmitted} transmitted, ${received} received, ${loss}% loss"
}

cmd_status() {
    echo "walletshield-cli connectivity"
    echo "============================="
    echo ""

    # Check SOCKS5 proxy
    echo -n "SOCKS5 proxy (${NODE}:${SOCKS_PORT}): "
    if curl --silent --max-time 5 --proxy "$SOCKS5" http://${NODE}:${WALLETSHIELD_PORT} \
        -X POST -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' >/dev/null 2>&1; then
        echo "OK"
    else
        echo "FAIL"
    fi

    # Show latest block
    echo ""
    cmd_block 2>&1 || echo "  (unreachable)"

    # Show proxy env
    echo ""
    echo "Proxy environment (for tools that support HTTP_PROXY):"
    echo "  HTTP_PROXY=${SOCKS5}"
    echo "  HTTPS_PROXY=${SOCKS5}"
    echo "  ALL_PROXY=${SOCKS5}"
    echo ""
    echo "RPC endpoint:"
    echo "  ETH_RPC_URL=${RPC_URL}"
}

cmd_env() {
    echo "# Add these to your shell or .env:"
    echo "export NODE='${NODE}'"
    echo "export SOCKS_PORT='${SOCKS_PORT}'"
    echo "export WALLETSHIELD_PORT='${WALLETSHIELD_PORT}'"
    echo ""
    echo "# Proxy variables (for curl, httpie, etc.):"
    echo "export HTTP_PROXY='${SOCKS5}'"
    echo "export HTTPS_PROXY='${SOCKS5}'"
    echo "export ALL_PROXY='${SOCKS5}'"
    echo ""
    echo "# RPC endpoint:"
    echo "export ETH_RPC_URL='${RPC_URL}'"
    echo ""
    echo "# Connect using curl directly:"
    echo "curl --proxy '${SOCKS5}' -X POST '${RPC_URL}' \\"
    echo "  -H 'Content-Type: application/json' \\"
    echo "  -d '{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}'"
}

# ── Main ───────────────────────────────────────────────────────────────────
cmd="${1:-help}"
shift 2>/dev/null || true

case "$cmd" in
    proxy)    cmd_proxy "$@" ;;
    block)    cmd_block "$@" ;;
    balance)  cmd_balance "$@" ;;
    rpc)      cmd_rpc "$@" ;;
    probe)    cmd_probe "$@" ;;
    status)   cmd_status "$@" ;;
    env)      cmd_env "$@" ;;
    help|--help|-h)
        sed -n '3,/^$/p' "$0" | sed 's/^# //;s/^#$//'
        ;;
    *)
        echo "unknown command: $cmd"
        echo "usage: walletshield-cli.sh <command> [args]"
        echo "  try: walletshield-cli.sh help"
        exit 1
        ;;
esac
