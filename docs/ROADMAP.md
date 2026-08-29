# zknode-autonomi — Roadmap

## Status: Active Development

Working features (v1): Mixnet PKI consensus, encrypted group/DM chat, walletshield
Ethereum RPC proxy, web dashboard, HSM key management, mesh wiki distribution.

---

## Gap 1: Mesh Chat — Bridge zkchat ↔ Nomadnet/Reticulum

**Problem**: zkchat only works inside the mixnet. Users on reticulum/nomadnet
cannot communicate with mixnet users.

**Approach**: Build a bridge daemon that relays messages between nomadnet peers
and zkchat groups/DMs.

```
nomadnet peer ──► bridge-daemon ──► zkchat ──► mixnet ──► chatd
                     │
                 reticulum transport
```

**Files**: `cmd/chat-bridge/`, `config/nomadnet/chat-bridge-config`

**Status**: Architecture phase

---

## Gap 2: mixnet-proxy — Fix SOCKS5 Bridge

**Problem**: mixnet-proxy container logs "waiting for gateway…" and never
connects. ant-node cannot route through the mixnet.

**Symptoms**:
- Container runs but `journalctl` shows no gateway connection
- `curl http://127.0.0.1:9090/status` returns error
- Gateway's kpclientd at `127.0.0.1:64332` is accepting connections

**Hypothesis**: thinclient config points to wrong provider address or Sphinx
geometry mismatch between proxy and mixnet.

**Debug steps**:
1. Verify `config/proxy/thinclient.toml` matches `config/mixnet/client/thinclient.toml`
2. Check Sphinx geometry constants in proxy source vs mixnet
3. Test with `docker run` directly (bypass Docker Compose)
4. Enable debug logging in proxy config

**Status**: ✅ Completed — Rebuilt mixnet-proxy with current code. Fixed three issues:
1. `client2` imports → `client` (package was renamed but imports not updated)
2. Thinclient.toml format: `[Dial.Tcp]` nesting → top-level `Network`/`Address` fields
3. Service name: `http_proxy` → `proxy` (capability name, not endpoint)
4. HTTP request URL: set `req.RequestURI` to absolute URL so http_proxy kaetzchen can forward

SOCKS5 proxy now routes HTTP traffic through mixnet (3-hop Sphinx path → service node http_proxy kaetzchen → upstream). Verified: `curl --socks5 127.0.0.1:1080 http://httpbin.org/ip` returns VPS exit IP, not SCM4 IP.

---

## Gap 3: Automated Peer Onboarding

**Problem**: Adding new users to zkchat groups requires manual identity hex
exchange and CLI commands.

**Solution**: Add invite links and QR codes to the dashboard.

```
1. User A clicks "Invite" in dashboard
2. Dashboard generates signed invite token (includes group_id + user A's identity)
3. User A shares token (QR code / link / clipboard)
4. User B scans token → dashboard auto-joins group
5. Both users can now message
```

**Files**: `zknode-dashboard/server/invite.js`, `zknode-dashboard/public/invite.js`

**Status**: ✅ Completed — Invite token generation (`POST /api/chat/groups/invite-token`), token verification (`GET /api/chat/groups/invite-info`), auto-join (`POST /api/chat/groups/join-token`), QR code of invite link, and `/#invite=<token>` URL fragment handling for auto-join modal on page load. HMAC-signed tokens expire after 30 days.

---

## Gap 4: Backup/Restore Automation

**Problem**: USB backup exists (`zmnt-rsync`) but no schedule or rotation.

**Solution**: Systemd timer for daily+weekly backups with retention.

```
/etc/systemd/system/zknode-backup.service   # runs zmnt-rsync
/etc/systemd/system/zknode-backup.timer     # daily at 03:00
/etc/systemd/system/zknode-backup-weekly.timer  # weekly Sunday 03:00
```

Retention: 7 daily, 4 weekly, 3 monthly.

**Status**: ✅ Completed — systemd timers installed and enabled (zknode-backup.timer daily, zknode-backup-weekly.timer weekly).

