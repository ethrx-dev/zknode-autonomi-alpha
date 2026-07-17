# zknode-autonomi — Architecture

## System Layers

```
┌──────────────────────────────────────────────────────────────────┐
│                       Application Layer                          │
│  ┌──────────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │ zknode-      │  │ zkchat   │  │ walletshield  │ llm-wiki│   │
│  │ dashboard    │  │ (CLI/API)│  │ ETH RPC prox  │ (local) │   │
│  └──────┬───────┘  └────┬─────┘  └─────┬──────┘  └────┬─────┘   │
│         │               │              │              │          │
│         ▼               ▼              ▼              ▼          │
│                    Mesh & Storage Layer                           │
│  ┌────────────────┐ ┌────────────────┐ ┌──────────────────┐     │
│  │  Reticulum     │ │  Nomadnet      │ │  Autonomi        │     │
│  │  (transport)   │ │  (chat/wiki)   │ │  ant-node +   │     │
│  │  LoRa/Packet   │ │  over RNS      │ │  storage-proved   │     │
│  └───────┬────────┘ └───────┬────────┘ └────────┬─────────┘     │
├──────────┼──────────────────┼───────────────────┼────────────────┤
│          ▼                  ▼                   ▼                │
│              Service Orchestration                                │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │          Docker Compose (16+ services)                     │   │
│  │  host network (mixnet) + bridge + overlay + systemd timer │   │
│  └───────────────────────────────────────────────────────────┘   │
├──────────────────────────────────────────────────────────────────┤
│                       Transport Layer                              │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │  Katzenpost mixnet (host network, 127.0.0.1)             │   │
│  │  dirauth×3 + mix×3 + gateway + servicenode + client      │   │
│  │  3-hop onion routing, post-quantum Sphinx packets        │   │
│  │  CBOR plugins: chatd, http_proxy, courier (MLKEM768)     │   │
│  └───────────────────────────────────────────────────────────┘   │
├──────────────────────────────────────────────────────────────────┤
│               Security & Hardware Layer                            │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ SCM4/CM4 │  │ ZSCM HSM │  │ USB 3.0  │  │ LUKS     │        │
│  │ 8GB RAM  │  │ (I2C)    │  │ SSD      │  │ (zymkey) │        │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘        │
└──────────────────────────────────────────────────────────────────┘
```

## Data Flow: Encrypted Chat

```
User (dashboard UI) ──HTTP──▶ zknode-dashboard
  │                                │
  │  POST /api/chat/groups/send    │ zkchat CLI via Docker
  ▼                                ▼
zkchat ──group send──▶ kpclientd (mix-client)
  │                                │
  │  SURB through mixnet           │
  ▼                                ▼
mix-1 ──▶ mix-2 ──▶ mix-3 ──▶ mix-servicenode
                                │
                                ▼
                            chatd (CBOR plugin)
                          Stores in group_<id>/*.msg
                          Peers poll via kpclientd
```

## Data Flow: Ethereum RPC via walletshield

```
MetaMask ──JSON-RPC──▶ walletshield (thin client)
  │                        │
  │  POST /ethereum        │ SURB through mixnet
  ▼                        ▼
kpclientd ──▶ mix-1 ──▶ mix-2 ──▶ mix-3 ──▶ mix-servicenode
                                                │
                                     http_proxy Kaetzchen
                                                │
                                                ▼
                                        Upstream ETH RPC
                                        (e.g., Infura, Alchemy)
```

## Data Flow: Anonymous Storage (ant-node)

```
ant CLI ──▶ ant-node ──SOCKS5──▶ mixnet-proxy ──onion──▶ mixnet
                                                          │
                                                          ▼
                                                   Autonomi peer
                                              (sees servicenode IP)
```

## Network Topology

```
Host Network (network_mode: host)
├── mix-dirauth-1:30001
├── mix-dirauth-2:30002
├── mix-dirauth-3:30003
├── mix-1:30011
├── mix-2:30014
├── mix-3:30017
├── mix-gateway:30004
├── mix-servicenode:30008
├── mix-client (kpclientd):64332
├── walletshield:9200
├── zknode-dashboard:8080
├── mixnet-proxy:1080,9090
├── kpclientd (standalone):64332
├── storage-proved (bridge network)
├── storage-proved-rs (bridge network)
├── llm-wiki (bridge network)
├── nomadnet (bridge network)
└── reticulum (bridge network)
```

## Key Properties

- **All P2P traffic** flows through SOCKS5 → mixnet — no direct connections
- **External peers** see the mixnet servicenode's IP, never the SCM4
- **Chat messages** encrypted end-to-end through 3-hop mixnet
- **Ethereum RPC** requests anonymized through mixnet exit node
- **HSM-backed keys** via ZSCM (I2C), no plaintext private keys on disk
- **Post-quantum transport**: Sphinx packets with CTIDH-X25519 KEM

## Container Dependency

```
mix-dirauth-1 ──▶ mix-dirauth-2 ──▶ mix-dirauth-3
     │                                    │
     └──────────┬─────────────────────────┘
                ▼
           mix-1, mix-2, mix-3
                │
        ┌───────┴───────┐
        ▼               ▼
   mix-gateway    mix-servicenode
        │           │     │       │
        │      chatd  http_proxy  courier
        │               (walletshield)  (MLKEM768)
        ▼               ▼
   mix-client ──── walletshield ──▶ mixnet-proxy
        │                              │
        ├── zkchat (CLI/API)           └── ant-node
        │
        └── zknode-dashboard ──▶ llm-wiki ──▶ nomadnet ──▶ reticulum
                                     │
                          autonomi-wiki-sync.timer
```
