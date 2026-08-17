#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════
# ZKNetwork — P2P Foundation Wiki Export Pipeline
#
# Converts a MediaWiki XML dump to a markdown wiki archive,
# ingests it into llm-wiki, and archives it to Autonomi storage.
#
# Usage:
#   ./wiki-export-pipeline.sh [--input <dump.xml>] [--output <dir>]
#
# Prerequisites:
#   - pandoc
#   - python3 with mwparserfromhell, pyyaml
#   - llm-wiki binary on PATH
#   - ant CLI configured with SECRET_KEY
# ═══════════════════════════════════════════════════════════════════

INPUT_DUMP="${INPUT_DUMP:-mediawiki_dump.xml}"
OUTPUT_DIR="${OUTPUT_DIR:-./wiki-export}"
WIKI_NAME="${WIKI_NAME:-p2p-foundation}"
LLM_WIKI_ROOT="${LLM_WIKI_ROOT:-$HOME/wikis/$WIKI_NAME}"
ARCHIVE_DATE="$(date +%F)"

log()  { echo "[*] $*"; }
err()  { echo "[!] $*" >&2; exit 1; }

# ── Parse args ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)    INPUT_DUMP="$2"; shift 2 ;;
    --output)   OUTPUT_DIR="$2"; shift 2 ;;
    --wiki)     WIKI_NAME="$2"; shift 2 ;;
    --help|-h)  echo "Usage: $0 [--input <dump.xml>] [--output <dir>] [--wiki <name>]"; exit 0 ;;
    *)          err "Unknown option: $1" ;;
  esac
done

# ── Check prerequisites ─────────────────────────────────────────
log "Checking prerequisites..."

command -v pandoc  >/dev/null 2>&1 || err "pandoc required: apt install pandoc"
command -v python3 >/dev/null 2>&1 || err "python3 required"
command -v llm-wiki >/dev/null 2>&1 || log "Warning: llm-wiki not found (install from https://github.com/geronimo-iia/llm-wiki)"

python3 -c "import mwparserfromhell, yaml" 2>/dev/null || \
  err "Missing python deps: pip install mwparserfromhell pyyaml"

if ! command -v ant >/dev/null 2>&1; then
  log "Warning: ant CLI not found — skipping Autonomi archive step"
  SKIP_ARCHIVE=1
else
  SKIP_ARCHIVE=0
fi

# ── Step 1: Verify input dump ───────────────────────────────────
if [[ ! -f "$INPUT_DUMP" ]]; then
  err "Input dump not found: $INPUT_DUMP"
fi

log "Input: $INPUT_DUMP ($(du -h "$INPUT_DUMP" | cut -f1))"

# ── Step 2: Create output directory ─────────────────────────────
mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/pages"
mkdir -p "$OUTPUT_DIR/images"

# ── Step 3: Extract pages from XML dump via Python converter ────
log "Step 3: Converting MediaWiki XML to polished markdown..."

# Use the dedicated converter script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$SCRIPT_DIR/convert-wiki.py" \
  --input "$INPUT_DUMP" \
  --output "$OUTPUT_DIR" 2>&1

log "Converted $(find "$OUTPUT_DIR/pages" -name '*.md' | wc -l) pages to polished markdown"

# ── Step 4: Ingest into llm-wiki ────────────────────────────────
if command -v llm-wiki >/dev/null 2>&1; then
  log "Step 4: Ingesting into llm-wiki..."

  mkdir -p "$LLM_WIKI_ROOT"

  # Create or use existing wiki space
  llm-wiki spaces create "$LLM_WIKI_ROOT" --name "$WIKI_NAME" 2>/dev/null || true

  # Copy pages into the wiki
  cp -r "$OUTPUT_DIR/pages/"* "$LLM_WIKI_ROOT/"

  # Ingest (validate, index, commit)
  llm-wiki ingest "$WIKI_NAME"

  log "Wiki ingested at $LLM_WIKI_ROOT"
else
  log "Step 4: Skipped (llm-wiki not installed)"
fi

# ── Step 5: Archive to Autonomi ─────────────────────────────────
if [[ "$SKIP_ARCHIVE" -eq 0 ]]; then
  log "Step 5: Archiving to Autonomi..."

  ARCHIVE_FILE="${OUTPUT_DIR}/${WIKI_NAME}-wiki-${ARCHIVE_DATE}.tar.gz"

  tar czf "$ARCHIVE_FILE" -C "$OUTPUT_DIR/pages" .

  # Try ant CLI directly, or via Docker container
  ANT_CMD="ant"
  if ! command -v ant >/dev/null 2>&1 || ant --version 2>&1 | grep -qi "apache"; then
    if docker exec antd ant --version >/dev/null 2>&1; then
      ANT_CMD="docker exec -i antd ant"
      log "Using ant CLI from Docker antd container"
    else
      log "Warning: ant CLI not found — skipping Autonomi upload"
      SKIP_ARCHIVE=1
    fi
  fi

  if [[ "$SKIP_ARCHIVE" -eq 0 ]]; then
    log "Uploading $ARCHIVE_FILE to Autonomi..."
    $ANT_CMD file upload "$ARCHIVE_FILE" --public

    # Update pointer
    if $ANT_CMD pointer create "$(basename "$ARCHIVE_FILE").datamap" --name "${WIKI_NAME}-wiki-latest" 2>/dev/null; then
      log "Pointer updated: ${WIKI_NAME}-wiki-latest"
    fi

    log "Archived to Autonomi: $ARCHIVE_FILE"
  fi
else
  log "Step 5: Skipped (ant CLI not available)"
fi

# ── Step 6: Summary ─────────────────────────────────────────────
log "═══ Export Complete ═══"
echo "  Source:       $INPUT_DUMP"
echo "  Output:       $OUTPUT_DIR/pages/"
echo "  Pages:        $(find "$OUTPUT_DIR/pages" -name '*.md' | wc -l)"
echo "  llm-wiki:     $LLM_WIKI_ROOT"
echo "  Autonomi:     $([ "$SKIP_ARCHIVE" -eq 0 ] && echo "uploaded" || echo "skipped")"
