# AGENTS.md — zknode-autonomi

> Instructions for autonomous agents setting up and deploying the zknode-autonomi P4P wiki mesh node on a Zymbit SCM4.

## Project Overview

zknode-autonomi is a self-contained private Autonomi storage node with traffic routed through an embedded post-quantum Katzenpost mixnet, hardware-bound ZK storage proofs, and metadata-private P2P communication. Built for the SCM4/CM4 platform (aarch64, 8GB RAM, zymkey HSM).

**Repos**: `ethrx-dev/zknode-autonomi-alpha` (GitHub, public mirror) and `git.zknet.cloud/G/zknode-autonomi-P4P-v.01` (source of truth) — branch `main` on both
**Hardware**: Zymbit SCM4 (CM4 + zymkey HSM, 8GB RAM, 32GB eMMC, Debian Bookworm 64-bit)
**Stack**: 14 Docker containers (Katzenpost mixnet + Autonomi node + proxy + storage prover)

## Critical Safety Rules

### NEVER DO (will brick the SCM4)

1. **NEVER remove `dtoverlay=dwc2,dr_mode=host` from `/boot/config.txt`** — the eMMC is pre-encrypted and `rpiboot` is disabled. Removing this overlay bricks the unit permanently. Always verify it exists before any boot config changes:
   ```bash
   grep dwc2 /boot/config.txt
   ```

2. **NEVER allow `unattended-upgrades` to run** — it can break the encrypted boot chain. Disable immediately on first boot:
   ```bash
   sudo systemctl stop unattended-upgrades
   sudo systemctl disable unattended-upgrades
   sudo apt remove --purge unattended-upgrades -y
   ```

3. **NEVER modify boot artifacts without signing via `zbcli imager`** — Supervised Boot verifies signatures on every boot. Unsigned changes cause boot failure.

4. **NEVER set `tamper_policy` to self-destruct (2) during development** — this permanently destroys HSM keys on tamper. Use policy 1 (halt) or 0 (log only).

5. **NEVER use root for SSH** — connect as the regular user, then sudo as needed.

### Tamper Avoidance (physical handling)

The SCM4 has active tamper detection. Avoid triggering it:
- **Perimeter detect**: Do not open the enclosure. If you must, disable perimeter detect first via `zymkey.client.set_perimeter_event_actions(action_notify=True, action_self_destruct=False)` and clear events.
- **Accelerometer**: Do not drop, shock, or rapidly move the device. Place it on a stable surface before booting.
- **Power monitoring**: Use a stable power supply. Avoid hot-plugging USB devices during operation. Never remove the battery (if equipped).
- **Boot handling**: Let the 90-second boot sequence complete without interruption. The LED pattern indicates progress:
  - 1 slow blink → initializing
  - 1→2→3→4 blinks → Supervised Boot verifying
  - Rapid blinking → verification passed, booting OS
  - 1 blink / 3s → system ready

## Connection Details

| Item | Value |
|------|-------|
| SCM4 IP | `<node-ip>` (e.g. `<node-ip>`) |
| SSH user | `<node-user>` (never root) |
| SSH key | `~/.ssh/id_ed25519_scm4` |
| Sudo password | `<sudo-password>` |
| Sudo pattern | `echo '<sudo-password>' \| sudo -S <command>` |
| VPS IP | `<your-public-ip>` |
| VPS SSH alias | `zknet-vps` |
| GitHub CLI | `gh` (authenticated as `ethrx-dev`) |
| Git branch | `main` (both remotes) |

## Local Build Environment

The build machine (where Docker images are cross-compiled) is an amd64 Linux machine. Images are built for `linux/arm64` and transferred to the SCM4.

**Prerequisites on build machine:**
- Docker Engine 24+ with Compose v2
- Go 1.26+ (for local builds; Docker builds use `golang:latest` which works)
- Cross-compile toolchain: `gcc-aarch64-linux-gnu`, `g++-aarch64-linux-gnu`
- ARM64 multiarch libraries: `libssl-dev:arm64`, `libsnappy-dev:arm64`, `liblz4-dev:arm64`, `libzstd-dev:arm64`, `zlib1g-dev:arm64`
- Rust target: `rustup target add aarch64-unknown-linux-gnu`

