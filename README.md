# zknode-autonomi

**Any old computer can become a private Autonomi node.**

A self-contained anonymous Autonomi storage node that routes all P2P traffic through an embedded Katzenpost mixnet. No VPS, no cloud dependency — the entire mixnet runs on the same device as the storage node.

**Hardware**: SCM4/CM4 (8GB RAM, aarch64) or any machine with 8GB RAM + Docker.  
**Storage**: microSD for performance-critical data, USB pool (1-4 TB) for chunk storage.  
**Security**: zymkey HSM, LUKS encryption, tamper detection, post-quantum cryptography.

---

## Architecture

```
ant-node ──SOCKS5──▶ mixnet-proxy ──3-hop──▶ mix-servicenode ──QUIC──▶ Autonomi peers
                         │                                              (see mixnet exit IP,
                     200 lines                                        never SCM4's real IP)
                     of Go code
```

- **Layer 1**: Hardware (SCM4/CM4, zymkey HSM, USB drives)
- **Layer 2**: Mixnet (Katzenpost: 3 dirauths + 3 mixes + gateway + servicenode)
- **Layer 3**: Proxy (SOCKS5 bridge: ant-node ↔ mixnet)
- **Layer 4**: Storage (Autonomi ant-node with LMDB chunk store)
- **Layer 5**: Application (ant CLI, REST/gRPC SDK)

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
# 1. Build all 5 images
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.mixnet -t zeros/mixnet-node:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.ant-node -t zeros/ant-node:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.antd -t zeros/antd:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.mixnet-proxy -t zeros/mixnet-proxy:arm64 .

# 2. Export for transfer
./scripts/deploy.sh --export

# 3. Transfer to SCM4
cp zknode-autonomi-images.tar.gz /media/sdcard/
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
| mix-1/2/3 | Mix nodes (3-hop onion routing) | host | 256MB each |
| mix-gateway | Client gateway | host | 256MB |
| mix-servicenode | Mixnet exit node | host | 256MB |
| mixnet-proxy | SOCKS5 bridge (ant-node ↔ mixnet) | host | 256MB |
| ant-node | Autonomi storage node | bridge | 2GB+ |
| antd | Autonomi CLI | bridge | 128MB |

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
├── docker-compose.yml           # 10-service stack
├── Dockerfile.mixnet            # Katzenpost mixnet node
├── Dockerfile.ant-node          # Autonomi storage node
├── Dockerfile.antd              # Autonomi CLI
├── Dockerfile.mixnet-proxy      # SOCKS5 bridge
├── cmd/mixnet-proxy/main.go     # Proxy source
├── config/
│   ├── mixnet/                  # Generated mixnet PKI + node configs
│   ├── proxy/config.json        # SOCKS5 proxy config
│   └── autonomi/                # Autonomi node/CLI configs
├── scripts/
│   ├── deploy.sh                # Deploy/start/stop/export
│   ├── setup.sh                 # Init project structure
│   ├── gen-mixnet-configs.sh    # Mixnet config generator
│   ├── monitor.sh               # Stack monitoring
│   └── storage-layout.sh        # USB pool setup
├── data/                        # Runtime data (gitignored)
└── docs/                        # Full documentation
```

---

## Known Limitations

- **Host networking**: Mixnet containers share the host network (only one instance per port). For production isolation, switch to bridge networking with BindAddresses.
- **Dirauth startup race**: All 3 authorities must be running to reach consensus. Mitigated by internal retry loops in container entrypoints.
- **LMDB memory**: ant-node needs `vm.overcommit_memory=1` for LMDB mmap (enabled via privileged mode).
- **walletshield**: Built but not included in compose — uses katzenpost v0.0.64 client config, incompatible with our v0.0.73-rc3 mixnet. Rebuilding with a version-aligned Dockerfile would fix this.
- **Zymkey integration**: Hardware wallet keys stored in HSM; rewards address auto-set. Full HSM transaction signing requires ant-node code changes.

---

## Documentation

- [PoC Deployment Plan](docs/POC_DEPLOYMENT_PLAN.md) — Full deployment walkthrough
- [Architecture](docs/ARCHITECTURE.md) — System layers and data flow
- [Hardware Setup](docs/HARDWARE_SETUP.md) — SCM4 hardware, storage, USB pool
- [Zymbit/SCM4 Setup](docs/ZYMBIT_SETUP.md) — zymkey HSM, Bootware, LUKS, tamper, wallet, production lock
- [Mixnet Integration](docs/MIXNET_INTEGRATION.md) — Integration design options
- [Demo Script](docs/DEMO_SCRIPT.md) — 11-step demo walkthrough
- [Collaboration Proposal](docs/ZKNETWORK_AUTONOMI_COLLABORATION.md) — ZKNetwork × Autonomi collaboration

---

## License

Source code: AGPL-3.0-only (matches Katzenpost/ZKNetwork licensing).  
Documentation: CC-BY-SA-4.0.

**WARNING**: This is a Proof of Concept. Not production-hardened. Keys are generated for testing only.
