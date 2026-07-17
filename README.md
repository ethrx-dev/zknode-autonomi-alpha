# zknode-autonomi

**Any old computer can become a private Autonomi node.**

A self-contained anonymous Autonomi storage node that routes all P2P traffic through an embedded Katzenpost mixnet. No VPS, no cloud dependency — the entire mixnet runs on the same device as the storage node.

**Hardware**: Raspberry Pi CM4/SCM4 (8GB RAM, aarch64) or any machine with 8GB RAM + Docker.  
**Storage**: microSD for configs, USB SSD for pool/chunk storage.  
**Security**: ZSCM HSM, LUKS encryption, post-quantum cryptography.

---

## Architecture

```
MetaMask ──JSON-RPC──▶ walletshield ──mixnet──▶ upstream ETH RPC
                          │                   
web UI ──▶ zknode-dashboard ──▶ zkchat ──mixnet──▶ group chat / DMs
              │
              ├──▶ docker API ──▶ mixnet containers
              ├──▶ zymkey-api ──▶ ZSCM HSM
              └──▶ ant node daemon
```

- **Layer 1**: Hardware (SCM4, ZSCM HSM, USB SSD)
- **Layer 2**: Mixnet (Katzenpost: 3 dirauths + 3 mixes + gateway + servicenode)
- **Layer 3**: Privacy-preserving apps (walletshield RPC proxy, zkchat messaging)
- **Layer 4**: Storage (Autonomi ant-node with LMDB chunk store)
- **Layer 5**: Dashboard (web UI for monitoring, chat, wallet, wiki)

---

## Services

| Service | Role | Port |
|---------|------|------|
| mix-dirauth-1/2/3 | Directory authorities (PKI consensus) | — |
| mix-1/2/3 | Mix nodes (3-hop onion routing) | — |
| mix-gateway | Client gateway | 64332 |
| mix-servicenode | Mixnet exit node (chatd, http-proxy Kaetzchen) | — |
| mix-client | Thin client daemon (kpclientd) | 64332 |
| walletshield | Ethereum JSON-RPC over mixnet | 9200 |
| zkchat | CLI encrypted messaging (group + DM) | — |
| zknode-dashboard | Web UI (monitoring, chat, wiki, ant) | 8080 |
| mixnet-proxy | SOCKS5 bridge (ant-node ↔ mixnet) | 1080/30004 |
| storage-proved | Autonomi storage proving node | — |
| zymkey-api | ZSCM HSM HTTP API | 8765 |

---

## Quick Start

### Deploy full stack

```bash
cd zknode-autonomi
docker compose up -d
```

### Access dashboard

```
http://<host-ip>:8080
```

### Send encrypted chat message

```bash
# Group message
docker run --rm --network host -v $PWD/config/mixnet:/var/lib/katzenpost zeros/mixnet-node-fixed:v0.0.84 \
  zkchat group send /var/lib/katzenpost/client/thinclient.toml <group_id> "hello"

# Direct message
docker run --rm --network host -v $PWD/config/mixnet:/var/lib/katzenpost zeros/mixnet-node-fixed:v0.0.84 \
  zkchat send /var/lib/katzenpost/client/thinclient.toml <recipient_hex> "hello"
```

### Ethereum RPC over mixnet

```bash
# Local SSH tunnel
ssh -L 9200:127.0.0.1:9200 -N -f user@host

# Use in MetaMask
# Network: http://127.0.0.1:9200/ethereum
# Chain ID: 1 (Mainnet)
```

---

## File Structure