**Note**: The katzenpost hpqc module requires Go >= 1.26.2. If the build machine has an older Go, use Docker builds (`golang:latest` includes the required version).

## Deployment Phases

### Phase 1: SCM4 Zymbit Setup

Run these steps on the SCM4 itself, via SSH as `<node-user>`.

#### 1.1 — First Boot Verification

```bash
# SSH in (never as root)
ssh -i ~/.ssh/id_ed25519_scm4 <node-user>@<node-ip>

# Verify architecture
uname -m  # must be aarch64

# Verify zymkey device node exists
ls -la /dev/zymkey /dev/ttyACM7 /dev/zscm_* 2>/dev/null

# Verify zkifc service is running
systemctl status zkifc

# Verify zymkey firmware and status
python3 -c "import zymkey; print('FW:', zymkey.client.get_firmware_version()); print('Status:', zymkey.client.get_operational_status())"
# Expected: FW: 01.02.02release, Status: secure

# Get device ID (record this)
python3 -c "import zymkey; print('Device ID:', zymkey.client.get_unique_device_id())"
```

#### 1.2 — Disable Unattended Upgrades

```bash
echo '<sudo-password>' | sudo -S systemctl stop unattended-upgrades
echo '<sudo-password>' | sudo -S systemctl disable unattended-upgrades
echo '<sudo-password>' | sudo -S apt remove --purge unattended-upgrades -y
```

#### 1.3 — Verify Boot Overlay (CRITICAL)

```bash
grep dwc2 /boot/config.txt
# MUST output: dtoverlay=dwc2,dr_mode=host
# If missing, DO NOT REBOOT. Restore it immediately.
```

#### 1.4 — Configure Tamper Detection (Safe Mode)

Set tamper to notify-only (no self-destruct) for development and setup:

```bash
python3 << 'EOF'
import zymkey

# Check current tamper events
events = zymkey.client.get_tamper_events()
print(f"Current tamper events: {len(events)}")

# Set perimeter detect to notify only (NOT self-destruct)
zymkey.client.set_perimeter_event_actions(
    action_notify=True,
    action_self_destruct=False
)
print("Perimeter detect: enabled (notify only, no self-destruct)")

# Check accelerometer is present
try:
    accel = zymkey.client.get_accelerometer_data()
    print(f"Accelerometer: {accel}")
except Exception as e:
    print(f"Accelerometer: not available ({e})")
EOF
```

#### 1.5 — Install Docker on SCM4

```bash
# Install Docker Engine + Compose v2
echo '<sudo-password>' | sudo -S sh -c 'curl -fsSL https://get.docker.com | sh'

# Add user to docker group
echo '<sudo-password>' | sudo -S usermod -aG docker <node-user>

# Verify (may need re-login for group change)
docker --version
docker compose version
```

#### 1.6 — Clone Repo on SCM4

```bash
cd ~
git clone -b main https://github.com/ethrx-dev/zknode-autonomi-alpha.git zknode-autonomi   # or the zknet repo
cd zknode-autonomi
```

#### 1.7 — Encrypt USB Drive (for chunk storage)

The USB pool stores the Autonomi chunk database (can grow to 1-4 TB). The LUKS key is locked to the zymkey HSM so only this SCM4 can decrypt it.

```bash
# List available block devices
lsblk -d -o NAME,SIZE,TYPE | grep disk

# Encrypt USB drive (DESTROYS all data on the device)
echo '<sudo-password>' | sudo -S ./scripts/setup-zymbit.sh --encrypt-usb /dev/sda
# When prompted, type: ENCRYPT /dev/sda

# Verify mount
df -h /mnt/trinity
# Should show the encrypted volume mounted
```

#### 1.8 — Set Up Hardware Wallet (zymkey HSM)

Generates a BIP32 master seed in the HSM, derives an EVM rewards address, and updates docker-compose configs. The private key NEVER leaves the HSM.

