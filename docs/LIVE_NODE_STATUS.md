# Live Node Status — Autonomi Testnet

**Activated:** 2026-07-03 21:20 UTC  
**Host:** zknode01 (Raspberry Pi CM4, 4GB RAM, aarch64)  
**Management:** `systemd --user` service (auto-start on boot, auto-restart on failure)

---

## Node Identity

```
Peer ID:      d9f87b16195ee7ac9614d70ba9d8bbd59361cb55f4c85415ee5511a7bb77bedd
Binary:       ant-node 0.14.2 (statically linked ARM64)
Port:         UDP/QUIC :12000, IPv4-only mode
Network:      Autonomi Testnet
EVM:          Arbitrum Sepolia
Bootstrap:    7 peers (standard testnet bootstrap_peers.toml)
```

## Wallet

```
Address:      0xef902cC111D5435C5116c123771D9459FC77AD4B
Balance:      ~0.04 ETH (Arbitrum Sepolia)
Network:      Arbitrum Sepolia testnet
Purpose:      Rewards address for storage payments
```

## Systemd Service

```
Unit:         ant-node.service (~/.config/systemd/user/)
Type:         simple
User:         zero-tech (uid 1001)
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
    --rewards-address 0xef902cC111D5435C5116c123771D9459FC77AD4B \
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
| DHT peers | ~100 connected |
| NAT traversal coordinators | 5 bootstrap peers |
| Replication protocol | `/rr/autonomi.ant.replication.v2` (active) |
| Public IP | 24.31.26.231 (confirmed by multiple peers) |
| Memory usage | ~20MB resident |
| File descriptors | ~50 open |

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

---

## Related Files in Repo

- `config/ant-node/ant-node.service` — Systemd unit file (reference)
- `README.md` — Full architecture and live node summary
- `docs/POC_DEPLOYMENT_PLAN.md` — Full deployment plan
- `docs/DEMO_SCRIPT.md` — Verification steps
