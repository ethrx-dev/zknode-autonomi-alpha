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

**14 Docker containers + host services, all on one SCM4. Mesh networking via host network mode. No VPS.**

**New in this release:**
- **Dashboard container** (zknode-dashboard) — web UI with live mixnet, mesh, ant, and zymkey status on port 8080
- **Mesh tab** — Reticulum transport status, WiFi IBSS panel, live interface table, NomadNet pages, P4P wiki stats
- **Reticulum mesh stack** — rnsd systemd service + NomadNet daemon + WiFi IBSS (zknode-mesh, channel 1)
- **Walletshield fix** — forked thin client with proper `isConnected` tracking, built as `FROM scratch` (17MB)
- **AI pipeline** — chatd sends AI responses with `Sender: []byte("ai")` for dashboard rendering
- **CORS proxy** — rpc-proxy container at :9292 for MetaMask access to walletshield
- **P4P wiki editable UI** — in-dashboard page editor with slug/textarea, commit-to-git workflow

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
| 14 | zknode-dashboard | Node.js | host | 256MB | Web UI :8080 |
| 15 | rpc-proxy | caddy/node | host | 64MB | CORS proxy :9292 |

**Total: ~4.5 GB RAM** (fits in 8 GB with room for OS + USB I/O cache).

---

## 3. Network Topology

**Mixnet containers** use `network_mode: host` — they share the host's network namespace and communicate via `127.0.0.1`.

**Bridge containers** (antd, storage-proved) use Docker bridge network (`autonomi`).

