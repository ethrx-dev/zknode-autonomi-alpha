# zknode Working State — Reference

> **Purpose**: Document the exact working state of the zknode SCM4 system as of 2026-07-18. The device suffered a Supervised Boot failure after a `config.txt` edit. This document captures everything needed to recreate the exact environment.

---

## 1. Hardware

| Component | Detail |
|-----------|--------|
| Board | Zymbit SEN400 SCM4 (CM4 + Zymbit Security Module) |
| RAM | 8GB |
| Storage | eMMC (OS), USB 3.0 pool (data) |
| HSM | ZSCM Secure Boot Gateway, firmware `01.02.02release`, serial `2712AF4B7AC2F93FD13F8B33BA15A44C36C52F2F1495246261BBC0FEE6D52475` |
| WiFi | wlan0 — IBSS mesh (see §5) |
| GPIO | SPI enabled (`dtparam=spi=on` in `/boot/config.txt`) — awaiting RNode LoRa |
| IP | `<node-ip>` (static on `192.168.9.0/24`) |

### Failure Mode

The SCM blue LED shows **constant rapid blinking**: SCM in Production Mode, holding CM4 in reset due to Supervised Boot signature mismatch. The `config.txt` was modified (uncommented `dtparam=spi=on`) without updating the SCM Manifest. **Unrecoverable without Zymbit support** — encrypted eMMC cannot be reimaged via `rpiboot` in the field when bind-locked.

---

## 2. OS & Users

- **OS**: Debian bookworm (aarch64) — preinstalled Zymbit image
- **User**: `<node-user>` (primary ops user)
- **Passwords**: `r00ts3cur3` (sudo)
- **SSH key**: `~/.ssh/id_ed25519_zk` (on build machine, `~/.ssh/id_ed25519_zk.pub` on SCM4)
- **Hostname**: `<node-hostname>` (via `/etc/hosts` on LAN: `<node-ip> <node-hostname>.local`)

---

## 3. Docker Containers

All 15 containers use `network_mode: host` (mixnet + dashboard + proxy). Managed via `docker compose` in `/home/<node-user>/zknode-autonomi/`.

| # | Container | Image | Ports | Role |
|---|-----------|-------|-------|------|
| 1 | `mix-dirauth-1` | `zeros/mixnet-node:arm64` | 30001 | PKI authority 1 |
| 2 | `mix-dirauth-2` | `zeros/mixnet-node:arm64` | 30002 | PKI authority 2 |
| 3 | `mix-dirauth-3` | `zeros/mixnet-node:arm64` | 30003 | PKI authority 3 |
| 4 | `mix-1` | `zeros/mixnet-node:arm64` | 30011-30012 | Mix node layer 1 |
| 5 | `mix-2` | `zeros/mixnet-node:arm64` | 30013-30014 | Mix node layer 2 |
| 6 | `mix-3` | `zeros/mixnet-node:arm64` | 30015-30016 | Mix node layer 3 |
| 7 | `mix-gateway` | `zeros/mixnet-node:arm64` | 30004 | Client gateway |
| 8 | `mix-servicenode` | `zeros/mixnet-node:arm64` | 30007 | Exit node + echo |
| 9 | `mix-client` | `zeros/mixnet-node-fixed:v0.0.84` | 64332 | kpclientd thin client |
| 10 | `mixnet-proxy` | `zeros/mixnet-proxy:arm64` | 1080, 9090 | SOCKS5 + API |
| 11 | `walletshield` | `zeros/walletshield:arm64` | 9200 | EVM RPC (patched) |
| 12 | `storage-proved` | `zeros/storage-proved-rs:arm64` | 9201 | Winterfell prover |
| 13 | `antd` | `zeros/antd:arm64` | bridge | CLI + node manager |
| 14 | `zknode-dashboard` | `zknode-dashboard:latest` | 8080 | Web UI (host net) |
| 15 | `rpc-proxy` | (systemd or container) | 9292 | CORS proxy for MetaMask |

### Mixnet PKI State (epoch 240035 as of last known good)

- **Genesis epoch**: 240005
- **Epoch length**: ~20 minutes
- **Nodes**: 1 gateway (gateway1), 1 service node (servicenode1), 3 mix nodes, 3 dirauths
- **Consensus hash**: `5bc5fded67b166984f9de789df53eceb485f90eb0af0f53a140c38f775e93637`
- **Sphinx geometry**: `UserForwardPayloadLength = 2000` max per packet
- **KEM**: MLKEM768, NIKE: x25519

