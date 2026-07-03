# zknode-autonomi P4P — Reference Architecture

**Post-Quantum Mixnet + ZK Storage Prover + Autonomi P2P Storage**

A self-contained private Autonomi storage node with traffic anonymized through an embedded post-quantum mixnet, hardware-bound ZK storage proofs, and arbitrary-scale data proving. Designed for the SCM4/CM4 platform.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    zknode (SCM4 / CM4)                          │
│  8GB RAM · aarch64 · zymkey HSM · USB 3.0 pool                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐  SOCKS5  ┌─────────────────┐  PQ Mixnet       │
│  │   ant-node   │◄────────►│  mixnet-proxy   │◄─────────────────┤
│  │  (Autonomi)  │  :1080   │  (Go/Rust)      │                  │
│  │  :12000      │          │  :9090 mgmt API │                  │
│  └──────┬───────┘          └────────┬────────┘                  │
│         │                           │                           │
│         │ chunk data                │ ZK proofs                 │
│         ▼                           ▼                           │
│  ┌──────────────┐          ┌─────────────────┐                  │
│  │  LMDB Chunk  │          │ storage-proved  │                  │
│  │  Store       │◄────────►│ (Rust/Winfell)  │                  │
│  │  /mnt/chunks │  mmap    │  :9201 API      │                  │
│  └──────────────┘          └────────┬────────┘                  │
│                                     │                           │
│                            ┌────────┴─────────┐                 │
│                            │ zymkey HSM (I²C) │                 │
│                            │  HW Attestation  │                 │
│                            └──────────────────┘                 │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Katzenpost Post-Quantum Mixnet (host networking)        │   │
│  │                                                          │   │
│  │  ┌──────────┐  ┌────────┐  ┌────────┐  ┌──────────────┐  │   │
│  │  │dirauth 1 │  │ mix-1  │  │gateway │  │ servicenode  │  │   │
│  │  │dirauth 2 │◄►│ mix-2  │◄►│  :30004│◄►│ :30007       │  │   │
│  │  │dirauth 3 │  │ mix-3  │  │        │  │ (echo/proxy) │  │   │
│  │  └──────────┘  └────────┘  └────────┘  └──────────────┘  │   │
│  │                                                          │   │
│  │  PKI epoch 238999 · MLKEM768 · BLAKE2b-256 · 3-hop       │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Post-Quantum Mixnet (Katzenpost)

| Component | Image | Role | Crypto |
|-----------|-------|------|--------|
| `mix-dirauth-1/2/3` | `zeros/mixnet-node` | Directory authorities | Ed25519 + MLKEM768 |
| `mix-1/2/3` | `zeros/mixnet-node` | Mix nodes (3-hop) | Sphinx + MLKEM768 |
| `mix-gateway` | `zeros/mixnet-node` | Client entry point | MLKEM768 wire KEM |
| `mix-servicenode` | `zeros/mixnet-node` | Service exit node | Echo, testdest, proxy-kaetzchen |
| `mix-client` | `zeros/mixnet-node` | Client daemon (kpclientd) | Thin client API on :64332 |

**Upgraded** to commit `bfd5fcfc` (11 commits past v0.0.73-rc3):
- Nil PKIClient guard fix
- Consensus fetch timing improvements
- PKI document caching fixes

### 2. SOCKS5 Mixnet Proxy

**Language:** Go (thin client library)  

**Endpoints:**
- `:1080` — SOCKS5 proxy (ant-node → mixnet)
- `:9090/status` — Health/status
- `:9090/prove/bandwidth` — Bandwidth proof
- `:9090/prove/challenge` — Storage challenge proxy
- `:9090/prove/storage` — Storage proof proxy

### 3. Storage Prover

**Language:** Go (upgradeable to Rust/Winterfell)  

**API (`:9201`):**
- `GET /status` — Tree state (root, chunk count)
- `GET /challenge` — Random challenge index
- `POST /prove` — Generate Merkle proof for challenged index

### 4. Hardware Attestation

**Script:** `scripts/zymkey-attest.py` (Python/zymkey SDK)

Generates ECDSA-signed attestation over `merkle_root:node_address:serial` using the zymkey HSM's signing key. Binds hardware identity to storage commitment.

## Deployment

### Prerequisites

- Docker Engine 24+ with Compose v2
- Docker buildx with QEMU arm64 support
- 8GB RAM minimum
- aarch64/arm64 target (SCM4) or amd64 (development)
- SCM4 with zymkey HSM (for attestation)

### Build (from amd64 builder)

```bash
# All 7 images
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.mixnet -t zeros/mixnet-node:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.ant-node -t zeros/ant-node:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.antd -t zeros/antd:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.mixnet-proxy -t zeros/mixnet-proxy:arm64 .
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.storage-proved -t zeros/storage-proved:arm64 .
```

### Transfer to SCM4

```bash
# Stream images directly
docker save zeros/mixnet-node:arm64 | gzip | ssh zero-tech@192.168.9.118 'gunzip -c | docker load'

# Project files
rsync -avz ./ zero-tech@192.168.9.118:~/zknode-autonomi/ \
  --exclude='.git' --exclude='katzenpost/' --exclude='data/'
```

### Start

```bash
cd ~/zknode-autonomi
docker compose up -d
# PKI consensus takes ~2 min after fresh start
# Wait for: "PKI doc available" in mix-client logs
```

## ZK Proof Pipeline

### Storage Proof

```bash
# Get challenge
challenge=$(curl -s http://storage-proved:9201/challenge)

# Generate proof
curl -s -X POST http://storage-proved:9201/prove \
  -H "Content-Type: application/json" \
  -d "$challenge"

# Verify via proxy
curl -s http://127.0.0.1:9090/prove/bandwidth
```

### Hardware Attestation

```bash
# On SCM4:
python3 scripts/zymkey-attest.py \
  --merkle-root $(curl -s http://storage-proved:9201/status | jq -r .merkle_root)

# Verify:
python3 scripts/zymkey-attest.py --verify attestation.json
```

## Rust Porting Roadmap

| Phase | Component | Description | Status |
|-------|-----------|-------------|--------|
| 1 | `storage-proved-rs` | Winterfell STARK prover (proper AIR) | 🔜 Next |
| 2 | `mixnet-proxy-rs` | Async SOCKS5 + thin client in Rust | 📋 Planned |
| 3 | `zkclientd-rs` | Custom client daemon (fixes kpclientd epoch issue) | 📋 Planned |
| 4 | `zymkey-attest-rs` | Rust zymkey bindings + attestation | 📋 Planned |

### Phase 1: Winterfell STARKs

The Rust storage prover will implement a proper **Proof of Correct Storage** AIR:

```
Public inputs: Merkle root R, challenge index i
Private inputs: File segment S, Merkle path P
Statement: S at position i in tree with root R
Proof: Winterfell STARK proving Merkle path validity
```

Benefits over Go Merkle proofs:
- **Constant-size proofs** (~100KB regardless of file size)
- **Zero-knowledge** — verifier learns nothing about file content
- **Recursive proving** — aggregate multiple proofs into one
- **Post-quantum** — Winterfell uses Rescue hash (PQ-secure)
