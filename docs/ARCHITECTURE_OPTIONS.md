# zknode-autonomi — SCM4 Architecture Options

> Which architecture should a given SCM4 run? The repo now supports three
> distinct deployment profiles. This document is the decision guide; the
> canonical operational procedure lives in `AGENTS.md` ("SCM4 Architecture
> Options (Upgrade Paths)").

## TL;DR

| Option | Mixnet location | Dashboard health checks | SCM4 self-contained? | Recommended for |
|--------|-----------------|-------------------------|----------------------|-----------------|
| **1. Full local PoC** | On the SCM4 (3 dirauth + 3 mix + gateway + servicenode + client + proxy) | `dirauth_consensus`, `mix_nodes: "6/6"`, `walletshield_http` (local) | ✅ Yes — works offline | Fully decentralized proof of concept on the SCM4 |
| **2. VPS-client** | VPS 185.92.181.101 (full topology); SCM4 runs `kpclient-vps` thin client only | `kpclient-vps` + `mixnet-proxy` count, `getVpsConsensus()` from VPS | ❌ Requires VPS gateway | Resource-constrained SCM4s; box runs antd + mesh + wiki only |
| **3. Hybrid** | On the SCM4 (like Option 1) | **Local dashboard** (`dirauth_consensus` / `mix_nodes`) despite `main` code | ✅ Yes | Latest repo features on the SCM4 without the VPS dashboard mismatch — **the recommended SCM4 profile** |

## Why this matters

`main` HEAD is *VPS-aware*: its `zknode-dashboard/server/index.js` health logic
counts `kpclient-vps` and calls `getVpsConsensus()` against the VPS. A box
running the **local** topology must use the **local topology dashboard**
(which checks `dirauth_consensus` / `mix_nodes` against its own containers).

Deploying `main` unchanged onto a local-topology SCM4 produces a permanent,
bogus **degraded** / **mixnet dead** state: the dashboard looks for containers
that never existed on that box.

The shipped-by-tag local-PoC state is captured as **`p4p-poc-scm4-2026-09`**
(services exactly matching the SCM4's 19-container stack). `main` additionally
carries the Pigeonhole layer (`mix-replica-1..5`) and RNS 1.3.7 config — the
hybrid profile gets those on the SCM4 while keeping the correct dashboard.

## Image / dashboard identification

Before upgrading an existing SCM4:

```bash
docker ps --format '{{.Names}} {{.Image}}'
docker inspect zknode-dashboard --format '{{.Image}}'
```

Compare dashboard image IDs between boxes:

```bash
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | sort
```

- Local-PoC dashboard builds check `dirauth_consensus`, `mix_nodes`.
- VPS-aware dashboard builds reference `kpclient-vps`, `getVpsConsensus`.
- Keep the local build's tag/ID when applying the hybrid profile.

## Which to pick

- **Offline / self-contained requirement** → Option 1 or 3.
- **Lightest footprint, VPS dependency acceptable** → Option 2.
- **Latest features on the SCM4, correct dashboard** → Option 3 (hybrid).

## Related

- `AGENTS.md` — "SCM4 Architecture Options (Upgrade Paths)" (full procedure:
  clone/pin dashboard/transfer images/gen configs/deploy epoch rule/verify).
- `AGENTS.md` — "VPS Mixnet Deployment" (Option 2 detail).
- `docs/ARCHITECTURE.md` — general system layers.
- `docker-compose.yml` — service inventory for each profile.