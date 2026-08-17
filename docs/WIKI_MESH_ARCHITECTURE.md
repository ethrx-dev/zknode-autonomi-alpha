# ZKNetwork P4P Wiki Mesh — Architecture

**Decentralized Markdown Wiki over Autonomi Storage + Reticulum Mesh + Katzenpost Mixnet**

---

## Overview

The P4P Wiki Mesh is a multi-layer architecture for hosting, editing, and distributing a decentralized markdown wiki. It combines three independently useful networks into a unified system:

| Layer | Technology | Role |
|-------|-----------|------|
| Storage | Autonomi (ant) | Permanent, content-addressed wiki archive |
| Transport | Reticulum (NomadNet/LXMF) | Mesh-accessible page serving & messaging |
| Privacy | Katzenpost mixnet | Metadata-private editing & sync |
| Engine | llm-wiki | CLI markdown wiki with search, graph, MCP/ACP |

---

## Data Flow

```
                     ┌──────────────────────┐
                     │  llm-wiki engine     │
                     │ (single Rust binary) │
                     │ git-backed markdown  │
                     └──────┬───────┬───────┘
                            │       │
              ┌─────────────┘       └─────────────┐
              ▼                                   ▼
   ┌──────────────────┐                  ┌──────────────────┐
   │  NomadNet page   │                  │  Autonomi        │
   │  server (.mu)    │                  │  ant file upload │
   │  mesh-accessible │                  │  permanent store │
   │  :37428          │                  │  content-addrs   │
   └──────────────────┘                  └──────────────────┘
              │                                   │
              │                          ┌────────┴────────┐
              │                          │  Katzenpost     │
              │                          │  mixnet (SOCKS5)│
              │                          │  metadata-hiding│
              │                          └─────────────────┘
              │
   ┌──────────┴──────────┐
   │  Reticulum mesh     │
   │  (LoRa, WiFi, TCP)  │
   │  no internet needed │
   └─────────────────────┘
```

---

## Component Details

### 1. llm-wiki — Markdown Wiki Engine

**Repository**: <https://github.com/geronimo-iia/llm-wiki>

A single Rust binary providing a git-backed markdown wiki with full-text search (tantivy), typed pages (JSON Schema), concept graphs (petgraph), and MCP/ACP protocol support.

**Key properties for mesh use:**

- **Single binary, zero runtime** — no database, no daemon, no external services
- **Plain markdown + git** — wiki data is portable, diffable, readable by any tool
- **CLI-first** — all operations available from command line, ideal for terminal-based mesh access
- **MCP/ACP protocols** — compatible with agent-driven editing
- **19 tools** — search, list, read, write, graph, suggest, history, stats

**Usage on zknode:**

```bash
# Create a wiki space
llm-wiki spaces create ~/wikis/p2p-foundation --name p2p-foundation

# Start MCP server for editing
llm-wiki serve --http :18765

# CLI operations
llm-wiki search p2p-foundation "mutual credit"
llm-wiki list p2p-foundation --type concept
llm-wiki graph p2p-foundation --format mermaid
```

---

### 2. Autonomi — Permanent Wiki Archive

**Network**: Autonomi (ant CLI, antd daemon)

The Autonomi network provides permanent, content-addressed, encrypted storage. Each wiki snapshot is archived as a set of files:

**Archive strategy:**

| Asset | Autonomi Primitive | Description |
|-------|--------------------|-------------|
| Full wiki snapshot | `ant file upload` | Tar/gzip of entire wiki repo |
| Individual pages | `ant file upload --public` | Public-access pages |
| Wiki index | `ant scratchpad` | Mutable index of page addresses (up to 4MB) |
| Latest address | `ant pointer` | Updatable reference to latest snapshot |

**Workflow:**