```bash
echo '<sudo-password>' | sudo -S ./scripts/setup-zymbit.sh --wallet
# Records: master slot, rewards slot, EVM address
# Updates docker-compose.yml and docker-compose.zymkey.yml with the real rewards address
```

**Record the output**: EVM address, master slot, rewards slot. Set up SLIP39 recovery (3-of-5) for the master seed:
```bash
echo '<sudo-password>' | sudo -S python3 -c "
import zymkey
m = zymkey.client.create_slip39_mnemonic(3, 5, <master_slot>)
for i, s in enumerate(m): print(f'Share {i+1}: {s}')
"
```

#### 1.9 — Health Check

```bash
echo '<sudo-password>' | sudo -S ./scripts/setup-zymbit.sh --check
```

Expected output: all items marked with checkmark — architecture aarch64, I2C available, /dev/zymkey exists, Python API loaded, status secure, 0 tamper events, zkifc running.

#### 1.10 — Production Lock (OPTIONAL, IRREVERSIBLE)

Only do this after everything is verified and working. This permanently binds all security policies to the device.

```bash
echo '<sudo-password>' | sudo -S ./scripts/setup-zymbit.sh --production
# Type 'LOCK FOREVER' to confirm
# After this: status changes from 'secure' to 'production'
# Device cannot be reprogrammed, keys are permanently bound
```

### Phase 2: Build Docker Images (Build Machine)

Run on the amd64 build machine. Images are cross-compiled for arm64.

#### 2.1 — Clone and Prepare

```bash
git clone -b main https://github.com/ethrx-dev/zknode-autonomi-alpha.git zknode-autonomi   # or the zknet repo
cd zknode-autonomi
cp .env.example .env  # or create .env from template below
```

#### 2.2 — Configure .env

```bash
cp .env.example .env
```

`.env.example` is the complete variable reference (image names, ports,
mem limits, Autonomi, dashboard security). Key entries for a real node:
`NODE_HOME`, `IMAGE_*` (suffix `:amd64`/`:arm64` to match the target),
`ANT_REWARDS_ADDRESS` (HSM deployments), `DASHBOARD_TOKEN`
(`openssl rand -hex 24`) — unset keeps the dashboard loopback-only.

#### 2.3 — Build All Images (multi-arch)

```bash
./scripts/build.sh              # host arch, canonical image map
./scripts/build.sh --both       # local amd64 + arm64 tags
./scripts/build.sh --multiarch --push   # buildx manifest to a registry (REGISTRY=ghcr.io/<org>/)
```

Canonical map (one Dockerfile per image): mixnet-node, walletshield,
mixnet-proxy, ant-node, antd, storage-proved-rs, dashboard. All seven are
pinned and verified for **amd64 + arm64**; `tests/` gate CI publishes.

**Build notes:**
- `Dockerfile.mixnet` builds RocksDB v10.2.1 from source for aarch64 and cross-compiles all Katzenpost binaries. This takes ~20-30 minutes.
- `Dockerfile.ant-node` and `Dockerfile.antd` clone from `https://github.com/WithAutonomi/ant-node` and `ant-client` respectively. Build takes ~15-20 minutes each.
- `Dockerfile.mixnet` adds a `type Logger = logging.Logger` alias to `core/log/log.go` for backward compatibility.
- If a build fails due to Go version, ensure `golang:latest` is pulled (it should have >= 1.26.2).

#### 2.4 — Export Images for Air-Gapped Transfer

```bash
./scripts/deploy.sh --export
# Creates: zknode-autonomi-images.tar.gz
# Transfer to SCM4 via: scp, USB drive, or SD card
```

### Phase 3: Deploy on SCM4

#### 3.1 — Load Docker Images

```bash
# Transfer the tarball to SCM4 first, then:
gunzip -c zknode-autonomi-images.tar.gz | docker load
```

#### 3.2 — Verify Prerequisites

```bash
cd ~/zknode-autonomi
./scripts/deploy.sh --check
# Verifies: architecture, Docker installed, all images present, USB pool mounted
```

