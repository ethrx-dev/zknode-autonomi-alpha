#!/bin/bash
set -euo pipefail

# Autonomi ↔ llm-wiki Sync Script
# Downloads wiki archive from Autonomi network, extracts to llm-wiki, and reindexes.
# Designed to run as a systemd timer (e.g., hourly) or on-demand via REST API.

# ── Configuration ──────────────────────────────────────────────────────────────
LLM_WIKI_BIN="${LLM_WIKI_BIN:-/tmp/llm-wiki}"
ANT_BIN="${ANT_BIN:-/tmp/autonomi-arm64/ant}"
WIKI_ROOT="${WIKI_ROOT:-/home/user/zknode-autonomi/data/llm-wiki}"
WIKI_NAME="${WIKI_NAME:-p2p-foundation}"

# Autonomi network config
AUTONOMI_ADDR="${AUTONOMI_ADDR:-6c6fc79cd7e1553cbd1226c220c18fdca2a5b7f731a5b748fd5d1034a0082848}"
RPC_URL="${RPC_URL:-http://198.51.100.1:61612/}"
PAYMENT_TOKEN="${PAYMENT_TOKEN:-0x5FbDB2315678afecb367f032d93F642f64180aa3}"
DATA_PAYMENTS="${DATA_PAYMENTS:-0x8464135c8F25Da09e49BC8782676a84730C318bC}"
SECRET_KEY="${SECRET_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
BOOTSTRAP_PEER="${BOOTSTRAP_PEER:-/ip4/198.51.100.1/udp/53851/quic-v1/p2p/12D3KooWNo9XnZxB4DvnJsaMhKuUUjaXfFKw1GHaY718ecsWK3Ep}"

# ── Runtime ─────────────────────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

log() { echo "[$(date -Iseconds)] $*"; }
error() { log "ERROR: $*" >&2; }

# ── Ensure llm-wiki wiki space exists ───────────────────────────────────────────
ensure_wiki() {
    if ! "$LLM_WIKI_BIN" spaces list 2>/dev/null | grep -q "$WIKI_NAME"; then
        log "Creating wiki space '$WIKI_NAME' at $WIKI_ROOT"
        mkdir -p "$WIKI_ROOT"
        "$LLM_WIKI_BIN" spaces create --name "$WIKI_NAME" --description "P2P Foundation Wiki (Autonomi-synced)" --set-default "$WIKI_ROOT"
    else
        log "Wiki space '$WIKI_NAME' exists"
    fi
}

# ── Download from Autonomi ──────────────────────────────────────────────────────
download_from_autonomi() {
    local archive="$TMP_DIR/wiki.tar.gz"
    log "Downloading wiki archive from Autonomi: $AUTONOMI_ADDR"

    RPC_URL="$RPC_URL" \
    PAYMENT_TOKEN_ADDRESS="$PAYMENT_TOKEN" \
    DATA_PAYMENTS_ADDRESS="$DATA_PAYMENTS" \
    SECRET_KEY="$SECRET_KEY" \
    ANT_PEERS="$BOOTSTRAP_PEER" \
        "$ANT_BIN" --local file download "$AUTONOMI_ADDR" "$archive" >/dev/null 2>&1

    if [ ! -f "$archive" ]; then
        error "Download failed: archive not found"
        return 1
    fi

    log "Downloaded $(stat -c%s "$archive") bytes"
}

# ── Extract and copy to wiki root ───────────────────────────────────────────────
sync_wiki_files() {
    local archive="$1"
    local extract="$TMP_DIR/wiki-extract"
    mkdir -p "$extract"

    log "Extracting archive"
    tar xzf "$archive" -C "$extract"

    local count
    count=$(find "$extract" -name '*.md' -type f | wc -l)
    log "Found $count markdown files"

    log "Copying to wiki root: $WIKI_ROOT/wiki/"
    mkdir -p "$WIKI_ROOT/wiki"
    cp "$extract"/*.md "$WIKI_ROOT/wiki/" 2>/dev/null || true

    local copied
    copied=$(find "$WIKI_ROOT/wiki" -name '*.md' -type f | wc -l)
    log "Wiki now has $copied pages"
}

# ── Rebuild search index ────────────────────────────────────────────────────────
rebuild_index() {
    log "Rebuilding tantivy search index"
    "$LLM_WIKI_BIN" index rebuild --wiki "$WIKI_NAME" 2>&1 | tail -5
    log "Index rebuild complete"

    log "Ingesting any new files"
    "$LLM_WIKI_BIN" ingest "$WIKI_ROOT/wiki/" 2>&1 | tail -3
    log "Ingestion complete"
}

# ── Update NomadNet archive page ────────────────────────────────────────────────
update_nomadnet_page() {
    local pages_dir="${NOMADNET_PAGES_DIR:-/home/user/nomadnet/pages}"
    local archive_page="$pages_dir/archive.mu"

    if [ -f "$archive_page" ]; then
        log "Updating NomadNet archive page with current address"
        local page_count
        page_count=$(find "$WIKI_ROOT/wiki" -name '*.md' -type f | wc -l)
        local current_date
        current_date=$(date -I)

        cat > "$archive_page" << MUEOF
# Wiki Archives on Autonomi

The P2P Foundation wiki is archived on the Autonomi network.
Each snapshot is stored as a content-addressed archive with
permanent availability.

>>Latest Archive

* Snapshot date: $current_date
* Content: $page_count markdown pages
* Autonomi address: \`$AUTONOMI_ADDR\`
* Access: \`ant file download $AUTONOMI_ADDR --output wiki.tar.gz\`

>>How to Access

1. Install the Autonomi CLI: \`pip install autonomi-cli\`
2. Set your SECRET_KEY and EVM network
3. Download from address:
   \`\`\`
   ant file download $AUTONOMI_ADDR -o wiki.tar.gz
   tar xzf wiki.tar.gz
   \`\`\`

>>Snapshots

Full wiki snapshots are published to Autonomi on update.
The latest address is always shown above.

[Back to Home|/index.mu]
MUEOF
        log "NomadNet archive page updated"
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────────
main() {
    log "=== Autonomi Wiki Sync starting ==="

    ensure_wiki

    local archive_file="$TMP_DIR/wiki.tar.gz"
    if download_from_autonomi; then
        sync_wiki_files "$archive_file"
        rebuild_index
        update_nomadnet_page
        log "=== Sync complete ==="
    else
        error "Download failed, skipping sync"
        exit 1
    fi
}

main "$@"