### Important Config Paths

- Docker compose: `/home/<node-user>/zknode-autonomi/docker-compose.yml`
- Dashboard server: `/home/<node-user>/zknode-autonomi/zknode-dashboard/server/index.js`
- Dashboard HTML: `/home/<node-user>/zknode-autonomi/zknode-dashboard/public/index.html`
- Wiki data: `/home/<node-user>/wikis/p2p-infrastructure/wiki/`
  - 497 wiki pages (P2P Foundation archive)
  - Managed by llm-wiki MCP tools on port 18765
- NomadNet data: `/home/<node-user>/nomadnet-new/` → mounted at `/var/nomadnet/` in containers

---

## 4. Dashboard Web UI (port 8080)

The dashboard is a Node.js/Express app with these tabs/pages:

### Tabs

| Tab | Endpoints | What it shows |
|-----|-----------|---------------|
| **Mixnet** | `/api/mixnet` | PKI epoch, consensus hash, node topology (parsed from auth logs via `docker exec`) |
| **Mesh** | `/api/mesh/status`, `/api/mesh/nomadnet`, `/api/mesh/rns` | RNS transport identity/uptime/interfaces, WiFi IBSS info, NomadNet pages, P4P wiki stats |
| **Ant** | `/api/ant` | ant-node PID, port, daemon status, node list, recent logs |
| **Zymbit** | `/api/zymbit` | HSM device status, firmware version, API health |
| **Wiki** | `/api/wiki/*` | Wiki page browser, inline editor with slug + markdown textarea, commit-to-git workflow |

### Key Dashboard API Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /api/mesh/rns` | Live `rnstatus -j` JSON + `iw dev wlan0 info` WiFi data |
| `GET /api/mesh/status` | Reticulum/nomadnet process status + page counts |
| `GET /api/mesh/nomadnet` | NomadNet page listing, config, recent log |
| `GET /api/mixnet` | Auth log parsing for epoch/consensus/node topology |
| `POST /api/wiki/page/write` | Write/update a wiki page via MCP |
| `POST /api/wiki/commit` | Commit wiki changes to git |

### Dashboard Patch Notes (applied to server/index.js)

1. **Replace hardcoded PID 814** with `pgrep("nomadnet")` / `pgrep("rnsd")` — PIDs change on restart
2. **Add `/api/mesh/rns` endpoint** — fetches `rnstatus -j` JSON and parses `iw dev wlan0 info` output
3. **Fix mixnet node counting** — `grep 'Identifier'` → `grep 'servicenode'`/`grep 'gateway'` (auth log uses different terms)
4. **Fix shell quoting** — template literals with backticks instead of string concatenation for `docker exec` commands
5. **Add wiki page count** — reads `/home/<node-user>/wikis/p2p-infrastructure/wiki/` directory listing
6. **Add nomadnet page count** — reads `/var/nomadnet/pages/` directory listing

### Dashboard HTML Patch Notes (applied to public/index.html)

1. **Added Mesh tab panels**:
   - **RNS TRANSPORT** — transport ID, uptime, interface count, TX/RX traffic
   - **WIFI MESH** — SSID, mode (IBSS), channel, TX power, TCP port 4242
   - **INTERFACES** — live table (span 2 rows) with name, type, status dot, peers, TX, RX
2. **Kept existing panels**: RETICULUM, NOMADNET, P4P WIKI, WIKI BROWSER
3. **JS polling** updated to fetch `/api/mesh/rns` alongside `/api/mesh/status` and `/api/mesh/nomadnet`

---

## 5. Reticulum Mesh Stack

Reticulum v1.3.7 runs on the host (not in Docker) for direct WiFi interface access.

### Services

| Service | Binary | Config | Start Method |
|---------|--------|--------|-------------|
| `rnsd` | `~/.local/bin/rnsd -s` (Python) | `~/.reticulum/config` | systemd service (`/etc/systemd/system/rnsd.service`) |
| `nomadnet` | `~/.local/bin/nomadnet --daemon` | `~/nomadnet-new/` | Manual (not persistent) |

### RNS Config (`~/.reticulum/config`)

- `enable_transport = Yes`
- `share_instance = Yes`
- **Interfaces**:
  1. AutoInterface (UDP link-local multicast)
  2. TCPServerInterface on `0.0.0.0:4242`
  3. AutoInterface with `wifi_adhoc = Yes` (IBSS on wlan0)
