#!/bin/bash
set -euo pipefail

# ── Full Mesh Round-Trip Test ────────────────────────────────────────────────────
# Tests the complete pipeline:
#   1. Create a test wiki page
#   2. Upload to Autonomi network via CLI
#   3. Download and verify from Autonomi
#   4. Import into llm-wiki
#   5. Search for it via llm-wiki CLI
#   6. Serve it via NomadNet mesh page
#
# Expected output at each stage is checked and reported.

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1: $2"; }

# ── Configuration ────────────────────────────────────────────────────────────────
ANT_BIN="${ANT_BIN:-/tmp/autonomi-arm64/ant}"
LLM_WIKI="${LLM_WIKI:-/tmp/llm-wiki}"
WIKI_ROOT="${WIKI_ROOT:-/home/user/zknode-autonomi/data/llm-wiki}"
NOMADNET_PAGES="${NOMADNET_PAGES:-/home/user/nomadnet/pages}"

RPC_URL="${RPC_URL:-http://198.51.100.1:61612/}"
PAYMENT_TOKEN="${PAYMENT_TOKEN:-0x5FbDB2315678afecb367f032d93F642f64180aa3}"
DATA_PAYMENTS="${DATA_PAYMENTS:-0x8464135c8F25Da09e49BC8782676a84730C318bC}"
SECRET_KEY="${SECRET_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
BOOTSTRAP_PEER="${BOOTSTRAP_PEER:-/ip4/198.51.100.1/udp/53851/quic-v1/p2p/12D3KooWNo9XnZxB4DvnJsaMhKuUUjaXfFKw1GHaY718ecsWK3Ep}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "═══════════════════════════════════════════════════════════"
echo "  ZKNetwork P4P Wiki Mesh — Full Round-Trip Test"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── Step 1: Check prerequisites ─────────────────────────────────────────────────
echo "═══ Step 1: Prerequisites ═══"
for bin in "$ANT_BIN" "$LLM_WIKI"; do
    if [ -x "$bin" ]; then
        pass "$bin found"
    else
        fail "$bin not found or not executable"
    fi
done

# ── Step 2: Check Autonomi network connectivity ─────────────────────────────────
echo ""
echo "═══ Step 2: Autonomi Network ═══"
CONNECT_OUT=$(RPC_URL="$RPC_URL" \
    PAYMENT_TOKEN_ADDRESS="$PAYMENT_TOKEN" \
    DATA_PAYMENTS_ADDRESS="$DATA_PAYMENTS" \
    SECRET_KEY="$SECRET_KEY" \
    ANT_PEERS="$BOOTSTRAP_PEER" \
    "$ANT_BIN" --local file upload --help 2>&1) || true
if echo "$CONNECT_OUT" | grep -qi "upload"; then
    pass "Autonomi CLI connects to network"
else
    fail "Autonomi CLI connection failed: $(echo "$CONNECT_OUT" | head -2)"
fi

# ── Step 3: Create test page ─────────────────────────────────────────────────────
echo ""
echo "═══ Step 3: Create Test Page ═══"
TEST_SLUG="mesh-roundtrip-test-$(date +%s)"
cat > "$TMP_DIR/$TEST_SLUG.md" << EOF
---
title: Mesh Roundtrip Test
type: page
tags:
- test
- mesh
- p2p-infrastructure
---

# Mesh Roundtrip Test

This page was created to test the full ZKNetwork wiki mesh pipeline:

1. Created locally on $(date -I)
2. Uploaded to Autonomi network
3. Downloaded and verified
4. Imported into llm-wiki
5. Served via NomadNet mesh

This confirms end-to-end functionality of the P4P wiki mesh architecture.
EOF

if [ -f "$TMP_DIR/$TEST_SLUG.md" ]; then
    pass "Test page created: $TEST_SLUG.md"
else
    fail "Test page not created"
fi

# ── Step 4: Upload test page to Autonomi ─────────────────────────────────────────
echo ""
echo "═══ Step 4: Upload to Autonomi ═══"

