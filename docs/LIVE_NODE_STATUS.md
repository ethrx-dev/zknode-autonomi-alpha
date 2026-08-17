# Live Node Status — Autonomi Testnet

**Activated:** 2026-07-03 21:20 UTC
**Host:** SCM4 (Raspberry Pi SCM4, 8GB RAM, aarch64)
**Management:** `systemd --user` service (auto-start on boot, auto-restart on failure)

---

## Node Identity

```
Peer ID:      <peer-id>
Binary:       ant-node 0.14.4 (statically linked ARM64)
Port:         UDP/QUIC :12000, IPv4-only mode
Network:      Autonomi Testnet
EVM:          Arbitrum Sepolia
Bootstrap:    7 peers (standard testnet bootstrap_peers.toml)
```

## Wallet

```
Address:      0x0000...0000
Balance:      <balance> (Arbitrum Sepolia)
Network:      Arbitrum Sepolia testnet
Purpose:      Rewards address for storage payments
```

## Systemd Service

```
Unit:         ant-node.service (~/.config/systemd/user/)
Type:         simple
User:         <node-user> (uid 1001)
Restart:      always, 10s backoff
Startup:      enabled (WantedBy=default.target)
Stop-on-upgrade: true (systemd restarts after upgrade exit)
```

### Service Config

The service unit lives at `~/.config/systemd/user/ant-node.service` on the SCM4.
A reference copy is maintained in this repo at `config/ant-node/ant-node.service`.

```ini
[Unit]
Description=Autonomi Testnet Node
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=%h/zknode-autonomi/data/antd/.local/share/ant/nodes/node-1
ExecStart=%h/zknode-autonomi/data/antd/.local/share/ant/nodes/node-1/ant-node \
    --root-dir %h/zknode-autonomi/data/antd/.local/share/ant/nodes/node-1 \
    --port 12000 \
    --rewards-address 0x0000...0000 \
    --evm-network arbitrum-sepolia \
    --network-mode testnet \
    --ipv4-only \
    --enable-logging \
    --log-level debug \
    --log-dir %h/zknode-autonomi/data/logs \
    --stop-on-upgrade
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ant-node

[Install]
WantedBy=default.target
```

### Management Commands

```bash
systemctl --user status ant-node     # Check status
systemctl --user restart ant-node    # Restart
systemctl --user stop ant-node       # Stop
systemctl --user start ant-node      # Start
journalctl --user -u ant-node -f     # Tail logs (journal)
tail -f ~/zknode-autonomi/data/logs/ant-node.YYYY-MM-DD.log  # File logs (daily rotation, 7 days)
```

---

## Data Paths

| Path | Purpose |
|------|---------|
| `~/zknode-autonomi/data/antd/.local/share/ant/nodes/node-1/` | Node root dir (binary, identity, bootstrap) |
| `~/zknode-autonomi/data/antd/.local/share/ant/nodes/node-1/chunks.mdb/` | LMDB chunk store |
| `~/zknode-autonomi/data/antd/.local/share/ant/nodes/node-1/paid_list.mdb/` | Paid client tracking |
| `~/zknode-autonomi/data/antd/.local/share/ant/nodes/node-1/node_identity.key` | Node identity (Ed25519) |
| `~/zknode-autonomi/data/antd/.local/share/ant/nodes/node-1/bootstrap_peers.toml` | Bootstrap peers |
| `~/zknode-autonomi/data/logs/` | Daily rotating logs |

---

## Runtime Metrics

| Metric | Value |
|--------|-------|
| DHT peers | ~230 connected |
| NAT traversal coordinators | 5 bootstrap peers |
| Replication protocol | `/rr/autonomi.ant.replication.v2` (active) |
| Public IP | <your-public-ip> (confirmed by multiple peers) |
| Memory usage | ~20MB resident |
| File descriptors | ~50 open |

---

## ZK Storage Proofs

| Metric | Value |
|--------|-------|
| Status | 🟢 Active |
| Chunks | 10 (test data, 4KB each) |
| Merkle root | `a9cfc0c6...02ed36` |
| Proof size | 264 bytes (BLAKE3 Merkle path) |
| API | `http://127.0.0.1:9201` (storage-proved-rs) |
| Proxy API | `http://127.0.0.1:9090/prove/bandwidth` → `verified: true` |