```bash
# Archive full wiki
tar czf wiki-snapshot-2026-07-04.tar.gz -C ~/wikis/p2p-foundation .
ant file upload wiki-snapshot-2026-07-04.tar.gz --public

# Update pointer to latest snapshot
ant pointer create wiki-snapshot-$(date +%F).tar.gz.datamap --name p2p-wiki-latest

# Download & restore from any node
ant file download <address> --output wiki-restore.tar.gz
tar xzf wiki-restore.tar.gz -C ~/wikis/p2p-foundation
```

**Mixnet routing**: All Autonomi traffic flows through the Katzenpost mixnet via the SOCKS5 proxy (:1080), hiding the node's IP from storage peers.

---

### 3. NomadNet — Mesh Page Serving

**Package**: `nomadnet` (Python, runs on Reticulum)

NomadNet serves micron-format (.mu) pages directly on the Reticulum mesh. Pages are lightweight, bandwidth-efficient, and accessible over LoRa, packet radio, WiFi, or TCP.

**Architecture on zknode:**

```
zknode reticulum container
  ├── rnsd (Reticulum daemon)
  ├── nomadnet --daemon
  │     └── page server at ~/.nomadnetwork/storage/pages/
  │           ├── index.mu          # Wiki entry point
  │           ├── wiki/             # Mirrored wiki pages
  │           ├── search.mu         # Dynamic search page (PHP/Python)
  │           └── archive.mu        # Links to Autonomi archives
  └── TCP peer interface :37428
```

**Page mirroring pipeline:**

```bash
# Convert markdown pages to micron format
# (from llm-wiki markdown files)
md2mu ~/wikis/p2p-foundation/ ~/.nomadnetwork/storage/pages/wiki/

# NomadNet serves them on the mesh
# Access via any NomadNet client at the node's destination hash
nomadnet --daemon
```

**Tools for conversion:**
- `md2mu` — markdown-to-micron converter
- `MicronConverter` — alternative converter
- Dynamic pages via server-side scripts (Python, bash)

---

### 4. Katzenpost Mixnet — Privacy Layer

All Autonomi traffic and Reticulum TCP peer connections route through the Katzenpost mixnet for metadata privacy:

```
ant file upload
  → SOCKS5 :1080
  → mixnet-proxy (thin client)
  → kpclientd :64332
  → gateway → mix-3 → mix-2 → mix-1 → servicenode
  → Autonomi peer (QUIC)
```

---

## Complete Architecture Stack

```
┌─────────────────────────────────────────────────────────────────┐
│                    User Access Points                           │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────────┐   │
│  │ NomadNet │  │ ant CLI  │  │ llm-wiki │  │ NomadNavigator │   │
│  │   TUI    │  │ (Docker) │  │   CLI    │  │  Desktop GUI   │   │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └───────┬────────┘   │
│       │             │             │                │            │
├───────┼─────────────┼─────────────┼────────────────┼────────────┤
│       ▼             ▼             ▼                ▼            │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                 Docker Compose (zknode)                  │   │
│  │                                                          │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐                │   │
│  │  │reticulum │  │  antd    │  │ llm-wiki │                │   │
│  │  │:37428    │  │ (bridge) │  │ :18765   │                │   │
│  │  │nomadnet  │  │          │  │ MCP/ACP  │                │   │
│  │  └────┬─────┘  └────┬─────┘  └──────────┘                │   │
│  │       │             │                                    │   │
│  │       │    ┌────────┴────────┐                           │   │
│  │       │    │ mixnet-proxy    │                           │   │
│  │       │    │ SOCKS5 :1080    │                           │   │
│  │       │    └────────┬────────┘                           │   │
│  │       │             │                                    │   │
│  │       │    ┌────────┴────────┐                           │   │
│  │       │    │ kpclientd       │                           │   │
│  │       │    │ :64332          │                           │   │
│  │       │    └────────┬────────┘                           │   │
│  │       │             │                                    │   │
│  │       │    ┌────────┴────────┐                           │   │
│  │       │    │ Katzenpost      │                           │   │
│  │       │    │ mixnet (15 ctr) │                           │   │
│  │       │    └─────────────────┘                           │   │
│  └───────┼──────────────────────────────────────────────────┘   │
│          │                                                      │
├──────────┼──────────────────────────────────────────────────────┤
│          ▼                                                      │
│  ┌─────────────────────────────────────┐                        │
│  │       Reticulum Mesh                │                        │
│  │  (LoRa, packet radio, WiFi, TCP)    │                        │
│  │  No internet required               │                        │
│  └─────────────────────────────────────┘                        │
└─────────────────────────────────────────────────────────────────┘
```

