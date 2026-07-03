# zknode-autonomi — Architecture

## System Layers

```
┌───────────────────────────────────────────────────────────┐
│                   Application Layer                       │
│  ┌─────────┐  ┌──────────┐  ┌──────────┐                  │
│  │ ant CLI │  │ custom   │  │ monitor  │                  │
│  │ (shell) │  │ apps     │  │ scripts  │                  │
│  └────┬────┘  └──────────┘  └──────────┘                  │
│       │ docker exec antd ant <command>                    │
│       │ (ant-node runs as systemd --user, not Docker)     │
├───────┼───────────────────────────────────────────────────┤
│       ▼          Service Orchestration                    │
│  ┌────────────────────────────────────────┐               │
│  │     Docker Compose (15 services)       │               │
│  │ host network (mixnet) + bridge (auto)  │               │
│  │ + systemd --user (ant-node bare metal) │               │
│  └────────────────────────────────────────┘               │
├───────────────────────────────────────────────────────────┤
│               Storage + ZK Proof Layer                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐     │
│  │ Autonomi │  │ storage- │  │ mixnet-proxy         │     │
│  │ Chunk DB │  │ proved   │  │ (ZK proof API :9090) │     │
│  │ (LMDB)   │  │ :9201    │  │ → proxies to :9201   │     │
│  └──────────┘  └──────────┘  └──────────────────────┘     │
├───────────────────────────────────────────────────────────┤
│                  Transport Layer                          │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  Katzenpost mixnet (host network, 127.0.0.1)         │ │
│  │  dirauth×3 + mix×3 + gateway + servicenode           │ │
│  │  3-hop onion routing, post-quantum Sphinx packets    │ │
│  └──────────────────────────────────────────────────────┘ │
├───────────────────────────────────────────────────────────┤
│                  Integration Layer                        │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  mixnet-proxy (SOCKS5 bridge, ~300 lines Go)         │ │
│  │  ant-node ─SOCKS5──▶ proxy ─onion──▶ Autonomi peers  │ │
│  └──────────────────────────────────────────────────────┘ │
├───────────────────────────────────────────────────────────┤
│               Hardware Abstraction                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │ SCM4     │  │ zymkey   │  │ USB 3.0  │  │ Ethernet │   │
│  │ 8GB RAM  │  │ USB ACM7 │  │ Drives   │  │ Gigabit  │   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
└───────────────────────────────────────────────────────────┘
```

## Data Flow: Anonymous Storage

```
User: docker exec antd ant file upload secret.pdf --public
  │
  ▼
ant CLI → ant-node (via local API)
  │ Reads file, self-encrypts into chunks (ChaCha20-Poly1305 + BLAKE3)
  │ Chunks have XOR addresses derived from content hash
  ▼
ant-node (storage node)
  │ Bound to host network via SOCKS5 proxy
  │ All outbound traffic → host.docker.internal:1080
  ▼
mixnet-proxy
  │ SOCKS5 endpoint → wraps packets in mixnet SURBs
  │ Sends through 3-hop mixnet circuit
  │ Management API: http://127.0.0.1:9090/status
  ▼
mix-servicenode (mixnet exit)
  │ Decrypts final onion layer
  │ Forwards to external Autonomi peer via QUIC
  ▼
Autonomi peer (external)
  ├── Sees connection from mix-servicenode IP
  ├── Cannot determine SCM4's real IP
  ├── Verifies payment, stores chunk
  └── Returns acknowledgment → reverse path through mixnet
```

## Network Topology

```
┌──────────────────────────────────────────┐
│  Host Network (network_mode: host)       │
│                                          │
│  mix-dirauth-1 127.0.0.1:30001           │
│  mix-dirauth-2 127.0.0.1:30002           │
│  mix-dirauth-3 127.0.0.1:30003           │
│  mix-1         127.0.0.1:30011           │
│  mix-2         127.0.0.1:30014           │
│  mix-3         127.0.0.1:30017           │
│  mix-gateway   127.0.0.1:30004           │
│  mix-servicenode 127.0.0.1:30007         │
│  mix-client      127.0.0.1:64332         │
│  mixnet-proxy    127.0.0.1:1080,9090     │
│  walletshield    127.0.0.1:9200          │
│  storage-proved  127.0.0.1:9201          │                         │                (port mapped from bridge) │
├──────────────────────────────────────────┤
│  Bridge Network (zknode-autonomi-net)    │
│                                          │
│  antd          (idle, docker exec)       │
│                                          │
├──────────────────────────────────────────┤
│  Bare Metal (systemd --user)             │
│                                          │
│  ant-node      UDP :12000 (QUIC)         │
│  zkifc         USB :/dev/ttyACM7 (HSM)   │
└──────────────────────────────────────────┘
```

## Key Properties

- **All Autonomi P2P traffic** flows through SOCKS5 → mixnet — no direct connections
- **External peers** see the mixnet servicenode's IP, never the SCM4
- **Mixnet runs entirely on SCM4** — no external infrastructure
- **Chunk data** encrypted client-side (self-encryption) before reaching node
- **Transport encryption**: QUIC + post-quantum ML-KEM-768 + ML-DSA-65
- **DHT operations** (Kademlia lookups, close group replication) through mixnet
- **Config generation**: Built-in genconfig tool (katzenpost v0.0.73-rc3)
- **Dirauth stability**: Internal retry loop handles consensus race condition

## Container Dependency Graph

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
        │               │
        └───────┬───────┘
                ▼
         mixnet-proxy
                │
                ▼
            ant-node
                │
                ▼
              antd
```
