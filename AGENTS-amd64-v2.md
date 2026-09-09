# AGENTS-amd64-v2.md — zknode-autonomi (amd64 / Core-first Edition)

> Development playbook for building the **P4P Wiki Mesh Node** on a standard **amd64 Linux** machine.
> **Version 2** — kept as a separate file so the SCM4 v1 playbook (`AGENTS.md`) and v2 history are never lost. Merge into a single `AGENTS.md` only when the v2 path is stable.

## Versioning Policy

- `AGENTS.md` = v1, SCM4/Zymbit (aarch64, hardware attestation). **Never overwrite it.**
- `AGENTS-amd64-v2.md` = v2, amd64 Linux, **core-first** install order.
- New work: always create a `vN+1` file, never replace. Merge via a dedicated `merge/` workflow when the user decides it's time. Preserve `git history` — no force-push, no squash-onto-existing.

## Project Overview

The **P4P (peer-for-peer) Wiki Mesh Node** is a self-contained sovereign wiki-mesh node:

- **CORE (`zknode-autonomi-P4P-v.01`)** — the integrated 17-service stack: Autonomi storage node (ant-node) + embedded post-quantum Katzenpost mixnet (MLKEM768, 3-hop Sphinx) + ZK storage proofs (Winterfell STARK) + walletshield EVM RPC + Reticulum/NomadNet mesh + zknode-dashboard + P2P wiki (45,461 pages). **Deploy this first.**
- **ADVANCEMENT (`zknode-autonomi-x0x-P4P`)** — the agentic coordination layer layered on the core: **x0x agent mesh** (ML-DSA-65 identities, CRDT KV stores, DMs, pub/sub, file transfer, `:11700`) + **local FAE AI companion** (`:11780`, no cloud) + KPS transport integration + dashboard **Agents/X0X tabs**.

Install order is deliberate and non-negotiable: **core first, advancement second**. This yields a live, earning wiki mesh node before the agentic layer is layered on.

## Repositories & Local Mirrors

| Repo | Remote URL | Local mirror | Notes |
|---|---|---|---|
| CORE | `https://git.zknet.cloud/G/zknode-autonomi-P4P-v.01.git` | `/home/alchemical1/zknode-autonomi-v1` | remote `zknet`; also GitHub `origin` `ethrx-dev/zknode-autonomi-alpha` |
| ADVANCEMENT | `https://git.zknet.cloud/G/zknode-autonomi-x0x-P4P.git` | `/home/alchemical1/src/ZKNet/zknode-autonomi-x0x-p4p` | GitHub mirror `Alchemi1/zknode-autonomi-x0x-p4p`, branches `master` + `feat/kps-integration` |

Always push to `zknet` (git.zknet.cloud). GitHub mirror is for backup/CI only.

## Key Documents

- Original spec (v1.0 manual): `https://md.zknet.cloud/s/6e__4yZ6Pn`
- v2 install doc (amd64, core-first): `/home/alchemical1/Documents/P4P-Wiki-Mesh-Node-amd64-Linux-v2.md`
- v1 hardware playbook: `docs/ZYMBIT_SETUP.md`, `docs/HARDWARE_SETUP.md`, `AGENTS.md` (SCM4)

## Architecture — Service Groups

```
Layer 2 — ADVANCEMENT (x0x-P4P)  agentic coordination
  x0xd (:11700) · FAE (:11780) · kps-monitor · mixnet-proxy KPS · Agents/X0X dashboard tabs
───────────────────────────────────────────────────────────────────────────
Layer 1 — CORE (P4P-v.01)  the P4P Wiki Mesh Node
  G1 mix-dirauth-1/2/3   Katzenpost PKI consensus
  G2 mix-1/2/3           3-hop Sphinx MLKEM768 routing
  G3 mix-gateway         client entry
  G4 mix-servicenode     exit + courier/chatd
  G5 mix-client + mixnet-proxy (:1080/:9090 SOCKS5 bridge)
  G6 walletshield (:9200) + storage-proved-rs (:9201 Winterfell)
  G7 antd + ant-node (:12000 QUIC)   ← Autonomi storage, the earner
  G8 reticulum + nomadnet (:37428)   mesh transport
  G9 zknode-dashboard (:8080) + zkchat
```

Deploy order = staged groups with health-waits (authorities → mixes → gateway → servicenode → client/proxy → walletshield/storage → ant → mesh → dashboard).

