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

**Status**: Needs investigation

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

**Status**: ⏳ In progress — QR codes and identity display added to dashboard. Invite link generation remaining.

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

**Status**: ✅ Completed

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

**Status**: Ready to implement

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
| Backups automation | High | Small | ✅ Completed |
| Monitoring/alerting | High | Small | ✅ Completed |
| CI/CD pipeline | High | Medium | This week |
| Recovery documentation | Medium | Small | ✅ Completed |
| Peer onboarding | Medium | Medium | ⏳ In progress |
| mixnet-proxy fix | High | Medium | Next week |
| Mesh chat bridge | Low | Large | Future |
| Key rotation | Low | Medium | Future |
