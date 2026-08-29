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

### 1. Automated backups — HIGH (ops safety)
`/api/health` reports `last_backup_age_hours: -1` — there is **no automated
daily backup** despite the dashboard expecting `/mnt/backup/zknode/daily/`.
- [ ] Schedule a daily job: configs + keys + compose + `.env` (exclude logs)
      → `/mnt/autonomi/backups/daily/YYYY-MM-DD/`, retain 14 days.
- [ ] Include the deployed image tarballs pointer
      (`/mnt/autonomi/backups/mixnet-stable-20260828/`).
- [ ] Wire `last_backup_age_hours` to the actual job so the dashboard shows it.

### 2. Log rotation — HIGH (disk safety)
Root fs sits at ~81% and katzenpost logs grow continuously at INFO. The 90%
incidents came from logs + `/tmp` tarballs.
- [ ] Add logrotate config (or a cron `truncate`) for
      `config/mixnet/*/katzenpost.log` with size caps.
- [ ] Move walletshield/chatd stdout into rotation or size-capped files.

### 3. antd daemon-managed nodes — MEDIUM (upstream)
`ant node daemon`-managed nodes (0.17.2) fail with `Failed to create
dual-stack network nodes` — the daemon does not propagate env/flags to spawned
processes. The storage node therefore runs as the **direct binary** via the
container entrypoint.
- [ ] Track/patch upstream (`WithAutonomi/ant-client` daemon spawn env
      propagation + dual-stack on IPv4-only hosts).
- [ ] When fixed: migrate to daemon-managed nodes for the web console,
      keeping `ANT_IPV4_ONLY=true`.

### 4. zkchat identity persistence — MEDIUM
The `zkchat` container derives its 16-byte identity from
`/etc/zkchat/.zkchat/identity`, which is **not on a persistent volume** —
recreating the container mints a new identity (groups owned by the old ID
become invisible to it).
- [ ] Mount `./data/zkchat/identity:/etc/zkchat/.zkchat` (or pass the config
      from a persisted dir) so the poll/send identity survives recreations.
- [ ] Note: the **dashboard** identity IS persisted
      (`config/mixnet/client/.zkchat/identity`) — groups created via the UI
      are stable.

### 5. MetaMask large batch payloads — MEDIUM (UX)
The mixnet caps a single payload at ~2000 bytes; MetaMask occasionally sends
64KB batched/filter requests. The dashboard now rejects them instantly with
JSON-RPC `-32005` (no tunnel churn — see OPS_SESSION §7).
- [ ] Optional: implement request **splitting** in the dashboard `/ethereum`
      proxy (split batches, forward ≤1900-byte items, merge replies) instead
      of rejecting.
- [ ] Optional: document recommended MetaMask settings (disable advanced
      batched fetching) in the dashboard UI.

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
      patches; both `main` and `p4p-0.99-upgrade` are merged as of
      `4676d5b` (tag `v0.01-stable-mixnet`) on GitHub and `git.zknet.cloud`.

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