## Environment

### Build machine (this repo's home)

- OS: Linux amd64 (Ubuntu 24.04 x86_64 test path)
- Docker Engine + Compose v2
- 8 GB RAM min / 16 GB recommended; 35 GB disk min (see Storage section)
- Go >= 1.26.2 required by katzenpost hpqc (Docker builds use `golang:latest`)

### Target deployment

- Any amd64 Linux host with Docker. Port `12000/udp` reachable for earning.
- No hardware HSM on this path — identity is ant-node's native **ML-DSA-65 keypair** (BLAKE3 PeerId, LMDB). ZK Winterfell proofs replace HMAC challenges.

## Build / Deploy Workflow (amd64)

### Stage A — Core (P4P-v.01) FIRST

```bash
git clone https://git.zknet.cloud/G/zknode-autonomi-P4P-v.01.git
cd zknode-autonomi-P4P-v.01
cp .env.example .env    # complete reference: .env.example covers every compose variable
```

Critical `.env` keys:

| Key | Purpose |
|---|---|
| `ANT_REWARDS_ADDRESS` | rewards address (REQUIRED for ANT; HSM hosts set this instead of SECRET_KEY) |
| `NODE_HOME` | host deployment root (dashboard docker mounts) |
| `IMAGE_*` | image names — suffix `:amd64` on amd64 hosts |
| `DASHBOARD_TOKEN` | unset = dashboard loopback-only; set = LAN access with token auth |
| `MIXNET_MEM_LIMIT` / `PROXY_MEM_LIMIT` | compose mem limits |

### amd64 images — pull or cross-build

Defaults are `:arm64`-tagged (`zeros/mixnet-node:arm64`, `zeros/antd:arm64`, `zeros/storage-proved-rs:arm64` …). On amd64 either:

```bash
# (a) use an amd64/multi-arch tag if published; verify with:
docker image inspect --format '{{.Architecture}}' zeros/antd:amd64
# (b) cross-build from Dockerfiles (TARGETARCH is supported):
# Or build everything with the canonical builder:
./scripts/build.sh --both        # amd64 + arm64 tags (all 7 images)
# (manual: docker build --build-arg TARGETARCH=amd64 -f <Dockerfile> -t <tag> .)
```

Point compose/env image tags to `:amd64`. The ant-node binary is pinned
(`v0.14.4`); the antd entrypoint resolves the node binary dynamically
(preferring the proven version).

### Mixnet topology (required before first deploy)

```bash
sudo ./scripts/gen-mixnet99.sh "${IMAGE_MIXNET:-zeros/mixnet-node:amd64}"
# -> config/mixnet99/ (3 authorities, 3 mixes, gateway, servicenode,
#    replicas, client) with deployment fixes applied.
# Restart rule: nodes restart only at epoch boundaries (:00/:20/:40 UTC).
```

### Deploy

```bash
sudo ./deploy.sh --check       # pre-flight: RAM/disk/mounts/ports
sudo ./deploy.sh               # staged groups 1–9
./scripts/monitor.sh           # TUI status
```

Dashboard LAN access: set `DASHBOARD_TOKEN` in `.env` (unset = loopback
only). The UI prompts for the token on first API call.

### Tests

```bash
./tests/run-all.sh             # repo test matrix (run before every push)
```

### Verify core

```bash
curl http://localhost:8080/api/health         # dirauth/mix status
curl http://localhost:8080/api/ant/balance    # ANT/ETH
curl http://localhost:8080/api/containers     # service states
curl http://localhost:8080/api/system         # cpu/ram/disk
```

Solo nodes: allow **24 h** close-group + chunk-ingest ramp before earnings. Open `12000/udp`.

## Stage B — Advancement (x0x-P4P) on top of core

```bash
git clone https://git.zknet.cloud/G/zknode-autonomi-x0x-P4P.git
cd zknode-autonomi-x0x-P4P
cp .env.example .env      # TARGETARCH=amd64, X0X_VERSION, ANT_REWARDS_ADDRESS
# build missing amd64 images, then:
./start.sh --all
```

Verify advancement:

```bash
curl http://127.0.0.1:11700/health && curl http://127.0.0.1:11700/agent   # x0x
curl http://127.0.0.1:11780/health && curl http://127.0.0.1:11780/skills # FAE
curl -X POST http://127.0.0.1:11780/ask -H 'Content-Type: application/json' \
     -d '{"query":"which wiki pages cover peer-for-peer?"}'
```

