# Remaining Work

> **Status as of 2026-08-28.** The 2026-08-20 blockers (WalletShield end-to-end
> RPC) are **resolved** — RPC works end-to-end through the mixnet, verified
> live. Full incident/fix history: `docs/OPS_SESSION_2026-08-28.md`.

## Previously blocked — now DONE

| 2026-08-20 item | State |
|---|---|
| Rebuild WalletShield with updated thin client | ✅ Done — walletshield runs the current `client/thin`; deployed image `ws-deploy:latest` |
| WalletShield E2E RPC blocked | ✅ Working — `POST /ethereum` and `ws-heartbeat` verified live (block numbers advancing) |
| Deploy echo service for SURB testing | ✅ Running on servicenode1 (loop decoys + ping rely on it) |
| PKI document fallback / epoch blacklist | ✅ Fixed upstream in `client/pki.go` (transient errors no longer blacklist; `now-1` fetch; recheckInterval /32) |
| Forward path / SURB debug | ✅ Round trips verified (eth_blockNumber, echo, loop decoys) |

---

## Current remaining work (prioritized)

### 1. Automated backups — ✅ DONE (2026-08-28)
`/api/health` now reports `last_backup_age_hours: 0`. Fixed chain: script exec
bit committed; target moved to `/mnt/usb_sda3/backup` (symlinked from
`/mnt/backup/zknode`); `*.db`/`*.sst`/`*.tar.gz` excluded; service runs as root
so root-owned PEMs and `.env` are captured; dashboard mounts the backup root
read-only; 0-hour-age falsy bug fixed. Daily timer verified end-to-end
(59M artifact with keys/configs/compose/.env; 7-day retention).

### 2. Log rotation — ✅ DONE (2026-08-28)
`/etc/logrotate.d/zknode-mixnet`: `maxsize 100M, rotate 2, compress,
copytruncate` over `config/mixnet/*/katzenpost.log` (validated dry-run + forced
cycle; containers keep writing). Journal vacuumed to 100M with its own rotate
config; 2.3G of stale `/tmp` tarballs removed. Root fs 87% → 72%.

### 3. antd daemon-managed nodes — MEDIUM (upstream)
`ant node daemon`-managed nodes (0.17.2) fail with `Failed to create
dual-stack network nodes` — the daemon does not propagate env/flags to spawned
processes. The storage node therefore runs as the **direct binary** via the
container entrypoint.
- [ ] Track/patch upstream (`WithAutonomi/ant-client` daemon spawn env
      propagation + dual-stack on IPv4-only hosts).
- [ ] When fixed: migrate to daemon-managed nodes for the web console,
      keeping `ANT_IPV4_ONLY=true`.

### 4. zkchat identity persistence — ✅ DONE (2026-08-28)
`./data/zkchat/identity:/etc/zkchat/.zkchat` mounted; current identity migrated
into the volume. Identity survives force-recreations (verified twice). The
dashboard identity was already persisted.

### 5. MetaMask large batch payloads — ✅ DONE (2026-08-28)
The `/ethereum` proxy now **splits oversized batch arrays** into sub-batches
that fit the 1900-byte tunnel limit, forwards each, and merges replies in
original order. A single request that alone exceeds the limit still gets a
clean JSON-RPC `-32005`. Verified: 30-item batch → 30/30 replies; mixed batch
→ per-item outcomes; small path unchanged.

### 6. Mixnet widget epoch accuracy — LOW (cosmetic)
`/api/mixnet` shows the dirauths' *voting* epoch, which can lag/lead the
published-consensus epoch. Cosmetic only — `/api/health` and consensus are
authoritative.
- [ ] Surface `currentDocument().Epoch` from mix-client (authoritative) next
      to the authority epochs.

### 7. Upstream contributions — LOW (hygiene)
The katzenpost patch line lives in `ethrx-dev/katzenpost-v0.0.84-patched`
(clean tree; upstream history contains a 58MB blob that blocks normal pushes).
- [ ] Consider upstream PRs (katzenpost/katzenpost) for the client/pki.go
      blacklist + epoch-boundary fixes and the chatd service.
- [ ] Keep `ethrx-dev/katzenpost-v0.0.84-patched` in sync with any new
      patches; `main` and `p4p-0.99-upgrade` are merged as of
      `57bbe58` (tag `v0.01-stable-mixnet`) on GitHub and `git.zknet.cloud`
      (default branch: `main`).

### 8. Cover traffic — LOW (privacy tradeoff)
`DisableDecoyTraffic = true` on mix-client (the 2026-08-28 load fix; decoys
were the dominant CPU load at load-avg 11).
- [ ] Revisit with 2 GB swap + INFO logging in place: re-enable and measure
      kpclientd CPU. Restore when more mesh peers join (network-level cover).

---

## Verification loop (post any change)

```
curl -s http://127.0.0.1:8080/api/health          # healthy, 6/6
curl -s http://127.0.0.1:8080/api/ant | jq .totalRunning
curl -x socks5h://127.0.0.1:1080 http://httpbin.org/ip
curl -s -X POST http://127.0.0.1:8080/ethereum \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}'
docker logs mix-client --since 5m 2>&1 | grep -c 'Lost connection'   # 0
```