- **Transport identity**: `6560de0c545854a8448008a4bca1c1ba`

### WiFi IBSS Mesh

```bash
# Set IBSS mode (requires stopping wpa_supplicant first)
sudo systemctl stop wpa_supplicant
sudo iw dev wlan0 set type ibss
sudo ip link set wlan0 up
sudo iw dev wlan0 ibss join <mesh-ssid> 2412

# Verify
iw dev wlan0 info
# → Interface wlan0, type ibss, ssid "<mesh-ssid>", channel 1 (2412 MHz)
```

- **SSID**: `<mesh-ssid>`
- **Channel**: 1 (2412 MHz, 20 MHz width)
- **Mode**: IBSS (ad-hoc)
- **TCP transport**: port 4242 for Reticulum peer-to-peer connections

### RNS Tools (in `~/.local/bin/`)

- `rnsd` — Reticulum daemon (`rnsd -s` logs to `~/.reticulum/logfile`)
- `rnstatus -j` — JSON status output with interfaces, transport_id, traffic, peers
- `rnpath -t -j` — JSON path table
- `rnprobe` — Path probe utility
- `rnsh` — Reticulum shell
- `rncp` — Reticulum copy
- `rnodeconf` — RNode configuration tool

---

## 6. Walletshield — Patched EVM RPC

The original `ZKNetwork/opt` walletshield v0.0.64 was incompatible with the v0.0.73 mixnet. Fork fixed:

### Changes

