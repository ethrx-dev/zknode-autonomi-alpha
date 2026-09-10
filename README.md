# zknode-autonomi — P4P Reference Architecture

> ⚠️ **DISCLAIMER — actively in development & testing (proof of concept).**
> Not audited, not production-ready, testnet only. Breaking changes and key
> rotation are routine. See [DISCLAIMER.md](DISCLAIMER.md) before deploying.

**Post-Quantum Mixnet + ZK Storage Proving + Autonomi P2P Storage**

A self-contained private Autonomi storage node with traffic routed through an embedded post-quantum Katzenpost mixnet, hardware-bound ZK storage proofs, and metadata-private P2P communication. Built for the SCM4/CM4 platform as a reference architecture for the P4P proof-of-useful-work movement.

> **STATUS**: 🟢 **LIVE ON AUTONOMI TESTNET** — ant-node v0.14.4 (pinned) serving on Arbitrum Sepolia. See [Live Node Status](docs/LIVE_NODE_STATUS.md).

**Hardware**: SCM4/CM4 (8GB RAM, aarch64) with zymkey HSM.  
**Multi-arch**: all core images build and run on **amd64 and arm64** (`./scripts/build.sh`).

---

## Quickstart (v0.2 — any amd64/arm64 Linux host)

```bash
git clone -b main https://github.com/ethrx-dev/zknode-autonomi-alpha.git zknode-autonomi
cd zknode-autonomi
cp .env.example .env                   # edit: NODE_HOME, ports; set DASHBOARD_TOKEN for LAN access
./scripts/build.sh                     # build images for this host's arch
./scripts/build.sh --both              # ...or amd64 + arm64 tags
sudo ./scripts/deploy.sh --check       # pre-flight
sudo ./scripts/deploy.sh               # fast-stagger deploy (creates -> starts group-by-group)
```

Dashboard: `http://<host>:8080` — binds **127.0.0.1 only** until you set
`DASHBOARD_TOKEN` in `.env` (generate: `openssl rand -hex 24`); with a token,
all `/api` endpoints are authenticated and rate-limited.

Node state (keys, identities) lives on the node and is NEVER committed:

```bash
sudo ./scripts/deploy.sh --backup-state    # encrypted bundle -> /mnt/autonomi/backup (BACKUP_KEYFILE required)
sudo ./scripts/deploy.sh --restore-state <bundle>   # disaster recovery
sudo ./scripts/deploy.sh --export-config   # drift check: repo topology vs live containers
```

Tests: `cd tests && ./run-all.sh` (4 checks + device drift check).

> **Privacy boundaries (honest scope)**: the WalletShield EVM RPC and zkchat
> messages traverse the embedded Katzenpost mixnet; the embedded 9-node
> mixnet on one host is an integration lab (single operator = no distributed
> anonymity); Autonomi P2P QUIC traffic goes out directly (not proxied).
> See [docs/PRIVACY_BOUNDARIES.md](docs/PRIVACY_BOUNDARIES.md).

---

