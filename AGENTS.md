# AGENTS.md — zknode-autonomi

> Instructions for autonomous agents setting up and deploying the zknode-autonomi P4P wiki mesh node on a Zymbit SCM4.

## Project Overview

zknode-autonomi is a self-contained private Autonomi storage node with traffic routed through an embedded post-quantum Katzenpost mixnet, hardware-bound ZK storage proofs, and metadata-private P2P communication. Built for the SCM4/CM4 platform (aarch64, 8GB RAM, zymkey HSM).

**Repo**: `ethrx-dev/zknode-autonomi-alpha` on branch `p4p-alpha-unified`
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
| SCM4 IP | `<node-ip>` (e.g. `192.168.9.133`) |
| SSH user | `<node-user>` (never root) |
| SSH key | `~/.ssh/id_ed25519_scm4` |
| Sudo password | `<sudo-password>` |
| Sudo pattern | `echo '<sudo-password>' \| sudo -S <command>` |
| VPS IP | `<your-public-ip>` |
| VPS SSH alias | `zknet-vps` |
| GitHub CLI | `gh` (authenticated as `ethrx-dev`) |
| Git branch | `p4p-alpha-unified` |

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
git clone -b p4p-alpha-unified https://github.com/ethrx-dev/zknode-autonomi-alpha.git zknode-autonomi
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
git clone -b p4p-alpha-unified https://github.com/ethrx-dev/zknode-autonomi-alpha.git zknode-autonomi
cd zknode-autonomi
cp .env.example .env  # or create .env from template below
```

#### 2.2 — Configure .env

Create `.env` with these values (adjust for your deployment):

```env
IMAGE_MIXNET=zeros/mixnet-node:arm64
IMAGE_MIXNET_PROXY=zeros/mixnet-proxy:arm64
IMAGE_ANT_NODE=zeros/ant-node:arm64
IMAGE_ANTD=zeros/antd:arm64

ANT_NODE_PORT=12000
AUTONOMI_EVM_NETWORK=arbitrum-sepolia
AUTONOMI_CHUNK_DB=/mnt/trinity/autonomi/chunks
AUTONOMI_LOGS_DIR=/mnt/trinity/autonomi/logs
MIXNET_MEM_LIMIT=256m
PROXY_MEM_LIMIT=256m
PROXY_SOCKS_PORT=1080

SECRET_KEY=<your-wallet-private-key>
```

**Note**: If using zymkey HSM wallet (SCM4), the `SECRET_KEY` is not used for signing — the HSM holds the key. Set `ANT_REWARDS_ADDRESS` to the HSM-derived EVM address instead.

#### 2.3 — Build All Images

```bash
# Katzenpost mixnet node (all binaries: dirauth, server, courier, kpclientd, etc.)
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.mixnet -t zeros/mixnet-node:arm64 .

# Mixnet proxy (SOCKS5 bridge, Go thin client)
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.mixnet-proxy -t zeros/mixnet-proxy:arm64 .

# Autonomi storage node (Rust, cross-compiled)
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.ant-node -t zeros/ant-node:arm64 .

# Autonomi CLI / antd
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.antd -t zeros/antd:arm64 .

# Storage prover (Merkle/Winterfell proofs)
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.storage-proved -t zeros/storage-proved:arm64 .

