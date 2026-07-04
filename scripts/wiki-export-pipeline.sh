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
log "Step 3: Converting MediaWiki XML to markdown..."

python3 - "$INPUT_DUMP" "$OUTPUT_DIR" << 'PYEOF'
"""Convert MediaWiki XML dump to markdown with YAML frontmatter.

Uses mwparserfromhell for wikitext parsing and pandoc for
MediaWiki→Markdown conversion. Produces output compatible with
llm-wiki ingestion.
"""

import sys
import os
import re
import xml.parsers.expat
import yaml
import subprocess
import html

INPUT_DUMP = sys.argv[1]
OUTPUT_DIR = sys.argv[2]
PAGES_DIR = os.path.join(OUTPUT_DIR, "pages")

PAGE_STATS = {"total": 0, "converted": 0, "skipped": 0, "errors": 0}
TAG_INDEX = {}

# ── XML streaming parser ────────────────────────────────────────
class WikiDumpParser:
    def __init__(self, path):
        self.path = path
        self.in_page = False
        self.in_title = False
        self.in_text = False
        self.in_revision = False
        self.current_page = None
        self.current_title = None
        self.current_text = None
        self.depth = 0
        self.tag_stack = []

    def parse(self, page_callback):
        """Stream-parse XML, calling page_callback(title, text) per page."""
        def start_element(name, attrs):
            self.tag_stack.append(name)
            if name == "page":
                self.in_page = True
                self.current_title = None
                self.current_text = None
            elif name == "title" and self.in_page:
                self.in_title = True
            elif name == "revision" and self.in_page:
                self.in_revision = True
            elif name == "text" and self.in_revision:
                self.in_text = True

        def end_element(name):
            self.tag_stack.pop()
            if name == "page" and self.in_page:
                if self.current_title and self.current_text:
                    page_callback(self.current_title, self.current_text)
                self.in_page = False
            elif name == "title":
                self.in_title = False
            elif name == "revision":
                self.in_revision = False
            elif name == "text":
                self.in_text = False

        def char_data(data):
            if self.in_title:
                self.current_title = (self.current_title or "") + data
            elif self.in_text:
                self.current_text = (self.current_text or "") + data

        parser = xml.parsers.expat.ParserCreate()
        parser.StartElementHandler = start_element
        parser.EndElementHandler = end_element
        parser.CharacterDataHandler = char_data

        with open(self.path, "rb") as f:
            parser.ParseFile(f)

def wikitext_to_markdown(wikitext, title):
    """Convert wikitext to markdown using pandoc."""
    try:
        # mwparserfromhell for structured parsing
        import mwparserfromhell
        parsed = mwparserfromhell.parse(wikitext)
        tags = []

        # Extract categories as tags
        for category in parsed.filter_tags():
            if str(category.tag).lower() in ("category",):
                cat_name = str(category.attributes.get("key", ""))
                if cat_name:
                    tags.append(cat_name.strip().lower().replace(" ", "-"))
        # Also handle [[Category:...]] wikilinks
        for link in parsed.filter_wikilinks():
            text = str(link.title)
            if text.startswith("Category:"):
                cat = text.split(":", 1)[1].strip()
                tags.append(cat.lower().replace(" ", "-"))
            elif text.startswith("File:") or text.startswith("Image:"):
                pass

        # Strip category tags from wikitext so pandoc doesn't see them
        cleaned = str(parsed)
    except ImportError:
        cleaned = wikitext
        tags = []

    # Remove <category> tags
    cleaned = re.sub(r'<category[^>]*>.*?</category>', '', cleaned, flags=re.DOTALL)

    # Use pandoc to convert MediaWiki → markdown
    proc = subprocess.run(
        ["pandoc", "-f", "mediawiki", "-t", "markdown_github",
         "--wrap=preserve", "--atx-headers"],
        input=cleaned,
        capture_output=True,
        text=True,
        timeout=60
    )

    if proc.returncode != 0:
        print(f"Warning: pandoc failed for '{title}': {proc.stderr[:200]}", file=sys.stderr)
        # Fallback: return raw wikitext stripped of angle-bracket tags
        fallback = re.sub(r'<[^>]+>', '', cleaned)
        return fallback, tags or ["uncategorized"]

    markdown = proc.stdout.strip()
    if not markdown:
        markdown = f"# {title}\n\n*(empty page)*"

    return markdown, tags