#### 3.3 — Generate Mixnet Configs

```bash
sudo ./scripts/gen-mixnet99.sh [IMAGE_MIXNET]     # -> config/mixnet99/
```

Generates the full Katzenpost v0.0.99 topology (3 voting authorities, 3
mixes, gateway, service node, storage replicas, client) from the image's
`genconfig` and applies the deployment fixes (plugin paths, 0700 perms,
thinclient 127.0.0.1). Validated end-to-end: PKI consensus, 3-hop echo,
walletshield RPC round-trip.

**Operational rule**: restart mixnet nodes only at epoch boundaries
(:00/:20/:40 UTC) — mid-epoch restarts regenerate mix keys and invalidate
the current consensus document.

#### 3.4 — Start the Stack

**Without zymkey (standard mode):**
```bash
./scripts/deploy.sh --start
```

`--start` uses the **fast-stagger path**: it creates all containers in one pass
(one I/O storm instead of nine), then starts them group-by-group
(authorities → wait for consensus → mixes → gateway+servicenode → …) with
adaptive `wait_running` polling + a `wait_consensus` deadline. On the USB HDD
this converges in ~20-40 min instead of hours.

**With zymkey HSM access (SCM4 production):**
```bash
docker compose -f docker-compose.yml -f docker-compose.zymkey.yml up -d
```

The zymkey override adds:
- `/dev/zymkey` device access to ant-node, mixnet-proxy, walletshield
- `/etc/zymbit` and `/var/lib/zymbit` volume mounts
- `ZYMBIT_ENABLED=true` environment variable
- Read-only filesystem + no-new-privileges for ant-node and mixnet-proxy

#### 3.4b — Install the Living-Intelligence Layer (recommended)

After the stack is up, install the I/O-aware watchdog + fleet doctor + tuning:
```bash
scp scripts/zknode-doctor.sh scripts/zknode-watchdog.sh scripts/zknode-watchdog.service scripts/zknode-watchdog.timer <node-user>@<node-ip>:/tmp/
ssh <node-user>@<node-ip> -- 'NODE_HOME=<project-root> bash /tmp/install-living-intelligence.sh'
```

This installs:
- `zknode-doctor` + `zknode-watchdog` to `/usr/local/bin`
- `zknode-watchdog.timer` (10-min cycles, randomized, `IOSchedulingClass=idle`)
- `noatime,commit=60` on the docker/ext4 mounts in fstab
- `10m` Docker log rotation for future containers

The watchdog enforces the **GOLDEN RULE**: never intervene during an I/O storm
(iowait ≥ 60% or load ≥ 25 → back off, no interventions). It re-applies the
antd throttle, detects dirauth desyncs (stale epochs → coordinated restart with
2h cooldown), and resurfaces bad-behavior yet no-storm cases.

#### 3.5 — Verify Deployment

```bash
# Check all containers are running
docker compose ps

# Monitor stack status
./scripts/monitor.sh

# Check mixnet proxy API
curl -s http://127.0.0.1:9090/status | python3 -m json.tool

# Check storage layout
./scripts/storage-layout.sh

# Check zymkey health
echo '<sudo-password>' | sudo -S ./scripts/setup-zymbit.sh --check
```

Expected: 10+ containers running, mixnet consensus achieved, proxy ACTIVE, storage paths OK.

## Stack Architecture

### MetaMask / EVM RPC over the mixnet

External RPC endpoint: **`http://<node-ip>:8080/ethereum`** (dashboard →
walletshield on `127.0.0.1:9200` → kpclientd → `http` service on the
servicenode → `ethereum-rpc.publicnode.com`). Configure it in MetaMask as a
custom RPC; `eth_chainId` = `0x1`. JSON-RPC responses are capped at 2000
bytes (Sphinx payload geometry) — core polling (`eth_blockNumber`,
`eth_chainId`, balances) works; large responses (e.g. full block bodies)
time out by design. LAN access requires `DASHBOARD_TOKEN` (unset = dashboard
is loopback-only).

