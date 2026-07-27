# zknode-autonomi

**Any old computer can become a private Autonomi node.**

A self-contained anonymous Autonomi storage node that routes all P2P traffic through an embedded Katzenpost mixnet. No VPS, no cloud dependency — the entire mixnet runs on the same device as the storage node.

**Hardware**: Raspberry Pi CM4/SCM4 (8GB RAM, aarch64) or any machine with 8GB RAM + Docker.  
**Storage**: microSD for configs, USB SSD for pool/chunk storage.  
**Security**: ZSCM HSM, LUKS encryption, post-quantum cryptography.

---

## Architecture

```
MetaMask ──JSON-RPC──▶ walletshield ──mixnet──▶ upstream ETH RPC
                          │                   
web UI ──▶ zknode-dashboard ──▶ zkchat ──mixnet──▶ group chat / DMs
              │                      │
              │                      └──▶ llm-wiki (local LLM)
              │                                 │
              ├──▶ docker API ──▶ mixnet containers    └──▶ nomadnet ──▶ reticulum
              ├──▶ zymkey-api ──▶ ZSCM HSM
              └──▶ ant node ──SOCKS5──▶ mixnet-proxy ──mixnet──▶ Autonomi P2P
```

- **Layer 1**: Hardware (SCM4, ZSCM HSM, USB SSD)
- **Layer 2**: Mixnet (Katzenpost: 3 dirauths + 3 mixes + gateway + servicenode)
- **Layer 3**: Privacy-preserving apps (walletshield RPC proxy, zkchat messaging, courier MLKEM768)
- **Layer 4**: Mesh networking (Reticulum transport, Nomadnet chat/wiki, llm-wiki proxy)
- **Layer 5**: Storage (Autonomi ant-node with LMDB chunk store, storage-proved-rs proving)
- **Layer 6**: Dashboard (web UI for monitoring, chat, wallet, wiki, health)

---

## Services

| Service | Role | Port |
|---------|------|------|
| mix-dirauth-1/2/3 | Directory authorities (PKI consensus) | — |
| mix-1/2/3 | Mix nodes (3-hop onion routing) | — |
| mix-gateway | Client gateway | 64332 |
| mix-servicenode | Mixnet exit node (chatd, http-proxy, courier Kaetzchen) | — |
| mix-client | Thin client daemon (kpclientd) | 64332 |
| walletshield | Ethereum JSON-RPC over mixnet | 9200 |
| zkchat | CLI encrypted messaging (group + DM) | — |
| zknode-dashboard | Web UI (monitoring, chat, wiki, ant, health) | 8080 |
| mixnet-proxy | SOCKS5 bridge (ant-node ↔ mixnet) | 1080/9090 |
| storage-proved | Autonomi storage proving node (Go) | — |
| storage-proved-rs | Autonomi storage proving node (Rust) | — |
| llm-wiki | Local LLM for wiki search (Ollama) | — |
| nomadnet | Mesh chat/wiki over Reticulum | — |
| reticulum | LoRa/packet radio transport daemon | — |
| kpclientd | Thin client daemon (standalone) | 64332 |
| zymkey-api | ZSCM HSM HTTP API | 8765 |
| courier | PKI-advertized post-quantum key exchange (MLKEM768) | — |

---

## Quick Start

### Deploy full stack

```bash
cd zknode-autonomi
docker compose up -d
```

### Access dashboard

```
http://<host-ip>:8080
```

### Send encrypted chat message

```bash
# Group message
docker run --rm --network host -v $PWD/config/mixnet:/var/lib/katzenpost zeros/mixnet-node-fixed:v0.0.84 \
  zkchat group send /var/lib/katzenpost/client/thinclient.toml <group_id> "hello"

# Direct message
docker run --rm --network host -v $PWD/config/mixnet:/var/lib/katzenpost zeros/mixnet-node-fixed:v0.0.84 \
  zkchat send /var/lib/katzenpost/client/thinclient.toml <recipient_hex> "hello"
```

### Ethereum RPC over mixnet

```bash
# Local SSH tunnel
ssh -L 9200:127.0.0.1:9200 -N -f user@host

# Use in MetaMask
# Network: http://127.0.0.1:9200/ethereum
# Chain ID: 1 (Mainnet)
```

---

## File Structure

