# zknode-autonomi — P4P Sovereign Node

**Post-quantum mixnet · ZK storage proofs · Autonomi P2P storage · Hardware-anchored identity**

A self-contained **sovereign storage node** — one SCM4/CM4 running the full stack: an embedded Katzenpost mixnet for metadata-private transport, a live Autonomi storage node, hardware-bound ZK storage proofs via zymkey HSM, and a mesh wiki archive. All on a single board. No cloud, no VPS.

> `STATUS` 🟢 Live on Autonomi testnet (Arbitrum Sepolia) since 2026-07-03
> `HW` SCM4 · 8GB RAM · aarch64 · zymkey HSM · USB 3.0 pool
> `MIXNET` Katzenpost v0.0.73+ · MLKEM768 · 3-hop Sphinx · 15 containers
> `STORAGE` ant-node v0.14.2 · LMDB · systemd --user
> `MESH` Reticulum v1.3.7 · WiFi IBSS · NomadNet · 4242/tcp
> `DASHBOARD` Node.js web UI · port 8080 · live mixnet/mesh/ant/zymkey tabs
> `WALLETSHIELD` Patched thin client · `FROM scratch` · 17MB · CORS proxy :9292

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    zknode (SCM4 / CM4)                          │
│  8GB RAM · aarch64 · zymkey HSM · USB 3.0 pool                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐  SOCKS5  ┌─────────────────┐                  │
│  │   ant-node   │◄────────►│  mixnet-proxy   │                  │
│  │  (Autonomi)  │  :1080   │  (Go, thin lib) │                  │
│  │  :12000      │          │  :9090 mgmt API │                  │
│  └──────┬───────┘          └───────┬─────────┘                  │
│         │                          │                            │
│         │ chunk data               │ ZK proofs                  │
│         ▼                          ▼                            │
│  ┌──────────────┐          ┌─────────────────┐                  │
│  │  LMDB Chunk  │          │ storage-proved  │                  │
│  │  Store       │◄────────►│ (Merkle/Wfell)  │                  │
│  │  /mnt/chunks │  mmap    │  :9201 API      │                  │
│  └──────────────┘          └────────┬────────┘                  │
│                                     │                           │
│                            ┌────────┴─────────┐                 │
│                            │  zymkey HSM (I²C)│                 │
│                            │  HW Attestation  │                 │
│                            └──────────────────┘                 │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Katzenpost Post-Quantum Mixnet (15 containers)          │   │
│  │  dirauth1/2/3 ←→ mix1/2/3 ←→ gateway ←→ servicenode      │   │
│  │  MLKEM768 · BLAKE2b-256 · 3-hop Sphinx · host networking │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

| Layer | What | Docs |
|-------|------|------|
| 1 Hardware | SCM4/CM4, zymkey HSM, USB 3.0 pool | [Hardware Setup](docs/HARDWARE_SETUP.md) · [Zymbit Setup](docs/ZYMBIT_SETUP.md) |
| 2 Mixnet | 3 dirauths + 3 mixes + gateway + servicenode + client | [Architecture](docs/ARCHITECTURE.md) · [Mixnet Integration](docs/MIXNET_INTEGRATION.md) |
| 3 Proxy | SOCKS5 bridge: ant-node ↔ mixnet (thin client) | [`cmd/mixnet-proxy/`](cmd/mixnet-proxy/main.go) |
| 4 ZK Proofs | Merkle tree · bandwidth proofs · HSM attestation | [Storage Proved](cmd/storage-proved-rs/) · [`scripts/zymkey-attest.py`](scripts/zymkey-attest.py) |
| 5 Storage | Autonomi ant-node + LMDB chunk store | [Live Node Status](docs/LIVE_NODE_STATUS.md) |
| 6 App | ant CLI, wallet ops, wiki mesh | [PoC Deployment Plan](docs/POC_DEPLOYMENT_PLAN.md) |

---

## Walkthrough Index

### Hardware & HSM

| Resource | Description |
|----------|-------------|
| [HARDWARE_SETUP.md](docs/HARDWARE_SETUP.md) | SCM4 platform, USB pool, mergerfs, LUKS encryption |
| [ZYMBIT_SETUP.md](docs/ZYMBIT_SETUP.md) | zymkey HSM provisioning, Bootware, one-way key binding |
| [`scripts/setup-zymbit.sh`](scripts/setup-zymbit.sh) | One-shot SCM4 provisioner: health check, full setup, USB encrypt |
| [`scripts/hsm-attest.sh`](scripts/hsm-attest.sh) | Periodically sign storage Merkle root with HSM |
| [`scripts/hsm-unlock.sh`](scripts/hsm-unlock.sh) | Unlock Autonomi SECRET_KEY from HSM-bound blob |
| [`scripts/hsm-file-integrity.sh`](scripts/hsm-file-integrity.sh) | HSM-locked file integrity manifest |
| [`scripts/zymkey-attest.py`](scripts/zymkey-attest.py) | Python attestation generator/verifier |