### Autonomi daemon & node control

- Dashboard buttons: **DAEMON** start/stop (cleans stale `daemon.pid`/`.port`,
  then `ant node daemon start`) and **NODE** start/stop (`docker start/stop antd`).
- Status is read via `docker exec antd ant node daemon info --json` and
  `ant node status --json` — the dashboard is bridge-networked and cannot reach
  the daemon's host-loopback HTTP API.
- Rewards address: `0xf21CEFD6773491323B05162f62bE5106B27893aa` (arbitrum-sepolia).

### Containers

| Container | Role | Network | RAM Limit | Image |
|-----------|------|---------|-----------|-------|
| mix-dirauth-1/2/3 | Directory authorities (PKI consensus) | katzenpost-net bridge | 256MB | `${IMAGE_MIXNET}` |
| mix-1/2/3 | Mix nodes (3-hop Sphinx routing) | katzenpost-net bridge | 256MB | `${IMAGE_MIXNET}` |
| mix-gateway | Client entry point | katzenpost-net bridge | 256MB | `${IMAGE_MIXNET}` |
| mix-servicenode | Exit node (http proxy, courier, chat) | katzenpost-net bridge | 256MB | `${IMAGE_MIXNET}` |
| mix-client | Client daemon (kpclientd) | katzenpost-net bridge, publishes 127.0.0.1:64331 | 128MB | `${IMAGE_MIXNET}` |
| mixnet-proxy | SOCKS5 bridge + ZK proof API :9090 | host | 256MB | `${IMAGE_MIXNET_PROXY}` |
| walletshield | EVM RPC through mixnet :9200 | host | — | `${IMAGE_WALLETSHIELD}` |
| storage-proved | ZK storage prover :9201 | autonomi bridge | — | `${IMAGE_STORAGE_PROVED}` |
| antd | Autonomi CLI + node manager | autonomi bridge | — | `${IMAGE_ANTD}` |
| reticulum | Reticulum mesh networking (RNS + LXMF) | host | — | built from Dockerfile.reticulum |
| zkchat | Mixnet-native group chat (metadata-private) | host | — | `${IMAGE_MIXNET}` |

### Networking

- **Mixnet containers**: on the `katzenpost-net` bridge network — nodes address each other by Docker hostname (`auth1`, `mix1`, `gateway1`, `servicenode1`) resolved by the embedded DNS; PKI documents carry hostname-derived addresses and configs set `AllowHostnameAddresses = true`.
- **Storage/autonomi containers**: isolated bridge (`autonomi`).
- **Client-facing services**: `mix-client` publishes `127.0.0.1:64331` (thin clients: walletshield, zkchat, dashboard runner connect there); walletshield and the dashboard bind loopback; ant-node is the only externally exposed port (12000 UDP/QUIC).

### Storage Layout

| Path | Tier | Purpose |
|------|------|---------|
| `./data/mixnet/` | microSD (eMMC) | Mixnet bbolt DBs, runtime state |
| `./data/antd/` | microSD (eMMC) | Chunk index, metadata |
| `./data/proxy/` | microSD (eMMC) | SURB cache |
| `./data/zymbit/` | microSD (eMMC) | HSM configuration data |
| `/mnt/trinity/autonomi/chunks/` | USB pool (LUKS) | LMDB chunk store (1-4 TB) |
| `/mnt/trinity/autonomi/logs/` | USB pool (LUKS) | Rotating logs |
| `/mnt/trinity/backup/` | USB pool (LUKS) | Weekly snapshots |

## Key Scripts

