#!/usr/bin/env python3
"""
ZKNetwork — P2P Wiki Conversion: MediaWiki XML dump → polished markdown with YAML frontmatter

Usage:
  python3 convert-wiki.py [--input dump.xml] [--output outdir] [--fix-wikilinks] [--slugify]

Handles:
  - Streaming XML parse (no full DOM in memory)
  - Category extraction → YAML tags
  - Wikilink HTML → [text](slug) markdown links
  - Bold/italic unescaping
  - Clean output compatible with llm-wiki
"""

import sys, os, re, yaml, subprocess, xml.parsers.expat, html, argparse

# ── Slugify page titles ─────────────────────────────────────────
def slugify(title):
    s = title.replace(" ", "-").replace("_", "-")
    s = re.sub(r'[^a-zA-Z0-9\u00C0-\u024F\u0400-\u04FF\-]', '', s)
    s = re.sub(r'-+', '-', s).strip('-')
    return s.lower() or "index"

def wikilink_slug(text):
    """Convert a wikilink target to a slug (lowercase, hyphens)."""
    return slugify(text)

# ── Post-processing fixes ───────────────────────────────────────
WIKILINK_HTML_RE = re.compile(r'<a\s+href="([^"]*?)"(?:\s+class="wikilink"[^>]*?|title="[^"]*?"\s+class="wikilink"[^>]*?)>([^<]*?)</a>')
CATEGORY_LINE_RE = re.compile(r'^\[\[Category:[^\]]+\]\]\s*$', re.MULTILINE)
BOLD_ESCAPE_RE = re.compile(r'\\([*_])')
CATEGORY_LINK_RE = re.compile(r'\[\[Category:([^\]]+)\]\]')

def fix_markdown(md, page_title):
    """Post-process pandoc output to fix wikilinks, bold, categories."""

    # 1. Fix HTML wikilinks → [text](slug)
    def fix_link(m):
        href = html.unescape(m.group(1))
        text = html.unescape(m.group(2))
        # Skip category links in body (handled by YAML)
        if href.lower().startswith("category:"):
            return ""
        slug = wikilink_slug(href.replace("_", " "))
        return f"[{text}]({slug})"
    md = WIKILINK_HTML_RE.sub(fix_link, md)

    # 2. Fix pandoc's escaped bold/italic markers
    md = BOLD_ESCAPE_RE.sub(r'\1', md)

    # 3. Remove stray [[Category:...]] lines
    md = CATEGORY_LINE_RE.sub('', md)

    # 4. Also remove inline [[Category:...]] references
    md = md.replace('[[Category:', '').replace(']]', '')

    # 5. Clean up excessive blank lines
    md = re.sub(r'\n{4,}', '\n\n\n', md)

    return md.strip()

# ── Main conversion ─────────────────────────────────────────────
def convert_page(title, wikitext, tags_global):
    """Convert a single MediaWiki page to markdown."""
    try:
        import mwparserfromhell
        parsed = mwparserfromhell.parse(wikitext)
        tags = []

        # Extract categories from [[Category:...]] wikilinks
        for link in parsed.filter_wikilinks():
            t = str(link.title).strip()
            if t.startswith("Category:"):
                cat = t.split(":", 1)[1].strip()
                tags.append(cat.lower().replace(" ", "-"))

        cleaned = str(parsed)
    except ImportError:
        cleaned = wikitext
        tags = []

    # Strip <category> tags
    cleaned = re.sub(r'<category[^>]*>.*?</category>', '', cleaned, flags=re.DOTALL)

    # Pandoc: MediaWiki → GitHub-Flavored Markdown
    proc = subprocess.run(
        ["pandoc", "-f", "mediawiki", "-t", "gfm",
         "--wrap=preserve", "--markdown-headings=atx"],
        input=cleaned, capture_output=True, text=True, timeout=60
    )

    if proc.returncode != 0:
        md = f"# {title}\n\n*(conversion error: {proc.stderr[:100]})*"
    else:
        md = proc.stdout.strip()
        if not md:
            md = f"# {title}\n\n*(empty page)*"

    # Post-process
    md = fix_markdown(md, title)

    # Build YAML frontmatter
    fm = {"title": title, "type": "page"}
    if tags:
        fm["tags"] = sorted(set(t for t in tags if t))
        tags_global.update(fm["tags"])

    return fm, md