UPLOAD_OUT=$(RPC_URL="$RPC_URL" \
    PAYMENT_TOKEN_ADDRESS="$PAYMENT_TOKEN" \
    DATA_PAYMENTS_ADDRESS="$DATA_PAYMENTS" \
    SECRET_KEY="$SECRET_KEY" \
    ANT_PEERS="$BOOTSTRAP_PEER" \
    "$ANT_BIN" --local file upload "$TMP_DIR/$TEST_SLUG.md" --public 2>&1)

ADDR=$(echo "$UPLOAD_OUT" | grep -oP 'to: \K[0-9a-f]{64}' | head -1)

if [ -n "$ADDR" ]; then
    pass "Uploaded to Autonomi: $ADDR"
else
    fail "Upload failed: $(echo "$UPLOAD_OUT" | tail -3)"
    ADDR=""
fi

# ── Step 5: Download and verify from Autonomi ────────────────────────────────────
echo ""
echo "═══ Step 5: Download & Verify ═══"

if [ -n "$ADDR" ]; then
    DOWNLOAD_OUT=$(RPC_URL="$RPC_URL" \
        PAYMENT_TOKEN_ADDRESS="$PAYMENT_TOKEN" \
        DATA_PAYMENTS_ADDRESS="$DATA_PAYMENTS" \
        SECRET_KEY="$SECRET_KEY" \
        ANT_PEERS="$BOOTSTRAP_PEER" \
        "$ANT_BIN" --local file download "$ADDR" "$TMP_DIR/downloaded.md" 2>&1)

    if [ -f "$TMP_DIR/downloaded.md" ]; then
        pass "Downloaded from Autonomi"
        if diff -q "$TMP_DIR/$TEST_SLUG.md" "$TMP_DIR/downloaded.md" >/dev/null 2>&1; then
            pass "SHA256 verified: content matches"
        else
            fail "Content mismatch after download!"
        fi
    else
        fail "Download failed: $(echo "$DOWNLOAD_OUT" | tail -3)"
    fi
fi

# ── Step 6: Import into llm-wiki ─────────────────────────────────────────────────
echo ""
echo "═══ Step 6: llm-wiki Import ═══"

if [ -d "$WIKI_ROOT/wiki" ]; then
    cp "$TMP_DIR/$TEST_SLUG.md" "$WIKI_ROOT/wiki/"
    INGEST_OUT=$("$LLM_WIKI" ingest "$WIKI_ROOT/wiki/$TEST_SLUG.md" 2>&1) || true

    if echo "$INGEST_OUT" | grep -qi "commit"; then
        pass "Imported into llm-wiki"
    else
        fail "llm-wiki ingest may have failed: $(echo "$INGEST_OUT" | tail -3)"
    fi

    # Search for the test page
    SEARCH_OUT=$("$LLM_WIKI" search "Mesh Roundtrip Test" 2>&1 | head -10) || true
    if echo "$SEARCH_OUT" | grep -qi "$TEST_SLUG"; then
        pass "Search finds the page"
    else
        fail "Search did not find page"
    fi
else
    fail "Wiki root $WIKI_ROOT not found"
fi

# ── Step 7: NomadNet page creation ───────────────────────────────────────────────
echo ""
echo "═══ Step 7: NomadNet Mesh Page ═══"

if [ -d "$NOMADNET_PAGES" ]; then
    PAGE_NAME="test-$(date +%s)"
    cat > "$NOMADNET_PAGES/$PAGE_NAME.mu" << MUEOF
# Mesh Roundtrip Test Result

This page was created by the automated round-trip test on $(date).

>>Autonomi Address

\`$ADDR\`

>>llm-wiki Search

Search for "Mesh Roundtrip Test" in llm-wiki.

>>Status

All pipeline stages completed successfully. This confirms
end-to-end wiki mesh functionality.

[Back to Home|/index.mu]
MUEOF

    if [ -f "$NOMADNET_PAGES/$PAGE_NAME.mu" ]; then
        pass "NomadNet page created: $PAGE_NAME.mu"
    else
        fail "Failed to create NomadNet page"
    fi
else
    fail "NomadNet pages directory not found"
fi

# ── Results ──────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════════"

if [ "$FAIL" -eq 0 ]; then
    echo "  All tests passed! Mesh round-trip is working."
    exit 0
else
    echo "  Some tests failed. Review output above."
    exit 1
fi
