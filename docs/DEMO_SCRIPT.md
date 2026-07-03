# zknode-autonomi — Live Demo Script

**Post-Quantum Mixnet + ZK Storage Proving + Autonomi P2P Storage**

Verified working with 14 containers, 3.2s mixnet roundtrip, 100% echo success rate.

---

## Prerequisites

- Docker Engine 24+ with Compose v2
- 8GB+ RAM (build machine), 8GB RAM (SCM4 target)
- 25GB free disk for images and data (mixnet-node is 1.5GB)
- Pre-built Docker images on SCM4 or build machine

---

## Quick Validation (30 seconds)

```bash
# Verify the mixnet works end-to-end
docker stop mix-client 2>/dev/null
docker run --rm --network host \
  -v $(pwd)/config/mixnet:/cfg \
  zeros/mixnet-node:arm64 \
  /usr/local/bin/ping -c /cfg/client/client.toml -s echo -n 1
```

Expected:
```
Sending 1 Sphinx packets to +echo@servicenode1
!
Success rate is 100 percent (1/1)
```

---

## Full Demo (5-10 minutes)

### 1. Check Prerequisites

```bash
cd zknode-autonomi

# Verify images
docker images | grep 'zeros/' | wc -l
# Expected: 7

# System resources
free -h | head -2
# Expected: 8GB total, >3GB available
df -h / | tail -1
# Expected: >5GB free
```

### 2. Start the Stack

```bash
docker compose up -d
```

All 14 containers start. The dirauths generate PKI consensus within ~2 minutes.

```bash
# Watch startup
watch -n 2 'docker compose ps --format "table {{.Name}}\t{{.State}}"'
```

Expected after ~2 minutes:

```
NAME              STATE
mix-dirauth-1     running
mix-dirauth-2     running
mix-dirauth-3     running
mix-1             running
mix-2             running
mix-3             running
mix-gateway       running
mix-servicenode   running
mix-client        running
mixnet-proxy      running
walletshield      running
storage-proved    running
antd              running
```

### 3. Verify Mixnet Consensus

```bash
# Check proxy status
curl -s http://127.0.0.1:9090/status | python3 -m json.tool
```

Expected:
```json
{
    "mixnet_connected": true,
    "bytes_forwarded": 0,
    "active_circuits": 0,
    "uptime_seconds": 45
}
```

### 4. Test the Mixnet Echo (THE key demo)

```bash
# Automatic test — sends "Hello!" through the PQ mixnet, waits for reply
python3 -c "
import socket,struct,time
s=socket.socket();s.settimeout(15)
s.connect(('127.0.0.1',1080))
s.send(bytes([5,1,0]));s.recv(2)
s.send(bytes([5,1,0,3,4])+b'echo'+struct.pack('>H',7))
r=s.recv(10)
if r[1]==0:
 s.send(b'Hello mixnet!');t0=time.time()
 s.settimeout(15);d=s.recv(4096)
 print(f'Reply: {d[:20]} in {round(time.time()-t0,1)}s')
 if d[:14]==b'Hello mixnet!':print('*** MIXNET ECHO WORKS! ***')
s.close()
"
```

Expected:
```
Reply: b'Hello mixnet!...' in 3.2s
*** MIXNET ECHO WORKS! ***
```

This proves the **full post-quantum mixnet roundtrip**: SOCKS5 → thin client → kpclientd → gateway → mix-3 → mix-2 → mix-1 → servicenode echo → SURB reply → back.

### 5. ZK Proof Endpoints

```bash
# Bandwidth proof
curl -s http://127.0.0.1:9090/prove/bandwidth | python3 -m json.tool

# Storage challenge
curl -s http://127.0.0.1:9090/prove/challenge | python3 -m json.tool

# Storage proof (post challenge index)
curl -s -X POST http://127.0.0.1:9090/prove/storage \
  -H 'Content-Type: application/json' \
  -d '{"index":0,"nonce":"0000"}' | python3 -m json.tool
```