```
zknode-autonomi/
├── docker-compose.yml             # Full 16-service stack
├── docker-compose.zymkey.yml      # ZSCM HSM override
├── Dockerfile.mixnet              # Katzenpost mixnet node
├── Dockerfile.walletshield        # Ethereum RPC proxy
├── Dockerfile.mixnet-proxy        # SOCKS5 bridge
├── Dockerfile.kpclientd           # Standalone thin client
├── Dockerfile.llm-wiki            # Local LLM / wiki proxy
├── Dockerfile.nomadnet            # Nomadnet mesh chat/wiki
├── Dockerfile.reticulum           # Reticulum transport
├── Dockerfile.storage-proved      # Storage proving (Go)
├── Dockerfile.storage-proved-rs   # Storage proving (Rust)
├── Dockerfile.wiki-export         # Wiki export pipeline
├── Dockerfile.antd                # Ant node daemon
├── Dockerfile.replica             # Replica node
├── config/
│   ├── mixnet/                    # Mixnet PKI + node configs
│   │   ├── auth1-3/               # Directory authorities
│   │   ├── mix1-3/                # Mix nodes
│   │   ├── gateway1/              # Client gateway
│   │   ├── servicenode1/          # Exit node (chatd, http-proxy, courier)
│   │   ├── client/                # Thin client config
│   │   └── servicenode-entrypoint.sh
│   ├── walletshield/             # Thin client config
│   ├── proxy/                     # SOCKS5 proxy config
│   ├── autonomi/                  # Ant node configs
│   ├── ant-node/                  # Ant node systemd service
│   ├── nomadnet/                  # Nomadnet config + pages
│   ├── llm-wiki/                  # LLM wiki service config
│   └── reticulum/                 # Reticulum transport config
├── cmd/
│   ├── zkclientd/                 # Custom client daemon
│   ├── storage-proved/            # Storage proving (Go)
│   └── storage-proved-rs/         # Storage proving (Rust)
├── walletshield-fix/              # Walletshield hotfix
├── patches/                       # Katzenpost patches
│   └── fix-decoy-sender-nil-pointer.patch
├── zknode-dashboard/              # Web UI
│   ├── server/index.js            # Express backend
│   ├── public/index.html          # Frontend
│   └── Dockerfile
├── scripts/
│   ├── backup/                    # Backup automation (systemd timers)
│   │   ├── zknode-backup.sh
│   │   ├── zknode-backup.service
│   │   ├── zknode-backup.timer
│   │   ├── zknode-backup-weekly.timer
│   │   └── health-check.sh
│   ├── recovery/
│   │   └── zmnt-restore.sh        # Full recovery from USB backup
│   ├── hsm-attest.service/timer   # HSM attestation timer
│   ├── hsm-attest.sh              # HSM attestation script
│   ├── hsm-file-integrity.sh      # File integrity via HSM
│   ├── hsm-unlock.sh              # HSM unlock
│   ├── autonomi-wiki-sync.service/timer
│   ├── autonomi-wiki-sync.sh      # Wiki sync via Autonomi
│   ├── convert-wiki.py            # Wiki format converter
│   ├── wiki-export-pipeline.sh    # Wiki export pipeline
│   ├── test-mesh-roundtrip.sh     # Mesh roundtrip test
│   ├── walletshield-cli.sh        # Wallet CLI helper
│   ├── deploy.sh                  # Deploy/start/stop
│   ├── setup.sh                   # Init project structure
│   ├── gen-mixnet-configs.sh      # Mixnet config generator
│   ├── monitor.sh                 # Stack monitoring
│   ├── setup-zymbit.sh            # Zymkey/HSM setup
│   └── zymkey-attest.py           # HSM attestation
├── start-zkTUI.sh                 # zkTUI launcher
├── .github/workflows/build.yml    # CI/CD multi-arch builds
├── docs/                          # Documentation
└── README.md
```

---

## Scripts