def main():
    parser = argparse.ArgumentParser(description="Convert MediaWiki XML dump to polished markdown")
    parser.add_argument("--input", default="mediawiki_dump.xml", help="Input MediaWiki XML dump")
    parser.add_argument("--output", default="./wiki-export", help="Output directory for markdown files")
    args = parser.parse_args()

    INDIR = args.input
    OUTDIR = args.output
    PAGES_DIR = os.path.join(OUTDIR, "pages")
    os.makedirs(PAGES_DIR, exist_ok=True)

    if not os.path.exists(INDIR):
        print(f"Error: input file not found: {INDIR}", file=sys.stderr)
        sys.exit(1)

    tags_global = set()
    stats = {"total": 0, "converted": 0, "skipped": 0, "errors": 0}
    skipped_titles = {"redirect": 0, "special": 0, "empty": 0, "mediawiki": 0}

    # ── Streaming XML parser ────────────────────────────────────
    class WikiParser:
        def __init__(self):
            self.t = self.txt = self.p = self.r = False
            self.title = self.text = None
        def parse(self, path):
            def s(n, a):
                if n == "page": self.p = True; self.title = self.text = None
                elif n == "title" and self.p: self.t = True
                elif n == "revision" and self.p: self.r = True
                elif n == "text" and self.r: self.txt = True
            def e(n):
                nonlocal stats, skipped_titles
                if n == "page" and self.p:
                    if self.title and self.text:
                        title = self.title.strip()
                        text = self.text.strip()
                        stats["total"] += 1

                        # Skip non-content pages
                        if title.startswith("MediaWiki:") or title.startswith("Special:") or title.startswith("Talk:"):
                            skipped_titles["special"] += 1
                            stats["skipped"] += 1
                            self.p = False; return

                        # Skip redirects (first line starts with #REDIRECT)
                        if text.upper().startswith("#REDIRECT"):
                            skipped_titles["redirect"] += 1
                            stats["skipped"] += 1
                            self.p = False; return

                        if not text:
                            skipped_titles["empty"] += 1
                            stats["skipped"] += 1
                            self.p = False; return

                        try:
                            fm, md = convert_page(title, text, tags_global)
                            slug = slugify(title)
                            spath = os.path.join(PAGES_DIR, f"{slug}.md")
                            with open(spath, "w", encoding="utf-8") as f:
                                f.write("---\n")
                                yaml.dump(fm, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
                                f.write("---\n\n")
                                f.write(md)
                                f.write("\n")
                            stats["converted"] += 1
                            if stats["converted"] % 50 == 0:
                                print(f"  ... {stats['converted']} pages converted", file=sys.stderr)
                        except Exception as ex:
                            print(f"  Error: {title}: {ex}", file=sys.stderr)
                            stats["errors"] += 1
                    self.p = False
                elif n == "title": self.t = False
                elif n == "revision": self.r = False
                elif n == "text": self.txt = False
            def d(d):
                if self.t: self.title = (self.title or "") + d
                elif self.txt: self.text = (self.text or "") + d
            p = xml.parsers.expat.ParserCreate()
            p.StartElementHandler = s; p.EndElementHandler = e; p.CharacterDataHandler = d
            with open(path, "rb") as f: p.ParseFile(f)

    print(f"Parsing {INDIR} ...", file=sys.stderr)
    WikiParser().parse(INDIR)

    # ── Write tag index ─────────────────────────────────────────
    tags_list = sorted(t for t in tags_global if t)
    with open(os.path.join(OUTDIR, "tags.yaml"), "w") as f:
        f.write("# Wiki Tag Index\n")
        yaml.dump({"tags": tags_list, "count": len(tags_list)}, f,
                   default_flow_style=False, allow_unicode=True)

    # ── Write summary ───────────────────────────────────────────
    with open(os.path.join(OUTDIR, "README.md"), "w") as f:
        f.write(f"""# Wiki Export Summary

- Total pages in dump: {stats['total']}
- Converted: {stats['converted']}
- Skipped: {stats['skipped']} (redirects: {skipped_titles['redirect']}, special: {skipped_titles['special']})
- Errors: {stats['errors']}
- Unique tags: {len(tags_list)}
""")

    print(f"\nDone: {stats['converted']} pages → {PAGES_DIR}/", file=sys.stderr)
    print(f"  Skipped: {stats['skipped']} ({skipped_titles['redirect']} redirects, {skipped_titles['special']} special)", file=sys.stderr)
    print(f"  Errors: {stats['errors']}", file=sys.stderr)
    print(f"  Tags: {len(tags_list)} unique", file=sys.stderr)

    return stats["converted"]

if __name__ == "__main__":
    main()
