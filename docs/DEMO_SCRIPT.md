# zknode-autonomi — Demo Script

## Prerequisites

- Docker Engine 24+ with Compose v2
- 8GB+ RAM
- 10GB free disk
- Pre-built Docker images

## Full Demo (10-15 minutes)

### 1. Check System

```bash
cd zknode-autonomi
docker ps
```

Expected: 14 containers running (3 dirauths, 3 mixes, gateway, servicenode, client, walletshield, dashboard, proxy, storage-proved, buildkit)

### 2. Access Dashboard

Open `http://<host-ip>:8080` in a browser.

Tabs: System, Mixnet, Autonomi, ZKCHAT, Wiki, Walletshield, LLM Wiki, Prover, Ant

### 3. ZKCHAT Group Messaging

#### View your identity

Open ZKCHAT tab → your 32-char hex identity is displayed in the groups panel header. Click to copy.

#### Send a group message

```bash
# From CLI
docker run --rm --network host -v $PWD/config/mixnet:/var/lib/katzenpost \
  zeros/mixnet-node-fixed:v0.0.84 \
  zkchat group send /var/lib/katzenpost/client/thinclient.toml \
  <group_id> "Hello from mixnet!"
```

Or use the dashboard UI: type in the message box and click SEND.

### 4. Ethereum RPC via walletshield

```bash
curl -X POST http://127.0.0.1:9200/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

Returns current Ethereum block number routed through the mixnet.

### 5. MetaMask Configuration

1. Open MetaMask → Settings → Networks → Add Network
2. Network Name: `ZKNode Walletshield`
3. RPC URL: `http://127.0.0.1:9200/ethereum`
4. Chain ID: `1`
5. Currency: `ETH`
6. Save and switch to this network

Requires SSH tunnel: `ssh -L 9200:127.0.0.1:9200 -N -f user@host`

### 6. Mixnet Status

```bash
# Check PKI consensus
./scripts/monitor.sh

# Check individual nodes
docker logs mix-dirauth-1 --tail 5
docker logs mix-servicenode --tail 5
```

### 7. Security Features

- **ZSCM HSM**: Hardware-backed key generation and signing
- **LUKS encryption**: Full disk encryption via zymkey
- **Mixnet routing**: All outbound traffic through 3-hop onion routing

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Dashboard shows "mixnet unavailable" | kpclientd not connected | Wait for PKI epoch, check `docker logs mix-client` |
| Group messages not appearing | First poll deletes from chatd | Dashboard persists messages; poll again |
| walletshield "service not found" | HTTP proxy Kaetzchen not registered | Wait for next PKI epoch (~5min) |
| MetaMask connection refused | No SSH tunnel | `ssh -L 9200:127.0.0.1:9200 -N -f user@host` |
