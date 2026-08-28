# Ops Session 2026-08-28 — Mixnet Stabilization, WalletShield, Autonomi, zkchat

> Full incident + stabilization log for the SCM4 node (`192.168.9.133`). Everything
> below was applied, verified live, and pushed. Start/stop of the whole stack is
> unchanged: `docker compose up -d` in `/home/zero-tech/zknode-autonomi`.

## 1. Mixnet client (kpclientd) — PKI fetch fixes

Symptoms fixed: loop-decoy `service not found` storms, thin clients stuck epochs
behind, `Skipping fetch for epoch N` repeating forever.

| File | Fix |
|------|-----|
| `katzenpost/client/pki.go` | Transient fetch errors (`ErrNoDocument`, `ErrNotConnected`) **no longer blacklist** an epoch — a failure recorded before the gateway link came up previously suppressed fetching forever. |
| `katzenpost/client/pki.go` | Worker now also fetches `now-1` when `now` is uncached: the newest consensus trails the epoch boundary by `PublishDeadline` (~12.5 min), so for the first minutes of an epoch only N-1 exists and `currentDocument`'s fallback needs it cached. |
| `katzenpost/client/pki.go` | `recheckInterval` `Period/16` → `Period/32` (faster retry). |
| `katzenpost/client/send.go`, `thin_messages.go`, `daemon.go` | `request.pkiDoc` plumbed through `ComposeSphinxPacket → makePath` — closes the TOCTOU race where the loop decoy derived its destination hash from a different document than it sent against. |

Remote: `ethrx-dev/katzenpost-v0.0.84-patched` (branch `v0.0.84-patched`, clean
single-commit tree — the upstream history contains a 58MB blob that blocks pushes).

## 2. Directory authorities — FSM desync

**Incident:** auth1 was processing epoch N+1 while auth2/3 skipped to N+2 and all
reported "No document for current epoch generated and never will be". Zero
consensus published → gateway refused all client connections
(`no usable PKI document`) → total mixnet outage.

**Fix:** restart all three dirauths **together** so their FSMs re-enter bootstrap
at the same epoch boundary:
```
docker restart mix-dirauth-1 mix-dirauth-2 mix-dirauth-3
```
Aligned FSMs vote on the next epoch (~10 min later) and publish consensus ~12.5
min into it. Verified: `SUCCESS! Achieved threshold consensus for epoch 243020`.

**Gotcha:** epochs an authority skipped are permanently unavailable
(`error code 2` / "will never get a document") — clients must land on the next
*published* epoch, which the §1 fixes handle automatically.

## 3. WalletShield — MetaMask RPC over the mixnet

MetaMask endpoint: **`http://192.168.9.133:8080/ethereum`**
(dashboard `POST /ethereum` → `walletshield :9200` → kpclientd `:64332` →
`proxy`/`http_proxy` service on servicenode1 → `ethereum-rpc.publicnode.com`).

| File | Fix |
|------|-----|
| `walletshield-fix/main.go` | **CBOR-decode** the http_proxy reply (`cbor.UnmarshalFirst` into `common.Response{Payload}`), raw-parse fallback kept — the proxy wraps replies, walletshield previously parsed raw and failed with `malformed HTTP version "\xa1gPayload…"`. |
| `walletshield-fix/main.go` | **Reconnect retry ×3 with backoff** on thin-client errors — a single reconnect can fail while the daemon is re-dialing its gateway link; reusing the stale client guaranteed a second failure and surfaced `custom 404` to MetaMask. |
| `config/walletshield/config.toml` | Migrated to new thin-client format: only `[Dial.Tcp] Network/Address` — geometry is delivered by the daemon handshake (old `Network=`/`[SphinxGeometry]` sections are rejected with `unknown key(s)`). |

## 4. Load / stability — the "MetaMask keeps disconnecting" root cause

The gateway link reset every 60–90 s (`nyquist: decryption failure`,
`ack timeout waiting for seq`) because the SCM4 was overloaded:
**load 11.3 on 4 cores, kpclientd 89.7% CPU, swap 99/99 MB (100% full)**.
Connections reset when the client couldn't finish wire handshakes in time
(`failed to receive NoOp during finalization: i/o timeout`).

Applied:
1. **+2 GB swap** `/mnt/autonomi/swapfile2` (persisted in `/etc/fstab`).
2. `config/mixnet/client/client.toml` — `DisableDecoyTraffic = true`
   (decoys were the dominant CPU load; flip back for stronger cover traffic
   when more peers join — with swap + INFO it may be sustainable).
3. `client.toml` + `gateway1`/`servicenode1` `katzenpost.toml` logging
   `DEBUG → INFO` (debug spammed ~180 MB / 4 h and starved packet processing).
4. Dashboard `wsProxy` timeout 30 s → 60 s so a single flap never reaches MetaMask.

Result: load 4.3, mix-client 0.7% CPU, **0 flaps**, RPC 12/12 success.

## 5. Autonomi (antd) — daemon + node buttons