# WalletShield (EVM RPC through mixnet)
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.walletshield -t zeros/walletshield:arm64 .
```

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

#### 3.3 — Generate Configs

```bash
./scripts/setup.sh
# Generates: mixnet PKI configs (via genconfig), proxy config, autonomi configs
# Creates: data/ directories, fixes permissions (katzenpost requires 700 on config dirs)
```

**What setup.sh does:**
1. Creates `data/` directories (mixnet, antd, proxy, zymbit)
2. Checks for USB pool at `/mnt/trinity` (falls back to `./data/` if not mounted)
3. Runs `genconfig` inside the mixnet Docker image to produce Katzenpost configs:
   - `--voting --wirekem MLKEM768 --nike x25519` (post-quantum wire KEM)
   - `--layers 3 --nodes 3 --gateways 1 --serviceNodes 1 --nrVoting 3`
4. Fixes servicenode config: correct binary paths, disables CBOR plugins
5. Sets directory permissions to 700 (katzenpost requirement)
6. Generates proxy config with random API key

#### 3.4 — Start the Stack

**Without zymkey (standard mode):**
```bash
./scripts/deploy.sh --start
```

**With zymkey HSM access (SCM4 production):**
```bash
docker compose -f docker-compose.yml -f docker-compose.zymkey.yml up -d
```

The zymkey override adds:
- `/dev/zymkey` device access to ant-node, mixnet-proxy, walletshield
- `/etc/zymbit` and `/var/lib/zymbit` volume mounts
- `ZYMBIT_ENABLED=true` environment variable
- Read-only filesystem + no-new-privileges for ant-node and mixnet-proxy

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

### Containers

| Container | Role | Network | RAM Limit | Image |
|-----------|------|---------|-----------|-------|
| mix-dirauth-1/2/3 | Directory authorities (PKI consensus) | host | 256MB | zeros/mixnet-node:arm64 |
| mix-1/2/3 | Mix nodes (3-hop Sphinx routing) | host | 256MB | zeros/mixnet-node:arm64 |
| mix-gateway | Client entry point | host | 256MB | zeros/mixnet-node:arm64 |
| mix-servicenode | Exit node (http_proxy, courier) | host | 256MB | zeros/mixnet-node:arm64 |
| mix-client | Client daemon (kpclientd) | host | 128MB | zeros/mixnet-node:arm64 |
| mixnet-proxy | SOCKS5 bridge + ZK proof API :9090 | host | 256MB | zeros/mixnet-proxy:arm64 |
| walletshield | EVM RPC through mixnet :9200 | host | — | zeros/walletshield:arm64 |
| storage-proved | Merkle/Winterfell storage prover :9201 | bridge | — | zeros/storage-proved:arm64 |
| antd | Autonomi CLI + node manager | bridge | — | zeros/antd:arm64 |
| reticulum | Reticulum mesh networking (RNS + LXMF) | host | — | zeros/reticulum:arm64 |
| zkchat | Mixnet-native group chat (metadata-private) | host | — | zeros/mixnet-node:arm64 |

### Networking

- **Mixnet containers**: `network_mode: host` — all share host network, communicate via `127.0.0.1` on distinct ports. This avoids Docker bridge overhead for latency-sensitive Sphinx packet routing.
- **Storage/autonomi containers**: `network_mode: bridge` (named `zknode-autonomi-net`) — isolated bridge network.
- **All services bind to `127.0.0.1`** — no external exposure except ant-node port 12000 (QUIC/UDP).

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
| `scripts/deploy.sh --start` | Deploy and start the full stack |
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

## Known Issues

| Issue | Status | Impact |
|-------|--------|--------|
| **Zymkey HSM signing** | Not implemented | ant-node cannot sign EVM transactions via HSM. Rewards arrive at HSM-derived address but must be spent separately via zymkey wallet. |
| **kpclientd epoch sync** | Workaround | kpclientd PKI doc retrieval has a blacklist bug in `client/pki.go:220` — epochs permanently blacklisted on `ErrNoDocument`. 20-min epochs, consensus published ~12.5 min in. Use `ping` binary for reliable mixnet access, or restart kpclientd at epoch boundaries. |
| **Host networking** | By design | Mixnet containers share host network for latency. Bridge networking with BindAddresses needed for production multi-instance isolation. |
| **Go 1.26.2 requirement** | Docker workaround | katzenpost hpqc module requires Go >= 1.26.2. Local builds may fail on older Go. Docker builds use `golang:latest` which works. |

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
# Branch: p4p-alpha-unified
# Remote: origin (ethrx-dev/zknode-autonomi-alpha)

# Pull latest
git pull --rebase origin p4p-alpha-unified

# Commit and push
git add -A
git commit -m "Description of change"
git push origin p4p-alpha-unified
```

## SCM4 .git Quirk

On the SCM4, the `.git` directory is a symlink to `/mnt/usb_sda3/zknode-autonomi-git` on an exFAT filesystem. This means:
- The `.git` directory is root-owned (exFAT has no UNIX ownership)
- `chown` does not work on exFAT
- To edit `.git/config`, use: `echo '<sudo-password>' | sudo -S sed -i '...' .git/config`
- Git operations (commit, push) work normally as the regular user

## Security Audit

The project has been audited with the zkn-security-server scanner. Applied fixes:
- Docker containers run as non-root users (`katzenpost` / `app`)
- Systemd service hardened (`NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`, etc.)
- npm dependencies pinned to exact versions
- Private PEM files removed from git history and `.gitignore` updated
- RPC gateway rate limiting configured (10 req/s, 100 req/min, burst 20)

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
