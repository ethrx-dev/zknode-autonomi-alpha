# zknode-autonomi — PoC Deployment Plan

> Package a full Autonomi storage node on SCM4 (8GB RAM, aarch64) with all traffic anonymized through an embedded Katzenpost mixnet. The entire mixnet runs on the same device — no cloud, no VPS.

---

## 1. Architecture Overview

```
                    ┌──────────────────────────────────────────┐
                    │           zknode (SCM4/CM4)              │
                    │                                          │
                    │   antd (CLI)  ◄── docker exec            │
                    │      │                                   │
                    │      ▼                                   │
                    │   ant-node (Autonomi storage node)       │
                    │      │  SOCKS5 proxy @ 127.0.0.1:1080    │
                    │      ▼                                   │
                    │   mixnet-proxy (SOCKS5→mixnet bridge)    │
                    │      │                                   │
                    │      ▼                                   │
                    │   ┌─── Katzenpost mixnet (host net) ───┐ │
                    │   │  3 × dirauth  (PKI consensus)      │ │
                    │   │  3 × mix      (3-hop onion)        │ │
                    │   │  1 × gateway  (client ingress)     │ │
                    │   │  1 × servicenode (mixnet exit)     │ │
                    │   └────────────────────────────────────┘ │
                    │                                          │
                    │    USB pool ── mergerfs ── LUKS (zymkey) │
                    └──────────────────────────────────────────┘
                                  │
                    mixnet exit   │   Autonomi P2P (QUIC)
                                  ▼
                      ┌──────────────────┐
                      │ Autonomi Network │
                      └──────────────────┘
```

**14 Docker containers, all on one SCM4. Mesh networking via host network mode. No VPS.**

---

## 2. Service Inventory

| # | Container | Binary | Network | RAM | Role |
|---|-----------|--------|---------|-----|------|
| 1 | mix-dirauth-1 | dirauth | host | 256MB | PKI authority 1 |
| 2 | mix-dirauth-2 | dirauth | host | 256MB | PKI authority 2 |
| 3 | mix-dirauth-3 | dirauth | host | 256MB | PKI authority 3 |
| 4 | mix-1 | server | host | 256MB | Mix node layer 1 |
| 5 | mix-2 | server | host | 256MB | Mix node layer 2 |
| 6 | mix-3 | server | host | 256MB | Mix node layer 3 |
| 7 | mix-gateway | server | host | 256MB | Client gateway |
| 8 | mix-servicenode | server | host | 256MB | Exit node + echo |
| 9 | mix-client | kpclientd | host | 128MB | Thin client API :64332 |
| 10 | mixnet-proxy | mixnet-proxy | host | 256MB | SOCKS5 + ZK API :9090 |
| 11 | walletshield | walletshield | host | 128MB | EVM RPC :9200 |
| 12 | storage-proved | storage-proved-rs | bridge | 128MB | Winterfell prover :9201 |
| 13 | antd | ant | bridge | 128MB | CLI + node manager |

**Total: ~4 GB RAM** (fits in 8 GB with room for OS + USB I/O cache).

---

## 3. Network Topology

**Mixnet containers** use `network_mode: host` — they share the host's network namespace and communicate via `127.0.0.1`.

**Bridge containers** (antd, storage-proved) use Docker bridge network (`autonomi`).

```
host net:  mix-dirauth-1/2/3 ─┐
           mix-1/2/3         ├── 127.0.0.1:30001-30017
           mix-gateway       │
           mix-servicenode   │
           mix-client        │  127.0.0.1:64332
           mixnet-proxy      │  127.0.0.1:1080,9090
           walletshield ─────┘  127.0.0.1:9200

bridge:    antd (autonomi network)
           storage-proved (autonomi network, :9201)
```

---

## 4. Image Build Strategy

All images cross-compile from amd64 → arm64. No QEMU emulation during builds.

| Image | Source | Build Time | Size |
|-------|--------|------------|------|
| zeros/mixnet-node:arm64 | Katzenpost bfd5fcfc + RocksDB | ~30 min | 1.47 GB |
| zeros/mixnet-proxy:arm64 | Custom (thin client library) | ~5 min | 122 MB |
| zeros/ant-node:arm64 | WithAutonomi/ant-node | ~10 min | 119 MB |
| zeros/antd:arm64 | WithAutonomi/ant-client | ~4 min | 146 MB |
| zeros/storage-proved-rs:arm64 | Custom (Rust/Winterfell) | ~5 min | 109 MB |
| zeros/walletshield:arm64 | ZKNetwork/opt walletshield | ~3 min | 126 MB |