## Storage — the ~35 GB Question

Measured on a live node: `/…/ant/nodes/node-1/chunks.mdb/data.mdb` = **27.1 GiB** single LMDB file — the Autonomi chunk store. Everything else (binary 19 MB, `paid_list.mdb` 1 MB, keys, logs) is negligible.

Bounds/config: the stack caps the store via `storage.db_size_gb` + `disk_reserve_mb`; growth plateaus at the cap. LMDB **never shrinks** (high-water mark; prunes within file but doesn't truncate). Replicated + paid chunk pressure fills the allocation — this is the earning asset (provable storage), not bloat to delete.

## Known Issues / Gotchas

| Issue | Status / Impact |
|---|---|
| `no matching manifest for linux/amd64` | Image only published as `:arm64` — build locally with `TARGETARCH=amd64`; never fall back to arm64 |
| Dirauth FSM desync | Restart all three together: `docker restart mix-dirauth-1 mix-dirauth-2 mix-dirauth-3` |
| WalletShield config schema | `config.toml`/`thinclient.toml` use `[Dial.Tcp]` only; old Sphinx geometry sections rejected |
| antd USB HDD I/O storm | Cap I/O via `blkio_config` (device_write_bps 40 MB/s, read 100 MB/s) on spinning disks |
| storage-proved boot race | Can exit 255 after reboot; `docker start storage-proved` |
| nomadnet shared RNS storage | Needs its OWN rns-config + separate storage dir (`./data/nomadnet/rns`), else silent exit-255 loop with empty logs |
| Host networking by design | Mixnet containers `network_mode: host`; storage on bridge; all bind `127.0.0.1` except `12000/udp` |

## Troubleshooting (amd64)

| Symptom | Fix |
|---|---|
| Node not joining | `WALLET_ADDRESS`/`SECRET_KEY` set? wait 24 h ramp; open `12000/udp`; check `8080/api/health` |
| Dashboard 404 | `http://<lan-ip>:8080`; allow `8080/tcp` |
| Low disk | `du -sh ~/.local/share/ant/nodes/*/chunks.mdb`; compact with `mdb_copy` off the live path or size `db_size_gb` down for a fresh store |
| Docker build Go error | use `golang:latest` base (katzenpost hpqc needs Go >= 1.26.2) |

## Operations / Backup

```bash
./scripts/monitor.sh                          # TUI
docker compose ps && docker compose logs -f antd
docker compose run --rm zkchat group send /etc/zkchat/thinclient.toml <group_id> "hello"
sudo ./scripts/backup/zknode-backup.sh        # daily/weekly snapshots
```

First boot: Katzenpost PKI ~20 min to stabilize; then `mixnet-proxy :9090` carries ZK proofs and `:9201` serves Merkle state. ANT accrues on-chain (Arbitrum).

## Minimal vs Full

- **Minimal (~650 MB RAM, 35 GB+, 2 cores)** — ant-node + walletshield + dashboard, still earns.
- **Full (~4.5 GB RAM, 40 GB+, 4 cores)** — all 17 + advancement (x0x + FAE local LLM + wiki + mesh).

## Git Workflow

```bash
# CORE repo
git pull --rebase zknet main
git add -A && git commit -m "..." && git push zknet main
# ADVANCEMENT repo
git pull --rebase origin master
git add -A && git commit -m "..." && git push origin master
```

Rules: no force-push; never overwrite v1 artifacts; version any doc/playbook change as a new `vN+1` file until merge is approved.

## Security

- `.env` holds wallet/secret keys — never commit; `.env` is gitignored. Use `.env.example` with placeholders only.
- Bind endpoints to `127.0.0.1`; only `12000/udp` external.
- LUKS the data partition for persistent storage; wallet keys backed up via mnemonics.
- No plaintext secrets in Dockerfiles, dashboards, or logs.

## References

- [v2 install doc (amd64 core-first)](Documents/P4P-Wiki-Mesh-Node-amd64-Linux-v2.md — see `/home/alchemical1/Documents/`)
- [Original v1.0 manual](https://md.zknet.cloud/s/6e__4yZ6Pn)
- v1 SCM4 playbook: `AGENTS.md` (don't overwrite)
- `docs/ARCHITECTURE.md`, `docs/ROADMAP.md`, `docs/WORKING_STATE.md`, `docs/LIVE_NODE_STATUS.md`