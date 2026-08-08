# Portable USB Node — Design & Runbook

A LUKS-encrypted USB drive that carries the entire P4P wiki mesh node and
boots on **any Linux machine with Docker** (aarch64 or amd64). The drive is
"the node": plug it in, unlock, and the same mixnet identity, wiki, wallet
and services come up on whatever host it lands on.

## Design decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Target platforms | aarch64 **+** amd64 by default | `IMG_ARCH` auto-detected on first run (`deploy.sh`) / at boot (`usb-init.sh`); compose defaults resolve `${IMG_ARCH:-arm64}` |
| Image distribution | vendored `docker save \| gzip` on the drive, **both arches** | one drive boots on any Docker host (arm64 or amd64), `usb-init.sh` loads only the tarballs for `$(uname -m)` |
| Node identity | shipped on drive, LUKS-passphrase protected | drive IS the node — same identity everywhere |
| Encryption | LUKS2 passphrase (not zymkey-bound) | any host can unlock without the SCM4 HSM |
| Host binaries | vendored into `ZKROOT/bin` | compose no longer needs `/home/zero-tech/...` |

## Drive layout

```
/mnt/zknode/                          <- LUKS2 ext4, label ZKNODE
└── zknode-autonomi/                  <- ZK_ROOT
    ├── docker-compose.yml            <- parametrized (ZK_* env paths)
    ├── deploy.sh  scripts/…          <- staged boot + portable/ helpers
    ├── config/mixnet/                <- node identity + PKI keys (carried)
    ├── bin/                          <- chatd, zkchat, llm-wiki, ant
    ├── wikis/                        <- wiki data set
    ├── images/                       <- <image>__<tag>.tar.gz (docker save)
    ├── data/                         <- antd node-1, logs, chunks (writes)
    └── .env                          <- generated (ZK_ROOT=/mnt/zknode/…)
```

## How the portability works

All compose host paths derive from one variable:

```
ZK_ROOT=/mnt/zknode/zknode-autonomi
ZK_BIN=${ZK_ROOT}/bin          # vendored binaries
ZK_WIKIS=${ZK_ROOT}/wikis      # wiki data
ZK_ANTD_NODE1=${ZK_ROOT}/data/antd-node-1   # antd state (was /mnt/usb_sda3)
ZK_ANT_SHARE=${ZK_ROOT}/data/ant-share      # ant node + wallet
ZK_LLM_WIKI_HOME=${ZK_ROOT}/.llm-wiki
ZK_POOL=${ZK_ROOT}/pool        # external pool / chunks
```

On the SCM4 the same file works unmodified by setting
`ZK_ROOT=/home/zero-tech/zknode-autonomi` (defaults keep the old layout for
in-place operation). App-layer ports are tunable:
`DASHBOARD_PORT`, `LLM_WIKI_PORT`, `WALLETSHIELD_PORT`, `STORAGE_PROVED_PORT`,
`ANTD_PORT`. The mixnet ports (30001-30019, 64332) are **fixed** — they are
baked into the PKI doc (`config/mixnet/auth1/authority.toml`); regenerate with
`scripts/gen-mixnet-configs.sh` to change them.

### Architecture is auto-detected

No manual `arm64`/`amd64` edits needed:

- **Direct repo run**: `deploy.sh` computes `IMG_ARCH` from `uname -m` on
  first run and generates/updates `.env` (`--check`, `--group N`, and full
  deploy all call `ensure_env` first).
- **Portable drive**: `usb-prep.sh` vendors **both** arch image tarballs;
  `usb-init.sh` reads `uname -m` on the target, sets `IMG_ARCH`, and `docker
  load`s only the matching-arch tarballs.
- **compose defaults**: every image tag is
  `${IMAGE_*:-zeros/<name>:${IMG_ARCH:-arm64}}`, so plain `docker compose up`
  also resolves correctly once `IMG_ARCH` is set (arm64 remains the fallback).

Image tags in `.env` use `zeros/<name>:${IMG_ARCH}` so a single arch variable
flips every service.

## Build machine steps (one-time)

```bash
# 1. build images for both arches (or pull prebuilt)
docker build --build-arg TARGETARCH=arm64 -f Dockerfile.mixnet -t zeros/mixnet-node:arm64 .
docker build --build-arg TARGETARCH=amd64 -f Dockerfile.mixnet -t zeros/mixnet-node:amd64 .
# ... same for mixnet-proxy, antd, storage-proved-rs, reticulum, walletshield, dashboard
# (CI workflow .github/workflows/build.yml builds + pushes these to ghcr)

# 2. vendor host binaries + wiki + compose onto the drive
sudo ./scripts/portable/usb-prep.sh -d /dev/sdX -l ZKNODE -p passfile

# 3. (optional) enable autoboot unit on target
sudo cp <mount>/zknode-autonomi/scripts/portable/zknode-boot.service /etc/systemd/system/
sudo systemctl enable --now zknode-boot
```