### Mixnet

| Resource | Description |
|----------|-------------|
| [MIXNET_INTEGRATION.md](docs/MIXNET_INTEGRATION.md) | Design options: external, embedded, thin client |
| [`config/mixnet/`](config/mixnet/) | Generated PKI + node configs (dirauth×3, mix×3, gateway, servicenode) |
| [`scripts/deploy.sh`](scripts/deploy.sh) | Deploy/start/stop/clean/export the full stack |
| [`scripts/monitor.sh`](scripts/monitor.sh) | Real-time status of all 15 containers |
| [`scripts/setup.sh`](scripts/setup.sh) | Initialize project structure and data directories |
| [`scripts/gen-mixnet-configs.sh`](scripts/gen-mixnet-configs.sh) | Regenerate all mixnet TOML configs |
| [`start-zkTUI.sh`](start-zkTUI.sh) | ANSI TUI dashboard: status, logs, ZKChat, stage tracking |

### Storage Node

| Resource | Description |
|----------|-------------|
| [LIVE_NODE_STATUS.md](docs/LIVE_NODE_STATUS.md) | Current state of the live testnet node |
| [POC_DEPLOYMENT_PLAN.md](docs/POC_DEPLOYMENT_PLAN.md) | Full walkthrough: from bare metal to running node |
| [`config/ant-node/ant-node.service`](config/ant-node/ant-node.service) | systemd unit for bare-metal ant-node |
| [`config/autonomi/`](config/autonomi/) | Autonomi node/CLI configuration files |
| [`Dockerfile.ant-node`](Dockerfile.ant-node) | Docker build: ant-node binary |
| [`Dockerfile.antd`](Dockerfile.antd) | Docker build: ant CLI + node manager |

### ZK Proofs

| Resource | Description |
|----------|-------------|
| [`cmd/storage-proved/main.go`](cmd/storage-proved/main.go) | Go Merkle proof daemon |
| [`cmd/storage-proved-rs/`](cmd/storage-proved-rs/) | Rust Winterfell STARK prover (production target) |
| [`Dockerfile.storage-proved`](Dockerfile.storage-proved) | Docker build: Go storage prover |
| [`Dockerfile.storage-proved-rs`](Dockerfile.storage-proved-rs) | Docker build: Rust Winterfell prover |

### SOCKS5 Proxy

| Resource | Description |
|----------|-------------|
| [`cmd/mixnet-proxy/main.go`](cmd/mixnet-proxy/main.go) | ~300-line SOCKS5 ↔ mixnet bridge via thin client lib |
| [`Dockerfile.mixnet-proxy`](Dockerfile.mixnet-proxy) | Docker build: proxy |
| [`config/proxy/config.json`](config/proxy/config.json) | Proxy configuration |

### Wallet / EVM

| Resource | Description |
|----------|-------------|
| [`scripts/gen-wallet.sh`](scripts/gen-wallet.sh) | Generate standard EVM wallet (eth_keys) |
| [`Dockerfile.walletshield`](Dockerfile.walletshield) | EVM RPC through mixnet |
| [`config/walletshield/config.toml`](config/walletshield/config.toml) | WalletShield thin client config |
| [`walletshield-fix/`](walletshield-fix/) | Patched walletshield source |

### Mesh & Wiki

| Resource | Description |
|----------|-------------|
| [WIKI_MESH_ARCHITECTURE.md](docs/WIKI_MESH_ARCHITECTURE.md) | Decentralized wiki over Autonomi + Reticulum |
| [`Dockerfile.llm-wiki`](Dockerfile.llm-wiki) | Git-backed markdown wiki engine with MCP/ACP |
| [`Dockerfile.nomadnet`](Dockerfile.nomadnet) | Mesh page server (micron format) over Reticulum |
| [`Dockerfile.wiki-export`](Dockerfile.wiki-export) | MediaWiki XML → markdown conversion |
| [`config/nomadnet/`](config/nomadnet/) | NomadNet config and micron pages |
| [`config/reticulum/`](config/reticulum/) | Reticulum mesh config |
| [`scripts/autonomi-wiki-sync.sh`](scripts/autonomi-wiki-sync.sh) | Download wiki from Autonomi, update llm-wiki |
| [`scripts/wiki-export-pipeline.sh`](scripts/wiki-export-pipeline.sh) | MediaWiki → markdown → Autonomi upload |
| [`scripts/test-mesh-roundtrip.sh`](scripts/test-mesh-roundtrip.sh) | Full mesh round-trip test: create → upload → download → import → serve |