| Script | Purpose |
|--------|---------|
| `scripts/setup.sh` | Generate configs, create data dirs, fix permissions |
| `scripts/deploy.sh --check` | Verify prerequisites (Docker, images, storage) |
| `scripts/deploy.sh --start` | Deploy and start the full stack (fast-stagger until consensus) |
| `scripts/deploy.sh --stop` | Stop the stack (preserves volumes) |
| `scripts/deploy.sh --clean` | Stop, remove volumes, clean all data |
| `scripts/deploy.sh --export` | Export images to tarball for air-gapped transfer |
| `scripts/setup-zymbit.sh --check` | SCM4 zymkey health check |
| `scripts/setup-zymbit.sh --full` | Full Zymbit setup (check + tamper + disable upgrades) |
| `scripts/setup-zymbit.sh --encrypt-usb /dev/sdX` | Encrypt USB drive with zymkey-bound LUKS |
| `scripts/setup-zymbit.sh --wallet` | Generate HSM hardware wallet for Autonomi rewards |
| `scripts/setup-zymbit.sh --production` | Lock device to production mode (IRREVERSIBLE) |
| `scripts/gen-wallet.sh --apply` | Generate standard EVM wallet (any machine, non-HSM) |
| `scripts/gen-mixnet-configs.sh` | Generate Katzenpost mixnet PKI + node configs |
| `scripts/monitor.sh` | Display stack status (containers, proxy, storage, exits) |
| `scripts/storage-layout.sh` | Verify two-tier storage hierarchy |
| `scripts/zymkey-attest.py` | Generate zymkey-signed hardware attestation |
| `scripts/zknode-doctor.sh` | One-shot fleet diagnostics → HEALTHY / DEGRADED / CRITICAL (iowait, disk, dirty flags, container fleet) |
| `scripts/zknode-watchdog.sh` | I/O-aware self-healing cycle (antd throttle, dirauth desync, bad-behavior detection); installed to `/usr/local/bin/zknode-watchdog` |
| `scripts/zknode-watchdog.service / .timer` | Runs watchdog every 10 min (randomized), `Nice=10`, `IOSchedulingClass=idle` |
| `scripts/install-living-intelligence.sh` | Installs doctor + watchdog + tuning on SCM4: scripts to `/usr/local/bin`, systemd units, `noatime,commit=60` fstab, Docker `10m` log rotation, enables watchdog timer |
| `scripts/build.sh` | Canonical multi-arch image builder (`host` / `--both` / `--multiarch --push`) |
| `scripts/gen-mixnet99.sh` | Generate a fresh v0.0.99 mixnet topology (`config/mixnet99`) with deployment fixes applied |
| `scripts/state.sh` | Node-state lifecycle: `export` (drift check), `backup` (encrypted bundle), `restore` |
| `tests/run-all.sh` | Repo test matrix (secrets scan, syntax, compose config, backup roundtrip, generator checks) |
| `tests/test-config-drift.sh` | Repo topology vs live node comparison (via SSH; skips gracefully when the node is unreachable) |
| `scripts/build-usb-image.sh` | Deterministic USB image builder for P4P wiki mesh: `--size 64G` `--stack minimal\|full` `--base wolfi\|debian` `--kernel zeros\|debian` `--output img` `--compress zstd\|gzip\|none` `--device /dev/sdX` `--dry-run` (safe: never touches nvme/sda) |

## Operational Rules