---

## Gap 5: Monitoring / Alerting

**Problem**: No notification when dirauth consensus drops or services go down.

**Solution**: Add health check endpoint to dashboard + optional notification
channels (email, ntfy.sh, webhook).

```
GET /api/health → {
  "dirauth_consensus": true/false,
  "mix_nodes_running": 3/3,
  "gateway_connected": true/false,
  "chatd_running": true/false,
  "walletshield_running": true/false,
  "disk_usage_percent": 68,
  "last_backup_age_hours": 12
}
```

Dashboard shows HEALTHY/DEGRADED badge in header. ntfy.sh push notification on status change (set `NTFY_TOPIC` env var).

**Files**: `scripts/backup/health-check.sh`

**Status**: ✅ Completed — health endpoint now also reports `walletshield_http`,
`mix_nodes` 6/6 incl. dirauths/gateway/servicenode/client, `kpclientd_listening`,
and Autonomi node/storage status. See `docs/OPS_SESSION_2026-08-28.md`.

---

## Gap 5b: Backup content verification — PARTIAL

**Problem**: The `zknode-backup.timer` fires daily, but `/mnt/backup/zknode/daily/`
(the path `/api/health` reads for `last_backup_age_hours`) is **empty** — the job
runs without producing the expected artifact, so the dashboard shows
`last_backup_age_hours: -1`.

**Needed**:
1. Debug the `zknode-backup.service` job (target dir, rsync exit status).
2. Ensure config/keys/compose/.env snapshots (excluding logs) land in the
   monitored path with a dated directory.
3. Wire the health endpoint to the real artifact and alert on staleness.

**Status**: ⚠️ Partial — timer exists, artifact path unverified.

---

## Post-v1 Stabilization (2026-08-28) — ✅ Completed

Full detail: `docs/OPS_SESSION_2026-08-28.md`.

- **kpclientd PKI reliability**: transient fetch errors no longer blacklist an
  epoch; previous-epoch fetch across the consensus-publish window;
  `recheckInterval` /32. Loop-decoy `pkiDoc` TOCTOU race closed.
- **Dirauth FSM desync recovery**: restart-all-three-together procedure;
  skipped epochs are unavailable — clients auto-land on the next published one.
- **WalletShield productionization**: CBOR reply decoding, reconnect retry ×3
  (skipped for deterministic errors), `Connection: close` (its Rust HTTP server
  hangs on keep-alive), `[Dial.Tcp]` thin-client config migration.
- **MetaMask payload guard**: `/ethereum` rejects bodies >1900 bytes instantly
  (mixnet caps a payload at 2000); oversized traffic can no longer churn the
  tunnel (was: 64KB batches → reconnect storms → dashboard "degraded/dead").
- **Performance tuning**: load 11.3 → ~1–4; +2 GB swap; decoys disabled on the
  client; INFO logging (was DEBUG, ~180 MB/4 h). Gateway link flap rate: 0.
- **Autonomi daemon on the dashboard**: DAEMON/NODE start-stop buttons
  (stale-PID-safe daemon start; container lifecycle for the node — the
  entrypoint monitor respawns killed processes). Status via `ant node … --json`
  (bridge-network safe). Node runs as **direct binary** — daemon-managed 0.17.2
  nodes are blocked upstream (dual-stack + env propagation).
- **zkchat**: `chat` service enabled on servicenode1; groups list API fixed;
  poll-container sweep (labeled `zkchat-poll`, pruned every 10 min).
- **Repos**: `main` merged (fast-forward) and tagged `v0.01-stable-mixnet` on
  GitHub + `git.zknet.cloud` (now the default branch); katzenpost patch line
  published at `ethrx-dev/katzenpost-v0.0.84-patched`.

---

## Gap 6: Reproducible Builds — CI/CD

**Problem**: Docker images built on-device with no pipeline.

**Solution**: GitHub Actions workflow that builds all Docker images on push
and publishes to ghcr.io.