---

## Editing Workflows

### Local Editing (via llm-wiki CLI)

```bash
# Create a new page
llm-wiki content new p2p-foundation concepts/mutual-credit

# Write content (validates against schema)
llm-wiki content write p2p-foundation concepts/mutual-credit << 'EOF'
---
title: Mutual Credit
type: concept
tags:
  - economics
  - p2p
  - currency
---

Mutual credit is a form of [[alternative currency]] where...

## See Also
- [[Complementary Currencies]]
- [[Time Banking]]
EOF

# Commit to git history
llm-wiki content commit p2p-foundation "Add mutual credit concept"

# Search
llm-wiki search p2p-foundation "mutual credit"

# View graph
llm-wiki graph p2p-foundation concepts/mutual-credit
```

### Remote Editing (via NomadNet over mesh)

```
User with NomadNet TUI
  → discovers zknode via Reticulum announce
  → browses wiki pages via micron
  → sends edit request via LXMF message (encrypted)
  → NomadNet propagation node stores message
  → zknode editor processes request
  → llm-wiki applies changes, commits to git
  → updated pages mirrored to NomadNet micron format
```

### Agent-Driven Editing (via MCP/ACP)

```
AI agent (Claude Code, Cursor, etc.)
  → connects to llm-wiki MCP server at :18765
  → reads wiki pages, searches, analyzes
  → writes new pages, links concepts
  → commits changes to git
  → changes synced to Autonomi + NomadNet
```

---

## MediaWiki Export Pipeline

The existing P2P Foundation wiki (45k+ pages, MediaWiki) is migrated via:

1. **Export**: `dumpBackup.php` generates XML dump
2. **Convert**: `mediawiki-to-markdown` Python tool converts to markdown with YAML frontmatter
3. **Ingest**: `llm-wiki content write` imports each page into the wiki space
4. **Archive**: `ant file upload` stores the full wiki on Autonomi
5. **Serve**: NomadNet mirrors key pages for mesh access

See `scripts/wiki-export-pipeline.sh` for the automated pipeline.

---

## Publication Strategy

| Channel | Method | Latency | Ideal For |
|---------|--------|---------|-----------|
| Autonomi | `ant file upload --public` | ~30 sec | Permanent archival, censorship-resistant |
| NomadNet | micron pages on mesh | Instant | Mesh-local browsing |
| Git remote | `git push` | ~10 sec | Development, collaboration |
| llm-wiki index | Tantivy search index | Instant | Full-text search |

---

## Security Properties

| Property | How It's Achieved |
|----------|-------------------|
| Metadata privacy | All Autonomi traffic routed through Katzenpost mixnet |
| Censorship resistance | Pages served from NomadNet (mesh) and Autonomi (storage) |
| Integrity | Content-addressed storage (Autonomi) + git history (llm-wiki) |
| Availability | Multiple zknodes can each serve the wiki independently |
| Encryption | Autonomi self-encryption + Reticulum E2E encryption by default |
| Off-grid access | NomadNet pages work over LoRa without internet |

---

## Roadmap

| Phase | Component | Status |
|-------|-----------|--------|
| 1 | llm-wiki Docker image + compose service | 🔜 Next |
| 2 | NomadNet micron page mirroring | 📋 Planned |
| 3 | MediaWiki export pipeline | 📋 Planned |
| 4 | Autonomi wiki archiver script | 📋 Planned |
| 5 | Multi-node wiki sync (mesh replication) | 🔮 Future |
| 6 | Agent-driven wiki editing over MCP | 🔮 Future |
