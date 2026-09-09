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

### 1. Live-node topology export (needs SCM4 access)
Run `sudo ./scripts/state.sh export` on the node and commit `config/mixnet99`
(the proven live topology) so repo and node are byte-identical; reconcile with
the generated tree. Also export the client `pki.go` epoch patch as
`patches/` (it exists in the deployed binary; source recovery pending).

### 2. chatd group persistence (small)
chatd stores group metadata in the servicenode's `/tmp/zkchat` (ephemeral).
Mount a persistent volume so zkchat groups survive servicenode restarts, or
restore Autonomi-backed storage in chatd.

### 3. CI/GHCR first publish run
The multiarch workflow is merged; first push to `main` publishes all 7 images
to GHCR. Verify the manifest (amd64+arm64) and wire `.env.example` defaults
to the published tags if desired.

### 4. Clean-VM acceptance test
Full `clone → .env → build.sh (or GHCR pull) → gen-mixnet99.sh → deploy.sh`
on a fresh amd64 and arm64 host; record results in docs/.

### 5. Upstream contributions (low)
Consider upstream PRs for the decoy nil-pointer fix and chatd/zkchat service
plugins; keep the patch line in `patches/` in sync.

### 6. Cover traffic (low, privacy tradeoff)
`DisableDecoyTraffic = true` on the client daemon. Revisit when mesh peers
grow; network-level cover traffic is the durable fix.

---

## Verification loop (post any change)

```
curl -s http://127.0.0.1:8080/api/health          # healthy, 6/6
curl -s -X POST http://127.0.0.1:8080/ethereum \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}'
./tests/run-all.sh                                 # repo matrix
docker logs mix-client --since 5m 2>&1 | grep -c 'Lost connection'   # 0
```
