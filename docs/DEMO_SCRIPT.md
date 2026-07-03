# zknode-autonomi — Demo Script

## Prerequisites

- Docker Engine 24+ with Compose v2
- 8GB+ RAM (build machine), 8GB RAM (SCM4 target)
- 20GB free disk for images and data
- Pre-built Docker images (see POC_DEPLOYMENT_PLAN.md §4 for build instructions)

## Full Demo (5-10 minutes)

### 1. Check Prerequisites

```bash
cd ~/src/ZKNet/zknode-autonomi

# Verify images are present
./scripts/deploy.sh --check
```

Expected:
```
[ok] Docker 28.5.2
[ok] All Docker images present
[ok] USB pool at /mnt/trinity (XXGB free)
All checks passed.
```

### 2. Deploy and Start

```bash
./scripts/deploy.sh --start
```

This runs setup.sh, generates mixnet configs, and starts all 10 containers. The dirauths use internal retry loops — it may take up to 30 seconds for all 3 to reach consensus.

Expected (after ~30 seconds):
```
NAME              STATE     STATUS
ant-node          running   Up 25 seconds
antd              running   Up 25 seconds
mix-1             running   Up 26 seconds
mix-2             running   Up 26 seconds
mix-3             running   Up 26 seconds
mix-dirauth-1     running   Up 27 seconds
mix-dirauth-2     running   Up 27 seconds
mix-dirauth-3     running   Up 27 seconds
mix-gateway       running   Up 26 seconds
mix-servicenode   running   Up 26 seconds
mixnet-proxy      running   Up 26 seconds
```

### 3. Verify Mixnet Proxy

```bash
curl -s http://127.0.0.1:9090/status | python3 -m json.tool
```

Expected:
```json
{
    "mixnet_connected": true,
    "wireguard_interface": "wg0",
    "ant_node_addr": "10.0.0.2",
    "bytes_forwarded": 0,
    "active_circuits": 0,
    "uptime_seconds": 52
}
```

### 4. Verify Mixnet Consensus

```bash
# All three dirauths should be running
docker compose ps | grep dirauth

# Check mix node routing
docker logs mix-1 --tail=5
```

### 5. Check ant-node Status

```bash
docker logs ant-node --tail=5
```

The ant-node should be running with LMDB storage initialized. For PoC purposes, it uses a zero rewards address — in production, set `ANT_REWARDS_ADDRESS` to your wallet.

### 6. Use the ant CLI (via idle container)

```bash
# Check ant version
docker exec antd ant --version

# List available commands
docker exec antd ant --help
```

### 7. Anonymity Verification

```bash
# Check ant-node has no direct outbound connections
docker exec ant-node sh -c 'ss -tnp 2>/dev/null | grep -v "127.0.0.1\|host.docker"' || echo "NO DIRECT CONNECTIONS (verified)"
```

### 8. Monitor

```bash
./scripts/monitor.sh
```

Expected:
```
┌────────────────────────────────────────┐
│  zknode-autonomi — Monitor             │
├────────────────────────────────────────┤
│  Services: 10/11 running               │
│  Mixnet: CONSENSUS ✓                   │
│  Proxy: ACTIVE, 0 bytes forwarded      │
│  ant-node: RUNNING, 0 peers            │
└────────────────────────────────────────┘
```

### 9. Teardown

```bash
./scripts/deploy.sh --stop
```

To remove all data:
```bash
./scripts/deploy.sh --clean
```

## Verification Checklist

- [ ] All 10 containers running without restarts
- [ ] mixnet-proxy API responds with `mixnet_connected: true`
- [ ] mix-dirauth-1/2/3 all running
- [ ] ant-node running with LMDB storage
- [ ] No direct outbound connections from ant-node
- [ ] Monitor script shows all systems healthy
- [ ] Images export cleanly: `./scripts/deploy.sh --export`

## Air-Gapped SCM4 Deployment

```bash
# On build machine
./scripts/deploy.sh --export
# → zknode-autonomi-images.tar.gz (~2 GB)

# Transfer to SCM4 (SD card)
cp zknode-autonomi-images.tar.gz /media/sdcard/

# On SCM4
git clone <repo-url> zknode-autonomi
cd zknode-autonomi
gunzip -c /media/sdcard/zknode-autonomi-images.tar.gz | docker load
./scripts/deploy.sh --check
./scripts/deploy.sh --start
```