**Mixnet**: Katzenpost v0.0.99 (pinned `32c27b8`, MLKEM768 PQ wire KEM, 3-hop Sphinx) — built reproducibly for amd64 + arm64.  
**ZK Proofs**: Merkle storage proofs (BLAKE2b), bandwidth proofs, zymkey hardware attestation.  
**Storage**: Autonomi ant-node v0.14.4 with LMDB chunk store — managed via systemd --user.  
**Dev VPS mixnet**: a second v0.0.99 fleet (13 containers) runs on the dev VPS as a remote
testnet gateway — see [VPS Mixnet Deployment](#vps-mixnet-deployment-dev-gateway).

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
│  │  Katzenpost Post-Quantum Mixnet (13-14 containers)       │   │
│  │  dirauth1/2/3 ←→ mix1/2/3 ←→ gateway ←→ servicenode      │   │
│  │  MLKEM768 · BLAKE2b-256 · 3-hop Sphinx · bridge network   │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

- **Layer 1**: Hardware (SCM4/CM4, zymkey HSM, USB drives)
- **Layer 2**: Mixnet (Katzenpost: 3 dirauths + 3 mixes + gateway + servicenode + client daemon)
- **Layer 3**: Proxy (SOCKS5 bridge: ant-node ↔ mixnet via official thin client library)
- **Layer 4**: ZK Proofs (storage-proved Merkle trees, bandwidth proofs, zymkey attestations)
- **Layer 5**: Storage (Autonomi ant-node with LMDB chunk store)
- **Layer 6**: Application (ant CLI, wallet operations)

---

## Quick Start

### On SCM4 (from pre-built images)

```bash
# 1. Load images (air-gapped transfer via SD card)
gunzip -c zknode-autonomi-images.tar.gz | docker load

# 2. Deploy
./scripts/deploy.sh --start

# 3. Monitor
./scripts/monitor.sh
```

### On build machine (cross-compile from amd64)

```bash
# 1. Build all 7 images (cross-compile arm64 from amd64)
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.mixnet -t zeros/mixnet-node:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.ant-node -t zeros/ant-node:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.antd -t zeros/antd:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.mixnet-proxy -t zeros/mixnet-proxy:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.storage-proved -t zeros/storage-proved:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.walletshield -t zeros/walletshield:arm64 .
```

---

## Commands

| Command | Description |
|---------|-------------|
| `./scripts/deploy.sh --check` | Verify prerequisites |
| `./scripts/deploy.sh --start` | Deploy and start stack |
| `./scripts/deploy.sh --stop` | Stop stack |
| `./scripts/deploy.sh --clean` | Stop and remove all data |
| `./scripts/deploy.sh --export` | Export images for air-gapped transfer |
| `./scripts/monitor.sh` | Display stack status |
| `./scripts/setup.sh` | Initialize configs and data dirs |
| `./scripts/setup-zymbit.sh --check` | SCM4 zymkey health check |
| `./scripts/setup-zymbit.sh --full` | Full Zymbit security setup |
| `./scripts/setup-zymbit.sh --encrypt-usb /dev/sdX` | Encrypt USB drive with zymkey |
| `./scripts/gen-wallet.sh --apply` | Generate standard EVM wallet (any machine) |
| `./scripts/gen-wallet.sh` | Generate wallet, print address only |
| `systemctl --user status ant-node` | Check live node status |
| `systemctl --user restart ant-node` | Restart the ant-node service |
| `journalctl --user -u ant-node -f` | Tail live node logs |

---

## VPS Mixnet Deployment (dev gateway)

A second v0.0.99 Katzenpost fleet runs on the dev VPS (`185.92.181.101`, SSH
alias `zknode-mix`) so off-SCM4 / P4P wiki mesh nodes can reach the mixnet.

- **Compose**: `docker-compose.vps.yml` — 13 containers on `katzenpost-net`
  (3 dirauth, 3 mix, gateway, servicenode, 5 storage replicas; courier is an
  embedded CBOR plugin on the servicenode). Topology kept in sync with
  `config/mixnet99/` via `scripts/gen-mixnet99.sh --storageNodes 5`.
- **Public surface**: gateway only — `tcp://185.92.181.101:30007`. Compose
  publishes `[VPS_GATEWAY_BIND]:[VPS_GATEWAY_PORT]:30007`; set
  `VPS_GATEWAY_BIND=185.92.181.101` so the port bind cannot shadow
  host-local services. UFW: 22, 30007 (the native deployment's 30004 was
  retired).
- **PKI/consensus**: descriptors accepted at epoch boundaries (:00/:20/:40
  UTC); the auth serves the doc (`error code 0`). **Restart mixnet nodes only
  at a boundary** — mid-epoch restarts regenerate mix keys and break the
  current consensus document.
- **Remote client** (another machine): run `kpclientd` with a thin
  `[Dial]` config pointing at `tcp://185.92.181.101:30007` (+ gateway/authority
  keys from the PKI), `-listen 127.0.0.1:64331`. Then thin clients
  (walletshield, ping) connect there. Validated: `+echo` 5/5, `+testdest`
  3/3, services reachable are `+echo`, `+http`, `+testdest`, `courier`.
- **walletshield `/ethereum`** (validated HTTP 200, live block):
  ```bash
  docker run -d --name ws-test --network host \
    -v config/walletshield/config.toml:/etc/ws.toml:ro zeros/walletshield:amd64 \
    -config /etc/ws.toml -listen 127.0.0.1:9202 \
    -upstream https://ethereum-rpc.publicnode.com
  curl -X POST http://127.0.0.1:9202/ethereum -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
  ```
  Gotchas:
  - **`-upstream` is required** — without it the handler sends an origin-form
    request line and the mixnet `http-proxy-server` fails with
    `unsupported protocol scheme ""` (then the client times out). The
    absolute-form `-upstream` path works unmodified.
  - On a machine where a `mix-client`/`walletshield-kps` already owns
    `127.0.0.1:9200`, bind the test to a free port (graceful failure).
- **Mesh-node connectivity**: a P4P wiki mesh node joins as a client — run
  `kpclientd` against `tcp://185.92.181.101:30007`, fetch the PKI doc, then
  use thin clients/SOCKS. One open inbound port on the VPS.

---

## Live Node (<node-hostname> SCM4)

```
Peer ID:      <peer-id>
Version:      ant-node 0.14.4
Network:      Autonomi Testnet, Arbitrum Sepolia
Public IP:    <your-public-ip>:12000 (QUIC/UDP)
Wallet:       0x0000...0000 (rewards address)
Service:      systemd --user (enabled, Restart=always, RestartSec=10)
DHT Peers:    ~100 connected
Replication:  Active (/rr/autonomi.ant.replication.v2)
```

---

## Service Status

| Container | Role | Network | RAM |
|-----------|------|---------|-----|
| mix-dirauth-1/2/3 | Directory authorities (PKI consensus) | host | 256MB each |
| mix-1/2/3 | Mix nodes (3-hop Sphinx routing) | host | 256MB each |
| mix-gateway | Client entry point | host | 256MB |
| mix-servicenode | Exit node (echo, proxy-kaetzchen) | host | 256MB |
| mix-client | Client daemon (kpclientd, thin API :64331) | katzenpost-net | 128MB |
| mixnet-proxy | SOCKS5 bridge + ZK proof API :9090 | host | 256MB |
| walletshield | EVM RPC through mixnet :9200 | host | 128MB |
| storage-proved | Merkle/Winterfell storage prover :9201 | autonomi | 128MB |

> **Note**: in the current deploy the mixnet containers run on the
> `katzenpost-net` bridge network (nodes addressed by Docker hostname); the
> client daemon is published on `127.0.0.1:64331`. The VPS fleet
> (`docker-compose.vps.yml`) publishes only the gateway `185.92.181.101:30007`
> and is otherwise identical.
| antd | Autonomi CLI + node manager | bridge | 128MB |
| ant-node | Autonomi storage node (systemd, bare metal) | host :12000 | ~20MB |
| reticulum | Reticulum mesh networking (RNS + LXMF) | host | 128MB |

---

## ZK Proof API

| Endpoint | Description |
|----------|-------------|
| `GET :9090/prove/bandwidth` | Bandwidth proof (Merkle chain) |
| `GET :9090/prove/challenge` | Get storage challenge (proxied to :9201) |
| `POST :9090/prove/storage` | Generate storage proof (proxied to :9201) |
| `GET :9201/status` | Merkle tree state (root, chunk count) |
| `GET :9201/challenge` | Random challenge index |
| `POST :9201/prove` | Generate Merkle proof for challenged index |
| `python3 scripts/zymkey-attest.py` | Hardware attestation via zymkey HSM |

---

## Storage Layout

| Path | Tier | Purpose |
|------|------|---------|
| `./data/mixnet/` | microSD | Mixnet bbolt DBs, keys |
| `./data/antd/` | microSD | Chunk index, metadata |
| `./data/proxy/` | microSD | SURB cache |
| `/mnt/trinity/autonomi/chunks/` | USB pool | LMDB chunk store (1-4 TB) |
| `/mnt/trinity/autonomi/logs/` | USB pool | Rotating logs |
| `/mnt/trinity/backup/` | USB pool | Weekly snapshots |

---

## Prerequisites

- Docker Engine 24+ with Compose v2
- 8GB RAM (16GB recommended for large chunk DB)
- aarch64/arm64 architecture (amd64 works via QEMU for development)
- USB 3.0 drive(s) for chunk storage
- Internet connection (for Autonomi peer connectivity)

---

## File Structure

```
zknode-autonomi/
├── .env                        # Environment config
├── .gitignore
├── docker-compose.yml          # 14-service stack (SCM4)
├── docker-compose.zymkey.yml   # Zymkey HSM override
├── docker-compose.vps.yml      # Dev VPS mixnet fleet (gateway-only publish)
├── Dockerfile.mixnet            # Katzenpost mixnet node (all binaries)
├── Dockerfile.ant-node          # Autonomi storage node
├── Dockerfile.antd              # Autonomi CLI
├── Dockerfile.mixnet-proxy      # SOCKS5 bridge (Go, thin client lib)
├── Dockerfile.storage-proved    # Merkle/Winterfell storage prover
├── Dockerfile.walletshield      # EVM RPC through mixnet
├── cmd/
│   ├── mixnet-proxy/main.go     # Proxy source (thin client API)
│   ├── storage-proved/main.go   # Go Merkle proof daemon
│   ├── storage-proved-rs/       # Rust Winterfell STARK prover (WIP)
│   └── zkclientd/main.go        # Fixed client daemon wrapper
├── config/
│   ├── mixnet/                  # Generated PKI + node configs
│   ├── proxy/config.json        # SOCKS5 proxy config
│   ├── walletshield/config.toml # WalletShield thin client config
│   ├── autonomi/                # Autonomi node/CLI configs
│   └── ant-node/                # Systemd service unit files
├── scripts/
│   ├── deploy.sh                # Deploy/start/stop/export
│   ├── setup.sh                 # Init project structure
│   ├── gen-mixnet-configs.sh    # Mixnet config generator
│   ├── gen-wallet.sh            # EVM wallet generator (eth_keys)
│   ├── monitor.sh               # Stack monitoring
│   ├── storage-layout.sh        # USB pool setup
│   ├── setup-zymbit.sh          # Zymbit/SCM4 setup
│   └── zymkey-attest.py         # Hardware attestation script
├── docs/                        # Full documentation
└── data/                        # Runtime data (gitignored)
```

---

## Known Limitations & Roadmap

| Issue | Status | Notes |
|-------|--------|-------|
| **Zymkey HSM signing** | 🔌 Planned | zymkey stores wallet key in slot 23/24. ant-node code changes needed for HSM-backed EVM transaction signing. |
| **kpclientd epoch sync** | ✅ Resolved | Ping achieves 100% mixnet success; remote clients fetch the PKI doc and use current-epoch docs from the dauth consensus served `error code 0`. |
| **Host networking** | ✅ Resolved | Mixnet containers now use the `katzenpost-net` bridge with hostname-addressed PKI (`AllowHostnameAddresses`); only the VPS gateway is published (`185.92.181.101:30007`). |
| **Remote/gateway access** | ✅ Resolved | `docker-compose.vps.yml` + `VPS_GATEWAY_BIND` connect off-SCM4 mesh nodes to the mixnet through a single public gateway port. |
| **http-proxy URL scheme** | ✅ Workaround | katzenpost `http-proxy-server` fails on origin-form URLs (`unsupported protocol scheme`); walletshield `-upstream` sends absolute-form and bypasses it. |

---

## Documentation

- [P4P Reference Architecture](docs/P4P_ARCHITECTURE.md) — Complete technical reference
- [Live Node Status](docs/LIVE_NODE_STATUS.md) — Active testnet node on SCM4
- [PoC Deployment Plan](docs/POC_DEPLOYMENT_PLAN.md) — Full deployment walkthrough
- [Architecture](docs/ARCHITECTURE.md) — System layers and data flow
- [Hardware Setup](docs/HARDWARE_SETUP.md) — SCM4 hardware, storage, USB pool
- [Zymbit/SCM4 Setup](docs/ZYMBIT_SETUP.md) — zymkey HSM, Bootware, LUKS
- [Mixnet Integration](docs/MIXNET_INTEGRATION.md) — Integration design options
- [Demo Script](docs/DEMO_SCRIPT.md) — 11-step demo walkthrough

---

## License

Source code: AGPL-3.0-only (matches Katzenpost/ZKNetwork licensing).  
Documentation: CC-BY-SA-4.0.

**WARNING**: This is a Proof of Concept. Not production-hardened. Keys are generated for testing only. Actively in development and testing — see [DISCLAIMER.md](DISCLAIMER.md).