### Multi-arch builder pin (do not change)

`Dockerfile.mixnet` must build from `golang:1.26-bookworm`, **not**
`golang:latest`:

- katzenpost `v0.0.84` requires `go >= 1.26.2` (its `go.mod` enforces it).
- `golang:latest` has moved to Debian 13 (glibc 2.41) while the runtime stage
  is `debian:bookworm-slim` (glibc 2.36). CGO binaries built there demand
  `GLIBC_2.39` and fail on the runtime (`/lib/x86_64-linux-gnu/libc.so.6:
  version 'GLIBC_2.39' not found`).
- `golang:1.26-bookworm` ships go 1.26.5 on glibc 2.36 → CGO binaries match
  the bookworm runtime. Verified: both `TARGETARCH=amd64` and `TARGETARCH=arm64`
  build clean and all seven katzenpost binaries
  (`dirauth server courier kpclientd ping fetch echo-plugin genconfig`) run.

A second historical foot-gun: the `Logger` alias patch appended to
`core/log/log.go` must keep its `\n` escapes — an unquoted
`printf n// Alias...type Logger = logging.Loggern` writes one garbage line and
breaks the Go build (`log.go:241:1: syntax error`). The committed form
`printf '\n// Alias ...\n\ntype Logger = logging.Logger\n'` is correct.

`usb-prep.sh` performs: LUKS2 format → open → mkfs.ext4 (label `ZKNODE`) →
rsync repo → vendor `bin/` (chatd, zkchat, llm-wiki, ant) → vendor `wikis/`
→ `docker save` each image in `images/` → write `.env` for the build arch.

## Target host steps (plug & play)

```bash
# as root, on any Docker host
sudo /mnt/zknode/zknode-autonomi/scripts/portable/usb-init.sh
```

`usb-init.sh` does: find drive by label → `cryptsetup open` (prompts for
passphrase) → mount → `docker load` the vendored images for `$(uname -m)` →
run the staged deploy (`deploy.sh`). Helpers: `luks-open.sh` / `luks-close.sh`.

## Constraints & caveats

- **Docker required** on the target (Engine + Compose v2). The drive is an
  appliance for Docker hosts, not a bootable OS.
- **Host networking + fixed ports**: mixnet uses host networking on
  30001-30019 (uncommon, low collision risk). App ports are tunable but the
  mixnet ports are PKI-baked.
- **Identity travels**: the drive carries mixnet PKI, the ant rewards wallet
  (`ANT_REWARDS_ADDRESS`), and zkchat identity. This is intended (drive = the
  node) but means the passphrase is the only thing protecting node identity —
  use a strong one.
- **USB I/O**: mixnet bbolt DBs prefer fast random IOPS (see
  HARDWARE_SETUP.md). On USB the mixnet may be slower than eMMC/SD. Acceptable
  for portable/backup use.
- **zymkey HSM**: not required. The stack runs without it; HSM features
  (attestation, LUKS key sealing) only work on the SCM4 via
  `docker-compose.zymkey.yml`.
- **amd64/arm64 images**: both verified builds (see "Multi-arch builder pin"
  above). CI (`build.yml`) cross-builds and pushes to ghcr; run it once before
  vendoring to a fresh drive. The deployed SCM4 only has arm64 images; the
  amd64 images come from CI (or `docker build --build-arg TARGETARCH=amd64`).
  `usb-prep.sh` vendors both arches and warns for any arch it cannot save.

## Files

| Path | Purpose |
|------|---------|
| `docker-compose.yml` | portable compose (ZK_* paths, tunable ports) |
| `scripts/portable/usb-prep.sh` | build-machine: LUKS + vendor everything |
| `scripts/portable/usb-init.sh` | target-host: unlock, load, deploy |
| `scripts/portable/luks-open.sh` | open/mount only |
| `scripts/portable/luks-close.sh` | unmount/lock |
| `scripts/portable/zknode-boot.service` | systemd autoboot unit |
| `scripts/portable/images.list` | image manifest (per-arch tags) |
| `Dockerfile.mixnet` / `Dockerfile.mixnet-proxy` / `Dockerfile.antd` | TARGETARCH-native-or-cross builds |
| `.github/workflows/build.yml` | multi-arch CI builds → ghcr |
| `.env.example` | full var reference (`IMG_ARCH` drives image arch) |