```
zknode-autonomi/
├── docker-compose.yml             # Full 14-service stack
├── docker-compose.zymkey.yml      # ZSCM HSM override
├── Dockerfile.mixnet              # Katzenpost mixnet node
├── Dockerfile.walletshield        # Ethereum RPC proxy
├── Dockerfile.mixnet-proxy        # SOCKS5 bridge
├── Dockerfile.antd                # Ant node daemon
├── Dockerfile.replica             # Replica node
├── config/
│   ├── mixnet/                    # Mixnet PKI + node configs
│   │   ├── auth1-3/               # Directory authorities
│   │   ├── mix1-3/                # Mix nodes
│   │   ├── gateway1/              # Client gateway
│   │   ├── servicenode1/          # Exit node (chatd, http-proxy)
│   │   ├── client/                # Thin client config
│   │   └── servicenode-entrypoint.sh
│   ├── walletshield/             # Thin client config
│   ├── proxy/                     # SOCKS5 proxy config
│   ├── autonomi/                  # Ant node configs
│   └── reticulum/                 # Reticulum config
├── zknode-dashboard/              # Web UI
│   ├── server/index.js            # Express backend
│   ├── public/index.html          # Frontend
│   └── Dockerfile
├── scripts/
│   ├── deploy.sh                  # Deploy/start/stop
│   ├── setup.sh                   # Init project structure
│   ├── gen-mixnet-configs.sh      # Mixnet config generator
│   ├── monitor.sh                 # Stack monitoring
│   ├── setup-zymbit.sh            # Zymkey/HSM setup
│   └── zymkey-attest.py           # HSM attestation
├── docs/                          # Documentation
└── README.md
```

---

## Scripts

| Command | Description |
|---------|-------------|
| `./scripts/deploy.sh --start` | Deploy and start full stack |
| `./scripts/deploy.sh --stop` | Stop stack |
| `./scripts/deploy.sh --check` | Verify prerequisites |
| `./scripts/monitor.sh` | Display stack status |
| `./scripts/setup.sh` | Initialize configs and data dirs |
| `./scripts/gen-mixnet-configs.sh` | Generate mixnet node configs |
| `./scripts/setup-zymbit.sh --check` | HSM health check |
| `./scripts/setup-zymbit.sh --full` | Full Zymbit security setup |

---

## API Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /api/chat/identity` | User's zkchat identity hex |
| `GET /api/chat/groups` | List user's groups |
| `POST /api/chat/groups/send` | Send group message |
| `GET /api/chat/groups/poll` | Poll group messages |
| `POST /api/chat/groups/create` | Create group |
| `POST /api/chat/send` | Send direct message |
| `GET /api/chat/poll` | Poll direct messages |
| `GET /api/ant/wallet` | Ant node wallet address |
| `GET /api/ant/balance` | ANT/ETH balance |
| `GET /api/zymkey/eth-address` | ZSCM-derived ETH address |
| `GET /api/system` | System stats (CPU, RAM, disk) |
| `GET /api/containers` | Docker container status |

---

## Known Limitations

- **Host networking**: Mixnet containers share the host network (only one instance per port).
- **Dirauth startup race**: All 3 authorities must be running to reach consensus. Mitigated by retry loops.
- **Message persistence**: zkchat group messages are stored in chatd until first poll, then deleted. Dashboard persists polled messages to `chat-history.json`.
- **walletshield**: Requires SSH tunnel for MetaMask (`http` only works for localhost). Use `ssh -L 9200:127.0.0.1:9200`.
- **ZSCM integration**: HSM provides key generation and signing for ant node rewards. Full transaction signing is functional via `sign_eth` endpoint.

---

## Documentation

- [PoC Deployment Plan](docs/POC_DEPLOYMENT_PLAN.md) — Full deployment walkthrough
- [Architecture](docs/ARCHITECTURE.md) — System layers and data flow
- [Hardware Setup](docs/HARDWARE_SETUP.md) — SCM4 hardware, storage, USB pool
- [Zymbit/SCM4 Setup](docs/ZYMBIT_SETUP.md) — zymkey HSM, Bootware, LUKS, tamper, wallet
- [Mixnet Integration](docs/MIXNET_INTEGRATION.md) — Integration design options
- [Demo Script](docs/DEMO_SCRIPT.md) — Step-by-step demo walkthrough

---

## License

Source code: AGPL-3.0-only.  
Documentation: CC-BY-SA-4.0.

**WARNING**: This is a Proof of Concept. Not production-hardened.