| Command | Description |
|---------|-------------|
| `./scripts/deploy.sh --start` | Deploy and start full stack |
| `./scripts/deploy.sh --stop` | Stop stack |
| `./scripts/deploy.sh --check` | Verify prerequisites |
| `./scripts/monitor.sh` | Display stack status |
| `./scripts/setup.sh` | Initialize configs and data dirs |
| `./scripts/gen-mixnet-configs.sh` | Generate mixnet node configs |
| `./scripts/setup-zymbit.sh --check` | HSM health check |
| `./scripts/setup-zymbit.sh --full` | Full Zymbit security setup |
| `./scripts/backup/zknode-backup.sh` | Manual backup run |
| `./scripts/backup/health-check.sh` | JSON health status |
| `./scripts/recovery/zmnt-restore.sh` | Full recovery from USB |
| `./scripts/hsm-attest.sh` | HSM attestation (timer) |
| `./scripts/hsm-unlock.sh` | HSM unlock |
| `./scripts/hsm-file-integrity.sh` | File integrity check |
| `./scripts/walletshield-cli.sh` | Wallet CLI (balance, send) |
| `./scripts/wiki-export-pipeline.sh` | Wiki export pipeline |
| `./scripts/autonomi-wiki-sync.sh` | Sync wiki via Autonomi |
| `./scripts/test-mesh-roundtrip.sh` | Mesh connectivity test |
| `./start-zkTUI.sh` | Terminal UI launcher |

---

## API Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /api/chat/identity` | User's zkchat identity hex |
| `GET /api/chat/groups` | List user's groups |
| `POST /api/chat/groups/send` | Send group message |
| `GET /api/chat/groups/poll` | Poll group messages |
| `POST /api/chat/groups/create` | Create group |
| `POST /api/chat/send` | Send direct message |
| `GET /api/chat/poll` | Poll direct messages |
| `GET /api/health` | Full service health (consensus, containers, disk, backup age) |
| `GET /api/ant/wallet` | Ant node wallet address |
| `GET /api/ant/balance` | ANT/ETH balance |
| `GET /api/zymkey/eth-address` | ZSCM-derived ETH address |
| `GET /api/system` | System stats (CPU, RAM, disk) |
| `GET /api/containers` | Docker container status |

---

## Known Limitations

- **Host networking**: Mixnet containers share the host network (only one instance per port).
- **Dirauth startup race**: All 3 authorities must be running to reach consensus. Mitigated by retry loops.
- **Message persistence**: zkchat group messages are stored in chatd until first poll, then deleted. Dashboard persists polled messages to `chat-history.json`.
- **walletshield**: Requires SSH tunnel for MetaMask (`http` only works for localhost). Use `ssh -L 9200:127.0.0.1:9200`.
- **ZSCM integration**: HSM provides key generation and signing for ant node rewards. Full transaction signing is functional via `sign_eth` endpoint.

---

## Documentation

- [PoC Deployment Plan](docs/POC_DEPLOYMENT_PLAN.md) — Full deployment walkthrough
- [Architecture](docs/ARCHITECTURE.md) — System layers and data flow
- [Hardware Setup](docs/HARDWARE_SETUP.md) — SCM4 hardware, storage, USB pool
- [Zymbit/SCM4 Setup](docs/ZYMBIT_SETUP.md) — zymkey HSM, Bootware, LUKS, tamper, wallet
- [Mixnet Integration](docs/MIXNET_INTEGRATION.md) — Integration design options
- [Demo Script](docs/DEMO_SCRIPT.md) — Step-by-step demo walkthrough
- [Roadmap](docs/ROADMAP.md) — Gap features, priorities, timeline
- [Recovery](docs/RECOVERY.md) — SD card failure restore procedure
- [Mesh Chat Bridge](docs/ARCHITECTURE-MESH-CHAT-BRIDGE.md) — Reticulum ↔ mixnet bridge design
- [mixnet-proxy Debug](docs/DEBUG-MIXNET-PROXY.md) — Gateway connection troubleshooting
- [P4P Architecture](docs/P4P_ARCHITECTURE.md) — Permissionless peer-to-peer mesh architecture
- [Wiki Mesh](docs/WIKI_MESH_ARCHITECTURE.md) — Distributed wiki over mesh/Autonomi
- [Live Node Status](docs/LIVE_NODE_STATUS.md) — Current production node state
- [P2P Foundation Proposal](docs/P2P_FOUNDATION_PROPOSAL.md) — Grant proposal draft

---

## License

Source code: AGPL-3.0-only.  
Documentation: CC-BY-SA-4.0.

**WARNING**: This is a Proof of Concept. Not production-hardened.
## Key Components

| Component | Port | Description |
|-----------|------|-------------|
| **zknode-dashboard** | 8080 | Web UI: system stats, mixnet health, wiki, zkchat, ant |
| **walletshield** | 9200 | Mixnet RPC proxy for MetaMask (CORS proxy on :8080/ethereum) |
| **mixnet** | 30001-30019 | Katzenpost mixnet (dauths, mixes, gateway, servicenode) |
| **kpclientd** | 64332 | Thin client daemon for walletshield & zkchat |
| **zkchat** | — | E2EE chat over mixnet |
| **llm-wiki** | 18765 | Local LLM-powered wiki search (P4P wiki, 39k+ pages) |
| **antd** | 12000 | Autonomi node daemon with Zymbit HSM wallet |