| Rule | Detail |
|------|--------|
| **Epoch-boundary restarts** | Restart mixnet nodes only at epoch boundaries (:00/:20/:40 UTC). Mid-epoch restarts regenerate mix keys and invalidate the current consensus document until the next epoch publishes. The fast-stagger deploy already aligns to boundaries. |
| **Dirauth restarts are simultaneous** | If authorities disagree on the voting epoch, restart all three **together**; skipped epochs are permanently unavailable and clients recover on the next published epoch. |
| **antd throttled on SCM4** | `blkio_config` caps ant-node writes (40MB/s) on the single-spindle USB HDD so the box never starves. The watchdog re-applies the cgroup limit. |
| **antd node = direct binary** | The storage node runs as the direct binary from the container entrypoint (the daemon doesn't propagate env to spawned nodes). Node start/stop = `docker start/stop antd`; the entrypoint monitor respawns it. |
| **NomadNet/Reticulum storage isolation** | nomadnet mounts its own RNS storage (`./data/nomadnet/rns`); rnsd keeps `./data/reticulum`. Do not share RNS storage between instances. |
| **WalletShield thin config format** | client2 format only: `[Dial] [Dial.Tcp]` — no geometry sections (geometry comes from the daemon handshake). |
| **Zymkey HSM signing** | Not implemented: rewards arrive at the HSM-derived address but must be spent via the separate zymkey wallet. |
| **storage-proved boot race** | After reboot it can stay Exited(255) — `docker start storage-proved` (the watchdog also auto-starts exited containers). |
| **SCM4 .git quirk** | The device's `.git` is a symlink to exFAT (root-owned, no chown); edit `.git/config` with sudo sed. |

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| No `/dev/zymkey` | zkifc service not running | `sudo systemctl restart zkifc` |
| Boot hangs on rainbow screen | Corrupted boot partition | Contact Zymbit support (eMMC not field-recoverable) |
| LUKS won't unlock | zymkey not in "secure" state | Check tamper events; verify binding |
| Key slots 16+ vanish on reboot | SCM FW 01.02.02release bug | Use BIP32 wallet (`gen_wallet_master_seed`) instead of `gen_key_pair()` |
| `gen_key_pair` not available | Python API missing | `sudo apt install python3-zymkey` |
| Perimeter detect false triggers | Floating GPIO | Add pull-up resistor to tamper circuit |
| antd logs growing fast | Log level set to debug | Change `--log-level debug` to `--log-level info` in docker-compose.yml |
| dirauth containers failing | Race condition on first start | Restart failed dirauths: `docker compose restart mix-dirauth-1 mix-dirauth-2 mix-dirauth-3` |
| Docker build fails (Go version) | katzenpost hpqc needs Go >= 1.26.2 | Use Docker build with `golang:latest` |

## Git Workflow

```bash
# Branch: main — push to BOTH remotes after every change
git add -A && git commit -m "change"
git push origin main      # GitHub (public mirror)
git push zknet main       # git.zknet.cloud (source of truth)
```

Run `./tests/run-all.sh` before pushing; CI publishes images only after
the test matrix passes.

## SCM4 .git Quirk

On the SCM4, the `.git` directory is a symlink to `/mnt/usb_sda3/zknode-autonomi-git` on an exFAT filesystem. This means:
- The `.git` directory is root-owned (exFAT has no UNIX ownership)
- `chown` does not work on exFAT
- To edit `.git/config`, use: `echo '<sudo-password>' | sudo -S sed -i '...' .git/config`
- Git operations (commit, push) work normally as the regular user

## Security Posture

- Dashboard: token auth on all `/api` endpoints (Bearer / `x-zk-token` /
  HttpOnly cookie), 240 req/min/IP rate limit, security headers; **binds
  127.0.0.1 only unless `DASHBOARD_TOKEN` is set**
- No key material in git (`**/*.pem`, state dirs ignored; secret-scan test
  enforces; detector files excluded from self-match)
- Node state lifecycle: encrypted backups (`scripts/state.sh backup`),
  checksum-verified restores, drift checks (`export`) between repo and node
- Pinned provenance: katzenpost commit, RocksDB, Rust/Go bases; patch
  application is fail-hard in image builds
- zymbit/SCM4: attestation, tamper notify-only in dev, LUKS key sealed to HSM

## References

- [P4P Reference Architecture](docs/P4P_ARCHITECTURE.md)
- [Live Node Status](docs/LIVE_NODE_STATUS.md)
- [Zymbit/SCM4 Setup Guide](docs/ZYMBIT_SETUP.md)
- [Hardware Setup](docs/HARDWARE_SETUP.md)
- [Architecture](docs/ARCHITECTURE.md)
- [PoC Deployment Plan](docs/POC_DEPLOYMENT_PLAN.md)
- [Mixnet Integration](docs/MIXNET_INTEGRATION.md)
- [Demo Script](docs/DEMO_SCRIPT.md)
- [Zymbit Docs](https://docs.zymbit.com/)
- [Katzenpost](https://github.com/katzenpost/katzenpost)
- [Autonomi](https://github.com/WithAutonomi)