### Reference Docs

| Document | Description |
|----------|-------------|
| [P4P_ARCHITECTURE.md](docs/P4P_ARCHITECTURE.md) | Complete technical reference for the P4P architecture |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | System layers, data flow, component interconnects |
| [POC_DEPLOYMENT_PLAN.md](docs/POC_DEPLOYMENT_PLAN.md) | Step-by-step deployment plan |
| [DEMO_SCRIPT.md](docs/DEMO_SCRIPT.md) | 11-step demo walkthrough |
| [LIVE_NODE_STATUS.md](docs/LIVE_NODE_STATUS.md) | Live testnet node metrics |
| [HARDWARE_SETUP.md](docs/HARDWARE_SETUP.md) | Hardware platform, USB storage, power |
| [ZYMBIT_SETUP.md](docs/ZYMBIT_SETUP.md) | Zymkey HSM provisioning and boot security |
| [MIXNET_INTEGRATION.md](docs/MIXNET_INTEGRATION.md) | Mixnet integration design options |
| [WIKI_MESH_ARCHITECTURE.md](docs/WIKI_MESH_ARCHITECTURE.md) | Decentralized wiki mesh architecture |

---

## Quick Start

```bash
# 1. Prerequisites check
./scripts/deploy.sh --check

# 2. Generate configs and data dirs
./scripts/setup.sh

# 3. Full Zymbit HSM setup (SCM4 only)
sudo ./scripts/setup-zymbit.sh --full          # one-time
./scripts/setup-zymbit.sh --encrypt-usb /dev/sda  # optional

# 4. Generate EVM wallet (any machine, offline)
./scripts/gen-wallet.sh --apply

# 5. Deploy the stack
./scripts/deploy.sh --start

# 6. Monitor
./scripts/monitor.sh
./start-zkTUI.sh                              # ANSI dashboard
```

Or if building images:

```bash
docker build --build-arg TARGETARCH=arm64 \
  -f Dockerfile.mixnet -t zeros/mixnet-node:arm64 .
# Repeat for: ant-node, antd, mixnet-proxy, storage-proved, walletshield,
#             llm-wiki, nomadnet, wiki-export
```

---

## Components

| Container | Role | Ports | RAM |
|-----------|------|-------|-----|
| mix-dirauth-1/2/3 | PKI directory authorities | 30001-30003 | 256MB |
| mix-1/2/3 | Sphinx mix nodes | 30011-30016 | 256MB |
| mix-gateway | Client entry point | 30004 | 256MB |
| mix-servicenode | Exit node (echo, http proxy) | 30007 | 256MB |
| mix-client | kpclientd thin client daemon | 64332 | 128MB |
| mixnet-proxy | SOCKS5 bridge + ZK proof API | 1080, 9090 | 256MB |
| walletshield | EVM RPC through mixnet | 9200 | 128MB |
| storage-proved | Merkle/Winterfell storage prover | 9201 | 128MB |
| antd | Autonomi CLI + node manager | bridge | 128MB |
| ant-node | Autonomi storage node (bare metal) | 12000 | ~20MB |
| reticulum | Reticulum mesh (RNS + LXMF) | bridge | 128MB |
| llm-wiki | Git-backed markdown wiki engine | 18765 | 64MB |
| nomadnet | Mesh page server over Reticulum | bridge | 64MB |

---

## API Reference

### ZK Proofs

| Endpoint | Description |
|----------|-------------|
| `GET :9090/prove/bandwidth` | Bandwidth proof (Merkle chain) |
| `GET :9090/prove/challenge` | Get storage challenge (proxied to :9201) |
| `POST :9090/prove/storage` | Generate storage proof (proxied to :9201) |
| `GET :9201/status` | Merkle tree state (root, chunk count) |
| `GET :9201/challenge` | Random challenge index |
| `POST :9201/prove` | Generate Merkle proof for challenged index |

### HSM Attestation

```bash
python3 scripts/zymkey-attest.py --merkle-root "<64-hex>"
```

### Wallet

```bash
./scripts/gen-wallet.sh          # print address only
./scripts/gen-wallet.sh --apply  # generate and write to .env
```

---

## Directory Map