def make_slug(title):
    """Convert a MediaWiki page title to a filesystem-safe slug."""
    slug = title.replace(" ", "-").replace("_", "-")
    slug = re.sub(r'[^a-zA-Z0-9\u00C0-\u024F\u0400-\u04FF\-/]', '', slug)
    slug = re.sub(r'-+', '-', slug).strip('-')
    return slug.lower() or "index"

def write_page(title, wikitext):
    """Convert and write a single wiki page."""
    slug = make_slug(title)
    filepath = os.path.join(PAGES_DIR, f"{slug}.md")

    markdown, tags = wikitext_to_markdown(wikitext, title)

    # Build YAML frontmatter
    frontmatter = {
        "title": title,
        "type": "page",
    }
    if tags:
        unique_tags = list(set(t for t in tags if t))
        if unique_tags:
            frontmatter["tags"] = unique_tags
            for t in unique_tags:
                TAG_INDEX.setdefault(t, []).append(title)

    # Ensure output dir exists
    os.makedirs(os.path.dirname(filepath), exist_ok=True)

    with open(filepath, "w", encoding="utf-8") as f:
        f.write("---\n")
        yaml.dump(frontmatter, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
        f.write("---\n\n")
        f.write(markdown)
        f.write("\n")

    PAGE_STATS["converted"] += 1

    if PAGE_STATS["converted"] % 1000 == 0:
        print(f"  ... {PAGE_STATS['converted']} pages converted", file=sys.stderr)

def handle_page(title, text):
    """Callback for each page in the XML stream."""
    PAGE_STATS["total"] += 1

    if not text or not text.strip():
        PAGE_STATS["skipped"] += 1
        return

    title = title.strip()
    if not title or title.startswith("MediaWiki:") or title.startswith("Special:"):
        PAGE_STATS["skipped"] += 1
        return

    try:
        write_page(title, text)
    except Exception as e:
        print(f"Error converting '{title}': {e}", file=sys.stderr)
        PAGE_STATS["errors"] += 1

# ── Main conversion ─────────────────────────────────────────────
print("Starting MediaWiki XML parse...", file=sys.stderr)
parser = WikiDumpParser(INPUT_DUMP)
parser.parse(handle_page)

# Write tag index
with open(os.path.join(OUTPUT_DIR, "tags.yaml"), "w") as f:
    f.write("# Tag index\n")
    f.write(yaml.dump(dict(TAG_INDEX), default_flow_style=False, allow_unicode=True))

# Write summary
summary = f"""---
title: wiki-export-{os.path.basename(OUTPUT_DIR)}
type: export-summary
---

# Wiki Export Summary

- Total pages: {PAGE_STATS['total']}
- Converted: {PAGE_STATS['converted']}
- Skipped: {PAGE_STATS['skipped']}
- Errors: {PAGE_STATS['errors']}
- Tag count: {len(TAG_INDEX)}
- Export date: {__import__('datetime').datetime.now().isoformat()}
"""
with open(os.path.join(OUTPUT_DIR, "README.md"), "w") as f:
    f.write(summary)

print(f"\nDone: {PAGE_STATS['converted']} pages written", file=sys.stderr)
PYEOF

log "Converted $(find "$OUTPUT_DIR/pages" -name '*.md' | wc -l) pages to markdown"

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

  log "Uploading $ARCHIVE_FILE to Autonomi..."
  ant file upload "$ARCHIVE_FILE" --public

  # Update pointer
  if ant pointer create "$(basename "$ARCHIVE_FILE").datamap" --name "${WIKI_NAME}-wiki-latest" 2>/dev/null; then
    log "Pointer updated: ${WIKI_NAME}-wiki-latest"
  fi

  log "Archived to Autonomi: $ARCHIVE_FILE"
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