**Endpoints:**
```bash
curl http://127.0.0.1:9201/status          # Merkle tree state
curl http://127.0.0.1:9201/challenge       # Random proof challenge
curl -X POST http://127.0.0.1:9201/prove \ # Generate Merkle proof
  -H "Content-Type: application/json" -d '{"index":0}'
curl http://127.0.0.1:9090/prove/bandwidth  # Bandwidth proof via proxy
```

The `storage-proved-rs` Docker container reads chunk files from `/mnt/autonomi/zknode-autonomi/chunks/`, builds a BLAKE3 Merkle tree, and serves proof generation/verification on port 9201 (mapped to host). The `mixnet-proxy` service forwards `/prove/challenge` and `/prove/storage` requests to storage-proved via localhost.

---

## HSM / Zymkey

| Metric | Value |
|--------|-------|
| Status | 🟢 Active |
| Service | `zkifc.service` (systemd, host) |
| Device | `/dev/ttyACM7` (USB serial, symlink `/dev/zscm_7`) |
| Uptime | 19+ hours |
| Wallet | Stored at `/var/lib/zymbit/<device-id>/` |
| RTC sync | Working, NTP-ready |

**Note:** The Docker compose `zkifc` container is **deprecated** — the zymkey is managed by the host-level systemd service. The compose container was removed because:
- It used `alpine:3.21` which lacks the `zkifc` binary
- It tried to map `/dev/zymkey` (I2C) but the actual device is USB serial (`/dev/ttyACM7`)
- Host systemd service runs as user `zymbit` with proper permissions

Zymbit packages installed: `libzk`, `libzymkeyssl`, `zkapputilslib`, `zkifc`, `zkpkcs11`, `zksaapps`, `zkbootrtc`.

---

## walletshield

| Metric | Value |
|--------|-------|
| Status | 🟡 PKI syncing |
| Port | TCP :9200 |
| Service | `proxy` (CBORPluginKaetzchen, http-proxy-server) |
| Image | `zeros/walletshield:arm64` (rebuilt with `ProxyHTTPService = "proxy"`) |

walletshield routes EVM JSON-RPC through the mixnet to the `proxy` kaetzchen, which forwards to Arbitrum Sepolia RPC. Currently timing out on mixnet message send while PKI re-stabilizes after dirauth restarts. Service resolution works (no panic), just waiting for full consensus.

---

## Activation Notes

1. **No explicit on-chain registration needed** on Autonomi testnet — nodes earn rewards by serving data to paid clients, not via a registration transaction.
2. The `paid_list.mdb` tracks which clients have paid for data storage. This fills as clients use the network.
3. The rewards address receives ANT tokens (on Arbitrum Sepolia) when the node serves paid data.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Service exits with `Permission denied (os error 13)` | LMDB files owned by wrong user. Run `find ~/zknode-autonomi/data/antd -not -user $(whoami) -delete` then restart. |
| Node not connecting to peers | Check firewall: UDP port 12000 must be open. Test with `ss -ulnp \| grep 12000`. |
| Peer count dropping | Check systemd logs: `journalctl --user -u ant-node -f`. Look for "dropping packet with invalid CID" (normal after restart). |
| Binary won't start from host | Ensure binary is statically linked ARM64: `file ~/zknode-autonomi/data/antd/.local/share/ant/nodes/node-1/ant-node`. |
| ant CLI daemon crash | The `ant node daemon start` crashes on the antd container due to bind mount permission conflicts. Use direct binary execution or the systemd service instead. |
| storage-proved-rs panic (OOB) | Fixed in commit `0ea8e1e`. Rebuild with `docker build -f Dockerfile.storage-proved-rs`. |
| walletshield "service not found" | Rebuild with `ProxyHTTPService = "proxy"` (commit `1456372`). Default upstream hardcodes `"http_proxy"`. |
| walletshield "context deadline exceeded" | PKI syncing after dirauth restart. Wait ~40 min or restart all 3 dirauths simultaneously. |

---

## Related Files in Repo

- `config/ant-node/ant-node.service` — Systemd unit file (reference)
- `Dockerfile.walletshield` — Builds fixed walletshield with correct service name
- `walletshield-fix/main.go` — Patched walletshield source
- `README.md` — Full architecture and live node summary
- `docs/ARCHITECTURE.md` — System layers and data flow
- `docs/POC_DEPLOYMENT_PLAN.md` — Full deployment plan
- `docs/DEMO_SCRIPT.md` — Verification steps
- `docs/ZYMBIT_SETUP.md` — HSM setup (host systemd, not Docker)
