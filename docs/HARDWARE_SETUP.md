# zknode-autonomi — Hardware Setup

## Target Hardware: SCM4

| Component | Spec |
|-----------|------|
| **Compute** | Zymbit SCM4 (integrated CM4 + zymkey HSM) |
| **CPU** | Broadcom BCM2711, quad-core Cortex-A72 @ 1.5GHz |
| **RAM** | 8 GB LPDDR4-3200 |
| **eMMC** | 32 GB (OS + applications) |
| **Security** | zymkey HSM via I2C, tamper detection, secure boot |
| **Network** | Gigabit Ethernet, 2.4/5 GHz Wi-Fi |
| **OS** | Debian Bookworm 64-bit (aarch64) |
| **Cost** | ~$245 (SCM Pro) + ~$130 (carrier/PSU) |

Also runs on any Raspberry Pi CM4, any 8GB aarch64 SBC, or any x86_64 machine with Docker.

---

## Storage Architecture

Two-tier storage with latency-based segregation:

| Tier | Device | IOPS | Capacity | Contents |
|------|--------|------|----------|----------|
| **microSD** | Internal eMMC | ~4000 random read | 32 GB | Mixnet bbolt DBs, antd metadata, proxy cache, configs |
| **USB pool** | External SSD/HDD | ~350 MB/s sequential | 1-4 TB | Autonomi chunk DB (LMDB), logs, backups |

### Why Two Tiers?

- **Mixnet bbolt databases** are accessed on every routed packet (~4000 random IOPS needed)
- **USB random IOPS** (~1000) would bottleneck packet routing
- **Chunk DB (LMDB)** is bulk sequential I/O — USB's ~350 MB/s exceeds the gigabit network bottleneck (~110 MB/s)
- **microSD is only 32 GB** — the chunk DB can grow to TB scale, must live on external storage

---

## Directory Layout

### microSD (internal eMMC)
```
~/zknode-autonomi/
├── config/
│   ├── mixnet/       # Katzenpost configs + PKI keys
│   │   ├── auth1/    # Authority 1 (authority.toml + keys)
│   │   ├── auth2/    # Authority 2
│   │   ├── auth3/    # Authority 3
│   │   ├── mix1/     # Mix node 1 (katzenpost.toml + keys)
│   │   ├── mix2/     # Mix node 2
│   │   ├── mix3/     # Mix node 3
│   │   ├── gateway1/ # Gateway
│   │   └── servicenode1/ # Service node (exit)
│   ├── proxy/
│   │   └── config.json
│   └── autonomi/
│       ├── node.toml
│       └── antd.toml
├── data/
│   ├── mixnet/       # Runtime bbolt databases
│   ├── antd/         # Chunk index, metadata
│   ├── proxy/        # SURB cache
│   └── zymbit/       # HSM configuration
└── scripts/          # Management scripts
```

### USB Pool (/mnt/trinity/)
```
/mnt/trinity/
├── autonomi/
│   ├── chunks/       # LMDB chunk store (grows to 1-4 TB)
│   └── logs/         # Rotating logs
└── backup/           # Weekly snapshots
```

---

## RAM Budget

| Component | RAM | Count | Total |
|-----------|-----|-------|-------|
| mix-dirauth | 256 MB | 3 | 768 MB |
| mix nodes | 256 MB | 3 | 768 MB |
| mix-gateway | 256 MB | 1 | 256 MB |
| mix-servicenode | 256 MB | 1 | 256 MB |
| mixnet-proxy | 256 MB | 1 | 256 MB |
| ant-node | 2 GB | 1 | 2 GB |
| antd (idle) | 128 MB | 1 | 128 MB |
| **Total** | | **11** | **~4.4 GB** |

Leaves ~3.6 GB for OS, Docker daemon, filesystem cache. Chunk DB uses LMDB mmap — no additional RAM overhead beyond what the kernel caches.

---

## USB Pool Setup

```bash
# Run on SCM4 to set up encrypted USB storage
sudo ./scripts/storage-layout.sh
```

This script:
1. Detects available USB drives
2. Creates LUKS-encrypted partitions (bound to zymkey)
3. Sets up mergerfs to pool multiple drives
4. Creates the directory structure under /mnt/trinity/
5. Adds fstab entries for auto-mount on boot

---

## Wallet Setup

| Option | Command | Where |
|--------|---------|-------|
| **Standard** (any machine) | `./scripts/gen-wallet.sh --apply` | Private key in `.env` |
| **Zymkey HSM** (SCM4 only) | `sudo ./scripts/setup-zymbit.sh --wallet` | Key locked in HSM |

Both auto-set `ANT_REWARDS_ADDRESS` in `docker-compose.yml`. See [ZYMBIT_SETUP.md](ZYMBIT_SETUP.md) §8 for details.

---

## Cross-Compile Toolchain (Build Machine)

```bash
# Go — already supports cross-compilation
# No setup needed beyond: GOOS=linux GOARCH=arm64

# Rust
rustup target add aarch64-unknown-linux-gnu

# C cross-compiler (for RocksDB, CGO)
sudo apt-get install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu

# ARM64 multiarch libraries (for CGO linking)
sudo dpkg --add-architecture arm64
sudo apt-get update
sudo apt-get install libssl-dev:arm64 libsnappy-dev:arm64 liblz4-dev:arm64 libzstd-dev:arm64 zlib1g-dev:arm64
```

## Known Hardware Limitations

- **microSD wear**: bbolt databases cause frequent small writes. Use high-endurance microSD or USB SSD for data/.
- **USB power**: External USB SSD may need powered hub if SCM4 USB port can't deliver enough current.
- **Thermals**: 11 containers + RocksDB + LMDB under load may need active cooling (heatsink + fan).

---

## Zymbit Security Features (SCM4)

The SCM4 includes a hardware security module with these ready-to-enable features. Full setup guide: **[ZYMBIT_SETUP.md](ZYMBIT_SETUP.md)**

| Feature | What It Does | Setup |
|---------|-------------|-------|
| **zymkey HSM** | Secure key storage, crypto operations, true RNG | Pre-installed on SCM4 |
| **Bootware** | Verified boot chain, signed images | `sudo zbcli update-config` |
| **LUKS Encryption** | Root + USB filesystem encryption | `sudo ./scripts/setup-zymbit.sh --encrypt-usb /dev/sdX` |
| **Tamper Detection** | Perimeter breach, shock, power loss | `sudo ./scripts/setup-zymbit.sh --tamper` |
| **Hardware Wallet** | BIP32 key generation, SLIP39 recovery | `sudo ./scripts/setup-zymbit.sh --wallet` |
| **Production Lock** | IRREVERSIBLE device binding | `sudo ./scripts/setup-zymbit.sh --production` |
| **Health Check** | Verify all security features | `sudo ./scripts/setup-zymbit.sh --check` |

**Deploy with zymkey access:**
```bash
docker compose -f docker-compose.yml -f docker-compose.zymkey.yml up -d
```