## Mixnet Tuning

The mixnet uses 3 mix layers with 1 node per layer (all localhost). Key parameters in `config/mixnet/auth1/authority.toml`:

- `Layers = 1` (reduced from 3 for lower latency — set during session)
- `UserForwardPayloadLength = 2000` (Sphinx payload size, matched across all configs)
- `Mu = 0.005`, `LambdaM = 0.2` (decoy/mix rate parameters)

RPC latency: ~2s after warmup (first request may take 30s for PKI fetch).

## zkchat

Groups stored in `/tmp/zkchat/` on the servicenode (chatd default). Dashboard reads from both `/tmp/zkchat/` and legacy path. Group creation/deletion supported via API and UI. No `group delete` command in zkchat CLI — deletion done via `rm -rf` on the store directory.

## MetaMask Connectivity

Use `http://<SCM4_IP>:8080/ethereum` as RPC URL (chain ID 1). The dashboard adds CORS headers (`Access-Control-Allow-Origin: *`). First request may be slow while mixnet warmup completes.

## Boot Recovery

Systemd service `zknode-boot.service` starts containers in phased order:
1. Directory authorities → 2. Mix nodes → 3. Gateway + Servicenode → 4. Client + Walletshield → 5. Dashboard + Support

Manual invocation: `sudo /home/zero-tech/zknode-autonomi/deploy.sh`

## Backup

- Local: `./backup-scm4.sh /tmp/scm4-backup-$(date +%Y%m%d-%H%M)`
- Restore: `./restore-scm4.sh <backup_dir>`
- USB SSD: Configs synced to `/mnt/autonomi/autonomi-data/zknode-backup-*/`

## Known Issues

- Chatd `-store` flag can't pass arguments (CBOR plugin treats `Command` as raw path)
- Proxy upstream responses exceeding 2000 bytes stall the plugin (restart servicenode to recover)
- Zymkey device flips between `/dev/ttyACM0` and `/dev/ttyACM1` on reboot
- Mixnet PKI chain requires ~20 min to stabilize after dauth restarts

## Mesh Wiki (NomadNet over Reticulum)

NomadNet serves the P4P wiki over the Reticulum mesh network for offline/peer-to-peer access.

| Component | Port | Description |
|-----------|------|-------------|
| **reticulum** | 37428/udp | Reticulum mesh transport (LoRa/LLC/I2P) |
| **nomadnet** | 4242/tcp | NomadNet mesh HTTP + peer discovery |

### Architecture

```
Mesh Peer ←→ Reticulum ←→ NomadNet (4242) ←→ Dynamic Pages ←→ Dashboard API (8080) ←→ llm-wiki MCP
                        ↕
                Static .mu pages (config/nomadnet/pages/)
```

- **Static pages**: Wiki content auto-exported as `.mu` files whenever a page is viewed in the dashboard (via `POST /api/wiki/export/:slug`)
- **Dynamic pages**: Python scripts in `config/nomadnet/pages/wiki/` that proxy search and page-read through to the dashboard REST API
  - `/wiki/search?q=query` — searches 39k+ wiki pages, returns results as `.mu` links
  - `/wiki/page?slug=Page_Name` — fetches a single page, renders as `.mu` with internal links

### Dashboard Mesh Tab

The frontend wiki browser panel (`#meshWikiContent`) mirrors the P4P wiki viewer. Any page viewed triggers auto-export to the nomadnet pages directory. State (active tab, wallet, wiki history, chat) persists across full page refreshes via `sessionStorage`.

### Configuration

- `config/nomadnet/config` — Reticulum identity, NomadNet port, dynamic page paths
- `config/nomadnet/pages/wiki/search` — Python search proxy (executable)
- `config/nomadnet/pages/wiki/page` — Python page-reader proxy (executable)
- `config/nomadnet/pages/` — Shared volume mounted in both `nomadnet` and `dashboard` containers

### Health Check

```
curl http://scm4:8080/api/status
→ {"rnsd":"running","nomadnet":"active","nomadPages":6,"wiki":{"pages":39804}}
```