```
zknode-autonomi/
├── .env                        # Environment config (gitignored — contains secrets)
├── .gitignore
├── docker-compose.yml          # 17-service stack
├── docker-compose.zymkey.yml   # Zymkey HSM override
├── Dockerfile.*                # 10 Dockerfiles (one per component)
├── start-zkTUI.sh              # ANSI TUI dashboard
├── cmd/
│   ├── mixnet-proxy/main.go    # SOCKS5 ↔ mixnet bridge
│   ├── storage-proved/         # Go Merkle proof daemon
│   ├── storage-proved-rs/      # Rust Winterfell STARK prover (WIP)
│   └── zkclientd/main.go       # Fixed client daemon wrapper
├── config/
│   ├── mixnet/                 # Generated PKI + node TOML configs
│   ├── proxy/config.json       # SOCKS5 proxy config
│   ├── walletshield/           # WalletShield thin client config
│   ├── autonomi/               # Autonomi node/CLI configs
│   ├── ant-node/               # systemd service unit files
│   ├── keys/                   # Generated keys (gitignored)
│   ├── reticulum/config        # Reticulum mesh config
│   └── nomadnet/               # NomadNet config + micron pages
├── scripts/
│   ├── deploy.sh               # Deploy/start/stop/clean/export
│   ├── setup.sh                # Init project structure
│   ├── monitor.sh              # Stack monitoring
│   ├── gen-mixnet-configs.sh   # Mixnet config generator
│   ├── gen-wallet.sh           # EVM wallet generator
│   ├── storage-layout.sh       # USB pool setup
│   ├── setup-zymbit.sh         # Zymbit/SCM4 hardware setup
│   ├── zymkey-attest.py        # HSM attestation script
│   ├── hsm-*.sh                # HSM unlock, attest, file integrity
│   ├── autonomi-wiki-sync.*    # Wiki sync service + timer + script
│   ├── test-mesh-roundtrip.sh  # Full mesh round-trip test
│   └── wiki-export-pipeline.sh # MediaWiki → markdown → Autonomi
├── docs/
│   ├── ARCHITECTURE.md         # System layers and data flow
│   ├── P4P_ARCHITECTURE.md     # Complete technical reference
│   ├── POC_DEPLOYMENT_PLAN.md  # Step-by-step deployment
│   ├── LIVE_NODE_STATUS.md     # Live node metrics
│   ├── HARDWARE_SETUP.md       # Hardware platform guide
│   ├── ZYMBIT_SETUP.md         # HSM provisioning guide
│   ├── MIXNET_INTEGRATION.md   # Mixnet integration options
│   ├── DEMO_SCRIPT.md          # 11-step demo
│   └── WIKI_MESH_ARCHITECTURE.md
├── walletshield-fix/           # Patched walletshield source
├── patches/                    # Katzenpost source patches
└── data/                       # Runtime data (gitignored)
```

---

## Roadmap & Limitations

| Area | Status | Notes |
|------|--------|-------|
| Autonomi testnet node | 🟢 Live | ant-node v0.14.2, Arbitrum Sepolia, ~100 peers |
| Mixnet PKI consensus | 🟢 Running | 3 dirauths, 20-min epoch, all nodes registered |
| ZK proof API | 🟢 Active | Merkle proofs, bandwidth proofs, HSM attestation |
| SOCKS5 proxy | 🟢 Working | ant-node ↔ mixnet via thin client lib |
| Zymkey HSM | 🟢 Active | One-way key, periodic attestation timer |
| llm-wiki engine | 🟢 Added | Rust, git-backed, MCP/ACP protocols |
| NomadNet pages | 🟢 Added | Mesh-accessible micron page server |
| Dashboard web UI | 🟢 Added | Port 8080, mixnet/mesh/ant/zymkey/wiki tabs |
| Reticulum mesh | 🟢 Active | rnsd systemd, WiFi IBSS (zknode-mesh), TCPServer :4242 |
| AI chat pipeline | 🟢 Fixed | `Sender: []byte("ai")` — dashboard renders AI responses |
| Walletshield fix | 🟢 Patched | Forked thin client, `FROM scratch`, CORS proxy :9292 |
| P4P wiki editor | 🟢 Added | Inline browser editor with write+commit |
| kpclientd epoch sync | 🔶 Workaround | Needs auth restart at epoch for full consensus |
| Zymkey HSM signing | 🔌 Planned | HSM-backed EVM transaction signing |
| Bridge networking | 📋 Future | Per-node bridge for production isolation |
| Mesh wiki replication | 📋 Future | Multi-node syncing across zknodes |
| Rust Winterfell STARKs | 🛠 WIP | `storage-proved-rs` — production prover |

---

## License

Source code: AGPL-3.0-only (matches Katzenpost / ZKNetwork licensing).  
Documentation: CC-BY-SA-4.0.

**⚠ Proof of Concept — not production-hardened. Keys generated for testing only.**