1. **Thin client fork** (`walletshield-fix/thin/`) — corrected `isConnected` field tracking
2. **Dockerfile** — `FROM scratch` (17MB vs 126MB), copies ca-certificates
3. **Build** — `GOOS=linux GOARCH=arm64 CGO_ENABLED=1 CC=aarch64-linux-gnu-gcc`
4. **CORS proxy** — `rpc-proxy` on port 9292 (walletshield doesn't serve CORS headers)
5. **MetaMask RPC URL**: `http://<node-ip>:9292`

### File Layout

```
walletshield-fix/
├── main.go              # Patched entry point — service=proxy, thin client init
├── build.sh             # Cross-compile script
├── build_static.sh      # Static build script
├── go.mod / go.sum      # Go module deps
├── thin/                # Forked thin client library
│   ├── thin.go          # Core thin client with isConnected tracking
│   ├── thin_events.go   # Event handling
│   └── thin_messages.go # Message handling
├── walletshield-arm64   # Cross-compiled binary (gitignored)
└── *.bak                # Original ZKNetwork/opt files (gitignored)
```

---

## 7. AI Chat Pipeline

### Chatd Fix

**File**: `/home/<node-user>/katzenpost/cmd/chatd/main.go` (line 366)
**Change**: `Sender: []byte("ai")` instead of empty `[]byte{}`

This ensures AI responses have a hex sender `6169` ("ai" in hex) that the dashboard's message regex can parse and display correctly.

**Build and deploy:**
```bash
cd /home/<node-user>/katzenpost
docker build -f cmd/chatd/Dockerfile -t zeros/mixnet-chatd:arm64 .
# Copy binary to host
docker cp $(docker create zeros/mixnet-chatd:arm64):/usr/local/bin/chatd .
# Replace in servicenode container
docker cp chatd mix-servicenode:/usr/local/bin/chatd
# Restart servicenode
docker restart mix-servicenode
```

The chatd runs inside `mix-servicenode` container at PID 24 (post-restart).

### AI Response Flow

```
User message → mixnet → servicenode → chatd → AI query → llama-server:18080
  → AI response stored with Sender="ai" → polled by dashboard → rendered as "AI"
```

- **LLM**: `phi-3-mini-q4` GGUF (2.3GB), CPU-only, ~1 token/sec
- **llama-server**: `127.0.0.1:18080`, OpenAI-compatible chat completions API
- **zkchat binary**: `/usr/local/bin/zkchat` (5.8MB — in dashboard container)
- **Host zkchat**: `/home/<node-user>/<node-user>/zknode-autonomi/bin/zkchat`

### Groups (as of last known good)

| Group Name | Group ID |
|------------|----------|
| MyChat | `05f013c53bb1b890c86fe505bbdfc0c7` |
| AIChat-Final | `af41b244cba7e699b4f6a92726bd295e` |

---

## 8. Ant Node (Autonomi)

- **Binary**: `/home/<node-user>/.local/share/ant/bin/ant-node-0.13.0` (statically linked ARM64, 14MB)
- **CLI**: `/home/<node-user>/.local/bin/ant` (v0.2.8, 39MB)
- **Daemon**: Running as systemd --user service, port 33899
- **Node**: PID 110371, port 12000 QUIC, DHT connecting
- **Data**: `/home/<node-user>/ant-node-data/node-1/`

### ant Systemd Service

```
/etc/systemd/system/ant-node.service  →  ~/.config/systemd/user/ant-node.service
```

Managed by `systemctl --user` commands. Daemon state files at `~/.local/share/ant/` (`daemon.pid`, `daemon.port`, `node_registry.json`).

---

## 9. Zymkey HSM

### Services

| Service | Status | Config |
|---------|--------|--------|
| `zkifc.service` | Active | Part of Zymbit base stack |
| `zymkey-api.service` | Active, :8765 | `/etc/systemd/system/zymkey-api.service` |

### Device Path

The SCM module presents as `/dev/zscm_1` (ttyACM1). The `zymkey-api.service` was fixed from the default `/dev/zscm_8`:

```
Environment=ZYMKEY_DEV=/dev/zscm_1
Environment=ZYMKEY_API_PORT=8765
```

The dashboard checks HSM status via:
1. `existsSync('/run/zkstatus/zkifc_running')` → `zkifc: active/inactive`
2. API health check at `http://127.0.0.1:8765/api/zymkey/status`

---

## 10. CORS Proxy (rpc-proxy)

A lightweight reverse proxy on port 9292 adds CORS headers for MetaMask to access walletshield.

**Config** (if systemd service):
```
/etc/systemd/system/rpc-proxy.service
```
Or a container based on caddy/node with `host` networking. Listens on `0.0.0.0:9292`, proxies to `127.0.0.1:9200`, adds `Access-Control-Allow-Origin: *`.

---

## 11. SPI for RNode LoRa

- **Config**: `dtparam=spi=on` uncommented in `/boot/config.txt` (line 45)
- **Modules loaded**: `spi_bcm2835`, `spidev` — verified with `lsmod | grep spi`
- **Status**: Ready — needs reboot to create `/dev/spidev0.0` / `/dev/spidev0.1`
- The reboot that triggered the Supervised Boot failure was for this change

---

## 12. Network Map

```
Build Machine (blaqbox)         SCM4 (<node-hostname>.local)
<peer-ip>                    <node-ip>
       │                              │
       │  SSH (id_ed25519_zk)         │
       │  Dashboard: http://:8080     │
       │  MetaMask: http://:9292      │
       │  WiFi mesh: <mesh-ssid> ch1  │
       │  TCP mesh: :4242             │
       ▼                              ▼
┌─────────────────┐      ┌─────────────────────────────┐
│  This machine   │      │  zknode SCM4                │
│  Git remote:    │      │  15 Docker containers       │
│  ethrx-dev/     │      │  Reticulum + NomadNet       │
│  zknode-...     │      │  ant-node (Autonomi testnet)│
│                 │      │  Dashboard on :8080         │
│  SSH key:       │      │  Patched walletshield :9200 │
│  ~/.ssh/..._zk  │      │  CORS proxy :9292           │
└─────────────────┘      └─────────────────────────────┘
```

---

## 13. Recovery Path

If the SCM4 hardware is recovered or replaced:

1. **Restore from git**: `git clone https://github.com/ethrx-dev/zknode-autonomi-alpha.git`
2. **Checkout**: `git checkout p4p-wiki-merge`
3. **Build images**: See [POC_DEPLOYMENT_PLAN.md](POC_DEPLOYMENT_PLAN.md) §8 for build commands
4. **Deploy**: `docker compose up -d` (after generating mixnet configs)
5. **Reticulum setup**: Install RNS v1.3.7, deploy systemd service, set IBSS WiFi
6. **Walletshield build**: `cd walletshield-fix && ./build.sh`
7. **Ant node**: Download ant-node binary, set up systemd --user
8. **Apply dashboard patches**: Already in the repo at `zknode-dashboard/`
9. **AI chat**: Build chatd with `Sender: []byte("ai")`, replace in servicenode container
10. **Zymkey**: Fix device path to `/dev/zscm_1` in `zymkey-api.service`