- The storage node runs as the **direct binary** (`ant-node-0.14.4` via the
  container entrypoint monitor loop). Daemon-spawned 0.17.2 nodes fail with
  `Failed to create dual-stack network nodes` — the daemon does not propagate
  `--env`/container env to spawned processes. Keep direct mode until fixed.
- `ant node daemon start` can lie ("already running (PID 1)") when a stale
  `daemon.pid` points at the container's PID-1 shell wrapper. The dashboard's
  daemon-start endpoint now does **stop → rm stale pid/port → start**.
- The dashboard runs on a **bridge network** and cannot reach the daemon's
  host-loopback HTTP — status is read via `docker exec antd ant node daemon
  info --json` / `ant node status --json` instead of `fetchUrl`.
- **Node start/stop = container lifecycle** (`docker start/stop antd`): killing
  the ant-node process alone is futile — the entrypoint monitor respawns it
  within 30 s. Stop halts node + daemon + monitor together.
- Rewards: every mesh chunk PUT pays `0xf21CEFD6773491323B05162f62bE5106B27893aa`
  on `arbitrum-sepolia`; balance visible via `8080/api/ant/wallet` + `/balance`
  (through walletshield/mixnet).

## 6. zkchat — service + groups

- servicenode `chat` plugin was `Disable = true` → enabled, descriptor
  re-uploaded; `chatd` runs as a CBOR Kaetzchen (`Capability = "chat"`, endpoint
  `chat`, binary `/usr/local/bin/chatd`).
- `config/mixnet/client/thinclient.toml` migrated to `[Dial.Tcp]` format (§3).
- Groups list API fixed: `chat-groups.sh` now runs `docker exec -u 0` and scans
  `/tmp/zkchat` only (chatd stores `group_*/meta.json` there; the old path
  `/var/lib/katzenpost/servicenode1/chatd` does not exist and made `find` exit 1
  → dashboard returned `{"groups":[]}` forever).
- **Container sweep:** the dashboard's zkchat poll runs `docker run --rm …`;
  a poll that times out mid-creation leaves a `Created` container behind
  (`--rm` only removes containers that ran). 19 orphans accumulated and slowed
  every docker call until dashboard endpoints timed out. Fix: poll containers
  labeled `zkchat-poll` + dashboard prunes them every 10 min
  (`docker container prune -f --filter label=zkchat-poll`).

## 7. Dashboard

- `DAEMON` widget keys off `daemon.running || totalRunning > 0` (direct node
  counts as RUNNING even though the management daemon reports no fleet nodes).
- NODES count uses merged `totalRunning/totalStopped` (daemon fleet + direct).
- **JS syntax regression fixed:** a sed-based edit left a stray `'+'` string and
  an unterminated string in the inline script — the whole dashboard is
  JS-rendered, so one syntax error = blank page. Always run `node --check` on
  the extracted script after hand edits to `public/index.html`.
- The compose **bind-mounts** `zknode-dashboard/server:/app/server` and
  `…/public:/app/public` — host files **override** the image. Bake-into-image
  changes are invisible until the host files are updated too.

## 8. Ops notes

- **Logs:** DEBUG filled the root fs (727 MB gateway log). Level is now INFO
  everywhere; truncate with `truncate -s 0 config/mixnet/*/katzenpost.log`
  if needed. Root fs historically spikes at `/tmp` tarballs — keep big
  artifacts on `/mnt/autonomi` (63 GB) or `/mnt/usb_sda3` (169 GB).
- **Backups:** `/mnt/autonomi/backups/mixnet-stable-20260828/` holds the exact
  deployed images (`mixnet-v3.tar.gz` = `zeros/mixnet-node:arm64` b699a10140af,
  `ws-cbor.tar.gz` = `ws-deploy:latest` de214bf5). `stale-tars-20260828/` keeps
  superseded builds. Config tarballs excluded logs deliberately.
- **Verify loop** after any mixnet change:
  ```
  curl -s http://127.0.0.1:8080/api/health
  curl -s http://127.0.0.1:8080/api/ant | jq .totalRunning
  curl -x socks5h://127.0.0.1:1080 http://httpbin.org/ip
  curl -s -X POST http://127.0.0.1:8080/ethereum \
    -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}'
  docker logs mix-client --since 5m 2>&1 | grep -c 'Lost connection'
  ```
- **Remotes:** `origin` = `ethrx-dev/zknode-autonomi-alpha` (GitHub),
  `zknet` = `git.zknet.cloud/G/zknode-autonomi-P4P-v.01` — both pushed to
  `p4p-0.99-upgrade` (f5ca5fc).

## 9. Verified end state (2026-08-28)

```
health:            healthy (6/6 mix nodes, walletshield 200)
containers:        18/18 Up, zero rogue containers
RPC:               eth_blockNumber / eth_chainId live via mixnet (12/12, 0 flaps)
flap rate:         0 (was 8–12 per 5 min)
loop decoys:       clean (service not found: 0)
load:              4.3 (was 11.3), swap 2 GB available
autonomi:          node1 running (direct), daemon running, storage active
zkchat:            chat service in doc, group create/list/poll working
dashboard:         all /api endpoints 200, JS syntax clean
```