```
host net:  mix-dirauth-1/2/3 ─┐
           mix-1/2/3          ├── 127.0.0.1:30001-30017
           mix-gateway        │
           mix-servicenode    │
           mix-client         │  127.0.0.1:64332
           mixnet-proxy       │  127.0.0.1:1080,9090
           walletshield  ─────┘  127.0.0.1:9200

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

## 7. Dashboard — Web UI

A self-contained Node.js/Express dashboard on port 8080 provides live status for all zknode subsystems.

### Dashboard Tabs

| Tab | Endpoints | Shows |
|-----|-----------|-------|
| **Mixnet** | `/api/mixnet` | PKI epoch, consensus hash, node topology (from auth logs) |
| **Mesh** | `/api/mesh/status`, `/api/mesh/nomadnet`, `/api/mesh/rns` | RNS transport, WiFi mesh, interfaces table, NomadNet pages, P4P wiki stats |
| **Ant** | `/api/ant` | ant-node PID, port, uploads/downloads |
| **Zymbit** | `/api/zymbit` | HSM device status, firmware, API health |
| **Wiki** | `/api/wiki/*` | Wiki page browser, inline editor with write+commit |

### Mesh Tab Panels

```
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ RNS TRANSPORT   │ │ WIFI MESH       │ │ INTERFACES      │
│ · Transport ID  │ │ · SSID          │ │ (span 2 rows)   │
│ · Uptime        │ │ · Mode (IBSS)   │ │ Name · Type     │
│ · Interfaces    │ │ · Channel       │ │ Status · Peers  │
│ · TX/RX         │ │ · TX Power      │ │ TX · RX         │
│                 │ │ · TCP Port 4242 │ │                 │
├─────────────────┤ ├─────────────────┤ │                 │
│ RETICULUM       │ │ NOMADNET        │ │                 │
│ · Service (rnsd)│ │ · Status        │ │                 │
│ · PID           │ │ · Pages         │ │                 │
│ · Identity      │ │ · Recent Log    │ │                 │
│ · Pages         │ │                 │ │                 │
├─────────────────┴┴─────────────────┴┤                 │
│ P4P WIKI (full width)               │                 │
│ · Wiki pages · STATS · PUBLISHED    │                 │
│ · NomadNet pages count              │                 │
└─────────────────────────────────────┴─────────────────┘
```

### Reticulum Mesh API

`/api/mesh/rns` returns live data from `rnstatus -j` + `iw dev wlan0 info`:

```json
{
  "transport_id": "6560de0c545854a8448008a4bca1c1ba",
  "uptime": 3600,
  "traffic": { "txb": 0, "rxb": 0 },
  "interfaces": [
    {
      "name": "AutoInterface",
      "type": "UDP",
      "status": "Up",
      "peers": 3,
      "rxb": 4096,
      "txb": 2048
    }
  ],
  "wifi": {
    "ssid": "zknode-mesh",
    "channel": "1",
    "type": "IBSS",
    "txpower": "20.00"
  },
  "paths": []
}
```

### Wiki Editor UI

The dashboard includes a full inline wiki page editor:

- **+NEW** button creates a new page with slug prompt
- **EDIT** button opens inline editor for any existing page
- Title, slug, and markdown textarea fields
- **SAVE** writes the page through MCP tools (`/api/wiki/page/write`, `/api/wiki/commit`)
- Git commit hash returned after each save

---

## 8. Air-Gapped Deployment Flow

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

## 9. Verification Checklist

- [ ] All 15 containers running (`docker compose ps`)
- [ ] Dashboard reachable: `curl http://192.168.9.118:8080` → 200
- [ ] Mesh API: `curl http://192.168.9.118:8080/api/mesh/rns` → JSON with interfaces
- [ ] Reticulum transport: `systemctl status rnsd` → active (running)
- [ ] mix-dirauth-1/2/3 stable (retry loop keeps them up)
- [ ] mixnet-proxy API: `curl http://127.0.0.1:9090/status` → `mixnet_connected: true`
- [ ] Mixnet echo test: SOCKS5 "Hello!" returns in ~3s
- [ ] Ping binary: 100% success rate
- [ ] ZK bandwidth proof: `curl http://127.0.0.1:9090/prove/bandwidth`
- [ ] WalletShield: `curl http://127.0.0.1:9200` → 200
- [ ] Storage prover: `docker logs storage-proved` shows "listening on 0.0.0.0:9201"

---

## 10. Next Steps

1. ~~**Register ant-node on-chain** — wallet funded (0.04 ETH on Arbitrum Sepolia)~~ **DONE** — Node live on Autonomi Testnet since 2026-07-03. See [Live Node Status](LIVE_NODE_STATUS.md).
2. **Bridge networking** — replace host networking for production multi-instance isolation
3. **Zymkey HSM signing** — ant-node code changes for HSM-backed EVM transactions
4. **USB pool setup** — LUKS encrypted chunk storage on external drives

---

## 11. Actual Deployment Notes

### What Works

- **ant-node v0.14.2** running on zknode SCM4 via `systemd --user`
- **Binary runs directly on host** — statically linked ARM64, no Docker dependency for ant-node
- **Node is discoverable** — public IP 12.34.56.789:12000, confirmed by multiple DHT peers
- **Replication active** — `/rr/autonomi.ant.replication.v2` protocol traffic flowing
- **Auto-restart** — systemd `Restart=always` with 10s backoff
- **LMDB storage** — chunks.mdb + paid_list.mdb working

### What Differs from the Container Plan

- ant-node runs as **systemd --user service**, not as a Docker container
- The compose `ant-node` service image was never built (cross-compile from source is slow)
- Workaround: binary downloaded directly from Autonomi releases, installed at `~/zknode-autonomi/data/antd/`
- No permission issues when running as the correct user (<node-user>, uid 1001)
- The `antd` CLI daemon crashes due to bind mount UID conflicts in the container — this is bypassed

### Reticulum Mesh — Host Services

Reticulum stack runs directly on the host (not in Docker) for direct WiFi interface access:

| Service | Binary | Config | Status |
|---------|--------|--------|--------|
| `rnsd` | `rnsd -s` (Python) | `~/.reticulum/config` | systemd service (user zero-tech) |
| `nomadnet` | `nomadnet --daemon` | `~/nomadnet-new/` | Manual start (no systemd unit) |
| WiFi IBSS | `iw` + `iwconfig` | wlan0, SSID `zknode-mesh`, ch 1 | Interface mode set at boot |

**RNS Config** (`~/.reticulum/config`):
- `enable_transport = Yes`
- `share_instance = Yes`
- Interfaces: AutoInterface (UDP link-local), TCPServerInterface (:4242), AutoInterface with wifi_adhoc
- Transport identity: `6560de0c545854a8448008a4bca1c1ba`

**WiFi IBSS Setup** (executed once, persists until reboot):
```bash
sudo iw dev wlan0 set type ibss
sudo ip link set wlan0 up
sudo iw dev wlan0 ibss join zknode-mesh 2412
```

### Zymkey HSM — API Fix

The `zymkey-api.service` needed device path correction. The SCM module presents as `/dev/zscm_1` (ttyACM1), not the default `/dev/zscm_8`:
- Service file: `/etc/systemd/system/zymkey-api.service`
- `ZYMKEY_DEV=/dev/zscm_1`
- `ZYMKEY_API_PORT=8765`
- Dashboard reads device status via `/dev/zscm_1` presence and API health check

### Walletshield — Thin Client Fork

The original `ZKNetwork/opt` walletshield used a thin client library incompatible with the v0.0.73 mixnet. Fix:
- Forked `thin/` package with corrected `isConnected` field tracking
- Built as `FROM scratch` (17MB vs 126MB)
- Host port 9200, CORS proxy on port 9292 (`rpc-proxy` container)
- MetaMask uses RPC URL `http://192.168.9.118:9292`

### Dashboard — Container Notes

The dashboard runs in Docker (`host` networking) and serves from:
- `/home/zero-tech/zknode-autonomi/zknode-dashboard/server/index.js` — API endpoints
- `/home/zero-tech/zknode-autonomi/zknode-dashboard/index.html` — Frontend

**Known issue**: The dashboard code is in `.gitignore` (local monitoring only). Server is a Node.js Express app with shell-command-based data collection.

### AI Chat Pipeline Fix

Chatd (`cmd/chatd/main.go:366`) sends AI responses with `Sender: []byte("ai")` instead of empty bytes, so the hex sender `6169` is parseable by the dashboard message renderer.

### Systemd Quick Start

```bash
# Install ant-node (on SCM4)
mkdir -p ~/.config/systemd/user/
cp config/ant-node/ant-node.service ~/.config/systemd/user/
systemctl --user daemon-reload
loginctl enable-linger
systemctl --user enable --now ant-node

# Monitor
systemctl --user status ant-node
journalctl --user -u ant-node -f
```

### Next Steps for SCM4 Recovery

The SCM4 unit is currently in **Supervised Boot failure** state after a `config.txt` modification (`dtparam=spi=on`). The blue LED shows constant rapid blinking — SCM in Production Mode holding CM4 in reset due to Manifest signature mismatch. Contact Zymbit support for recovery guidance.