```yaml
# .github/workflows/build.yml
- Build mixnet image (Dockerfile.mixnet)
- Build walletshield image (Dockerfile.walletshield)
- Build dashboard image (zknode-dashboard/Dockerfile)
- Build proxy image (Dockerfile.mixnet-proxy)
- Push to ghcr.io/ethrx-dev/zknode-autonomi-alpha/*
```

**Status**: ✅ Completed — `.github/workflows/build.yml` builds dashboard + walletshield for `linux/arm64` via QEMU + Buildx on every push, pushes to `ghcr.io/ethrx-dev/zknode-autonomi-alpha/{dashboard,walletshield}`.

---

## Gap 7: Key Rotation

**Problem**: Mixnet node keys are static — no rotation mechanism.

**Solution**: Script that:
1. Generates new identity/link keys for each mix node
2. Updates config files
3. Restarts containers gracefully during low-epoch window
4. Verifies PKI re-registration

**Files**: `scripts/rotate-mixnet-keys.sh`

**Status**: Architecture phase

---

## Gap 9: Performance / hardening follow-ups (from 2026-08-28 session)

| Item | Priority | Notes |
|------|----------|-------|
| Log rotation | High | INFO logs grow continuously; root fs has hit 90% twice. Add logrotate/size-capped truncate for `config/mixnet/*/katzenpost.log`. |
| Re-enable cover traffic | Low | `DisableDecoyTraffic = true` on mix-client (load fix). Revisit with 2 GB swap + INFO in place and more mesh peers. |
| zkchat identity persistence | Medium | Container identity (`/etc/zkchat/.zkchat/`) is not volume-mounted — recreations mint a new identity. Dashboard identity is persisted. |
| MetaMask batch splitting | Medium | Oversized batched requests are rejected (`-32005`). Optional: split/forward ≤1900-byte items and merge replies in the `/ethereum` proxy. |
| antd daemon-managed nodes | Medium | Upstream `WithAutonomi/ant-client`: daemon spawn env propagation + dual-stack on IPv4-only hosts. Direct binary works today. |
| Upstream katzenpost PRs | Low | Client pki.go blacklist/epoch fixes + chatd — offer to `katzenpost/katzenpost` from `ethrx-dev/katzenpost-v0.0.84-patched`. |
| Mixnet widget epoch accuracy | Low | `/api/mixnet` shows the dirauths' voting epoch; surface mix-client's `currentDocument().Epoch` alongside. |

---

## Gap 8: Recovery Procedure

**Problem**: If SD card dies, restoring from USB backup requires manual steps.

**Solution**: Documented recovery procedure + recovery script `zmnt-restore`
that can be run from a fresh OS install.

**Files**: `docs/RECOVERY.md`, `scripts/recovery/zmnt-restore.sh`

**Status**: ✅ Completed — `docs/RECOVERY.md` documents full recovery steps. `scripts/recovery/zmnt-restore.sh` handles automated restore.

---

## Timeline

| Gap | Priority | Effort | Target |
|-----|----------|--------|--------|
| Backups automation | High | Small | ⚠️ Partial (timer runs; artifact path unverified — Gap 5b) |
| Monitoring/alerting | High | Small | ✅ Completed (extended 2026-08-28) |
| CI/CD pipeline | High | Medium | ✅ Completed |
| Recovery documentation | Medium | Small | ✅ Completed |
| Peer onboarding | Medium | Medium | ✅ Completed |
| mixnet-proxy fix | High | Medium | ✅ Completed |
| Post-v1 stabilization | High | Large | ✅ Completed 2026-08-28 |
| Log rotation | High | Small | Next |
| MetaMask batch splitting | Medium | Medium | Next |
| zkchat identity persistence | Medium | Small | Next |
| antd daemon nodes upstream | Medium | Medium | Future |
| Upstream katzenpost PRs | Low | Medium | Future |
| Re-enable cover traffic | Low | Small | Future |
| Mesh chat bridge | Low | Large | Future |
| Key rotation | Low | Medium | Future |