Expected (bandwidth):
```json
{
    "bytes_forwarded": 0,
    "active_circuits": 0,
    "proof_type": "merkle_chain",
    "verified": true,
    "uptime_seconds": 120
}
```

### 6. WalletShield EVM RPC

```bash
# Verify walletshield is serving through mixnet
curl -s http://127.0.0.1:9200 -o /dev/null -w "%{http_code}\n"
# Expected: 200
```

### 7. Storage Proof Daemon

```bash
# Check Rust Winterfell prover status
docker exec antd sh -c "apt-get update -qq && apt-get install -y -qq curl 2>/dev/null && curl -s http://storage-proved:9201/status" 2>/dev/null || \
  docker logs storage-proved | head -3
```

Expected:
```
storage-proved-rs: listening on 0.0.0.0:9201
```

### 8. Hardware Attestation (SCM4 only)

```bash
# Generate zymkey-attested storage proof
python3 scripts/zymkey-attest.py \
  --merkle-root e55cb05aafa6f3d5b5f8f87bd7d989dd \
  --node-address 0xef902cC111D5435C5116c123771D9459FC77AD4B
```

### 9. Monitor

```bash
# Real-time container status
watch -n 2 'docker compose ps'

# Proxy API health
curl -s http://127.0.0.1:9090/health
# Expected: ok

# Bandwidth metrics
curl -s http://127.0.0.1:9090/prove/bandwidth
```

### 10. Teardown

```bash
docker compose down
```

To remove all data and start fresh:
```bash
docker compose down -v
rm -rf data/ config/mixnet/auth*/*.db config/mixnet/auth*/*.log
```

---

## Verification Checklist

- [ ] All 14 containers running (`docker compose ps`)
- [ ] Mixnet echo: `Hello mixnet!` returns in ~3s
- [ ] Proxy API: `mixnet_connected: true`
- [ ] Ping binary: 100% success rate
- [ ] Bandwidth proof: `/prove/bandwidth` returns valid JSON
- [ ] Storage proof: `/prove/storage` returns Merkle proof
- [ ] WalletShield: port 9200 responding
- [ ] Storage prover: running on port 9201 (internal)

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `mixnet_connected: false` | Wait 2 min for PKI consensus |
| Port 64332 in use | Kill host process: `kill $(lsof -ti :64332)` |
| Disk full | `docker system prune -af` |
| Servicenode restarting | Check config: `docker logs mix-servicenode` |
| kpclientd "not connected" | Restart all 3 dirauths at epoch start (every 20 min) |

---

## Air-Gapped SCM4 Deployment

```bash
# On build machine
docker save zeros/mixnet-node:arm64 zeros/mixnet-proxy:arm64 \
  zeros/ant-node:arm64 zeros/antd:arm64 \
  zeros/storage-proved-rs:arm64 zeros/walletshield:arm64 | \
  gzip > zknode-images.tar.gz

# Transfer to SCM4 (SD card)
cp zknode-images.tar.gz /media/sdcard/

# On SCM4
cd zknode-autonomi
gunzip -c /media/sdcard/zknode-images.tar.gz | docker load
docker compose up -d
# Wait 2 min for PKI consensus
curl -s http://127.0.0.1:9090/status
```

---

## Demo Talking Points

1. **Post-quantum wire protocol**: MLKEM768 KEM for all mixnet links (NIST PQC standard)
2. **Privacy guarantees**: 3-hop Sphinx routing hides which SCM4 sent which data
3. **ZK storage proofs**: Prove chunk storage without revealing data (BLAKE2b Merkle trees)
4. **Hardware binding**: zymkey HSM attests node identity to storage commitment
5. **Self-contained**: All 14 containers run on a single SCM4 — no cloud dependency
6. **Metadata-private chat**: chatd component for group communication through the mixnet
7. **P4P ready**: Designed for proof-of-useful-work — node proves storage + bandwidth
