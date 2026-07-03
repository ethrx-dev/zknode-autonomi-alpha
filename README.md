# zknode-autonomi — P4P Reference Architecture

**Post-Quantum Mixnet + ZK Storage Proving + Autonomi P2P Storage**

A self-contained private Autonomi storage node with traffic routed through an embedded post-quantum Katzenpost mixnet, hardware-bound ZK storage proofs, and metadata-private P2P communication. Built for the SCM4/CM4 platform as a reference architecture for the P2P Foundation's proof-of-useful-work movement.

**Hardware**: SCM4/CM4 (8GB RAM, aarch64) with zymkey HSM.  
**Mixnet**: Katzenpost v0.0.73-rc3+ (MLKEM768 PQ wire KEM, BLAKE2b-256 hashing, 3-hop Sphinx).  
**ZK Proofs**: Merkle storage proofs (BLAKE2b), bandwidth proofs, zymkey hardware attestation.  
**Storage**: Autonomi ant-node with LMDB chunk store on USB pool.

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
│  │  Katzenpost Post-Quantum Mixnet (14 containers)          │   │
│  │  dirauth1/2/3 ←→ mix1/2/3 ←→ gateway ←→ servicenode      │   │
│  │  MLKEM768 · BLAKE2b-256 · 3-hop Sphinx · host networking │   │
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

---

## Service Status

| Container | Role | Network | RAM |
|-----------|------|---------|-----|
| mix-dirauth-1/2/3 | Directory authorities (PKI consensus) | host | 256MB each |
| mix-1/2/3 | Mix nodes (3-hop Sphinx routing) | host | 256MB each |
| mix-gateway | Client entry point | host | 256MB |
| mix-servicenode | Exit node (echo, proxy-kaetzchen) | host | 256MB |
| mix-client | Client daemon (kpclientd, thin API :64332) | host | 128MB |
| mixnet-proxy | SOCKS5 bridge + ZK proof API :9090 | host | 256MB |
| walletshield | EVM RPC through mixnet :9200 | host | 128MB |
| storage-proved | Merkle/Winterfell storage prover :9201 | bridge | 128MB |
| antd | Autonomi CLI + node manager | bridge | 128MB |

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
├── docker-compose.yml          # 14-service stack
├── docker-compose.zymkey.yml   # Zymkey HSM override
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
│   └── autonomi/                # Autonomi node/CLI configs
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

| Issue | Status | Resolution |
|-------|--------|------------|
| **Host networking** | 🔶 Planned | Mixnet containers share host network. Bridge networking with BindAddresses in katzenpost.toml for production multi-instance isolation. |
| **Dirauth startup race** | ✅ Mitigated | Entrypoints use `while true; do ...; sleep 2; done` retry loops. All 3 auths converge within 2 epochs after clean restart. |
| **LMDB overcommit_memory** | 🔶 Available | ant-node needs `vm.overcommit_memory=1` for LMDB mmap. Set `privileged: true` on the antd container. |
| **walletshield** | ✅ Fixed | Rebuilt with matching Sphinx geometry (PacketLength=3082). Running in compose at `:9200` connected to kpclientd on :64332. |
| **Zymkey HSM signing** | 🔌 Planned | zymkey stores wallet key in slot 23/24. ant-node code changes needed for HSM-backed EVM transaction signing. |
| **kpclientd epoch sync** | 🔶 Workaround | Ping binary achieves 100% mixnet success. kpclientd PKI doc retrieval uses `currentDocument()` fallback — needs auth restarted at epoch start for full consensus with node descriptors. |
| **Bridge network isolation** | 📋 Future | Each mixnet node on unique bridge network with BindAddress for production multi-tenant deployments. |
| **Rust Winterfell STARKs** | 🚧 WIP | `cmd/storage-proved-rs/` project structure created. Go Merkle prover deployed as reference. |

---

## Documentation

- [P4P Reference Architecture](docs/P4P_ARCHITECTURE.md) — Complete technical reference
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

**WARNING**: This is a Proof of Concept. Not production-hardened. Keys are generated for testing only.