**6 images total** (ant-node not currently in compose — managed via antd CLI).

**Build commands:**
```bash
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.mixnet -t zeros/mixnet-node:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.ant-node -t zeros/ant-node:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.antd -t zeros/antd:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.mixnet-proxy -t zeros/mixnet-proxy:arm64 .
```

### Cross-Compilation Details

- **Go**: `GOOS=linux GOARCH=arm64 CGO_ENABLED=1 CC=aarch64-linux-gnu-gcc`
- **Rust**: `cargo build --target aarch64-unknown-linux-gnu` with `CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc`
- **RocksDB**: `make CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++ shared_lib`
- **Runtime**: `arm64v8/debian:bookworm-slim` (mixnet) or `arm64v8/debian:trixie-slim` (ant-node needs glibc ≥ 2.39)

---

## 5. Config Generation

Mixnet configs are generated by the built-in `genconfig` tool:

```bash
docker run --rm --platform linux/arm64 \
  -v "$(pwd)/config/mixnet:/out" \
  zeros/mixnet-node:arm64 \
  /usr/local/bin/genconfig \
    --voting --wirekem MLKEM768 --nike x25519 \
    --baseDir /var/lib/katzenpost --outDir /out \
    --layers 3 --nodes 3 --gateways 1 --serviceNodes 1 \
    --nrVoting 3 --noMetrics --logLevel DEBUG
```

Generated configs produce valid TOML with full SphinxGeometry, PKI keys, and voting authority config. All PKI keys (`.pem`, `.key`) are gitignored — regenerated per deployment.

**Post-generation fixes applied automatically:**
1. Servicenode CBOR plugins disabled (courier/http-proxy — binary path mismatch)
2. Data directories set to `chmod 700` (katzenpost security requirement)

---

## 6. Known Issues & Mitigations

| Issue | Impact | Mitigation |
|-------|--------|------------|
| Dirauth consensus race | All 3 must be running simultaneously to form PKI | `while true` retry loop in entrypoint (2s delay) |
| LMDB mmap ENOMEM | ant-node won't start on containers with memory limits | `privileged: true` + `vm.overcommit_memory=1` |
| Data dir permissions | Katzenpost requires 700 (owner-only) on DataDir | `chmod 700` applied in setup |
| Walletshield config mismatch | v0.0.64 client vs v0.0.73-rc3 mixnet | Removed from compose; rebuild needed against v0.0.73-rc3 |
| Host networking limitation | Only one instance per port | Fine for PoC; production needs bridge networking with BindAddresses |

---

## 7. Air-Gapped Deployment Flow

```bash
# === ON BUILD MACHINE (amd64) ===
cd zknode-autonomi/

# Build images (30-60 min total)
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.mixnet -t zeros/mixnet-node:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.ant-node -t zeros/ant-node:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.antd -t zeros/antd:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.mixnet-proxy -t zeros/mixnet-proxy:arm64 .

# Export
docker save zeros/mixnet-node:arm64 zeros/ant-node:arm64 \
  zeros/antd:arm64 zeros/mixnet-proxy:arm64 | gzip > zknode-autonomi-images.tar.gz

# Transfer (SD card or scp)
cp zknode-autonomi-images.tar.gz /media/sdcard/

# === ON SCM4 (aarch64) ===
git clone <repo-url> zknode-autonomi
cd zknode-autonomi

# Load images
gunzip -c /media/sdcard/zknode-autonomi-images.tar.gz | docker load

# Deploy
./scripts/deploy.sh --start

# Monitor
./scripts/monitor.sh
```

---

## 8. Verification Checklist

- [ ] All 15 containers running (`docker compose ps`)
- [ ] mix-dirauth-1/2/3 stable (retry loop keeps them up)
- [ ] mixnet-proxy API: `curl http://127.0.0.1:9090/status` → `mixnet_connected: true`
- [ ] Mixnet echo test: SOCKS5 "Hello!" returns in ~3s
- [ ] Ping binary: 100% success rate
- [ ] ZK bandwidth proof: `curl http://127.0.0.1:9090/prove/bandwidth`
- [ ] WalletShield: `curl http://127.0.0.1:9200` → 200
- [ ] Storage prover: `docker logs storage-proved` shows "listening on 0.0.0.0:9201"

---

## 9. Next Steps

1. **Register ant-node on-chain** — wallet funded (0.04 ETH on Arbitrum Sepolia)
2. **Bridge networking** — replace host networking for production multi-instance isolation
3. **Zymkey HSM signing** — ant-node code changes for HSM-backed EVM transactions
4. **USB pool setup** — LUKS encrypted chunk storage on external drives
