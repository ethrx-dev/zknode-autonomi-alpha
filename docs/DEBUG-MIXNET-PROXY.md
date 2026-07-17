# mixnet-proxy — Debug Plan

## Symptom

Container runs but logs `"waiting for gateway…"` indefinitely. No gateway
connection established.

## Architecture

```
ant-node ←──SOCKS5── mixnet-proxy ──thinclient──▶ mixnet gateway (kpclientd:64332)
```

The proxy runs a katzenpost **thinclient** that connects to a mixnet gateway.
The thinclient needs:
1. A **provider** address (gateway's kpclientd endpoint)
2. Matching **Sphinx geometry** (packet length, hops) with the rest of the mixnet
3. Valid **gateway identity** (public key hash)

## Debug Checklist

### 1. Verify Gateway is Running

```bash
# On the server:
docker ps | grep mix-gateway
# Should show "Up" status

# Check kpclientd is listening:
ss -tlnp | grep 64332
# Should show LISTEN
```

### 2. Inspect Proxy Config

```bash
docker exec mixnet-proxy cat /app/config/thinclient.toml
```

Compare with known-good client config:

```bash
docker exec mix-client cat /app/config/thinclient.toml
```

Differences to look for:
- `provider_address` — must match gateway's kpclientd address (`127.0.0.1:64332`)
- `gateway_identity` — must match gateway's public key hash
- `[geometry]` — must match mixnet `PacketLength` and hops

### 3. Check Gateway Identity

```bash
# Get gateway's public key hash from gateway config:
docker exec mix-gateway cat /app/config/gateway.toml

# Or from a working client container:
docker exec mix-client cat /app/config/client.toml
```

The proxy's thinclient must list the correct `gateway_identity` hex string.

### 4. Test Direct Connection

```bash
# From the proxy container:
docker exec -it mixnet-proxy bash
curl -s http://127.0.0.1:64332  # should get some response
```

### 5. Validate Sphinx Geometry

The proxy was built with a specific geometry. Check:
```bash
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}'
```

If the proxy image was built with different geometry than the mixnet,
regenerate with matching parameters. See `docs/ARCHITECTURE.md`:
- `PacketLength = 3082`
- `NWorkers = 2`
- `NPayloadLength = (...)`
- `hopps = 5`

### 6. Network Namespace

The proxy container uses `network_mode: host` (like other mixnet containers).
Verify:
```bash
docker inspect mixnet-proxy | grep NetworkMode
```

## Known Fixes

### Fix A: Update thinclient.toml

```toml
[geometry]
PacketLength = 3082
NWorkers = 2

[gateway]
provider_address = "127.0.0.1:64332"
gateway_identity = "<from-gateway-config-hex>"
```

### Fix B: Rebuild Proxy with Correct Geometry

```dockerfile
# In Dockerfile.mixnet-proxy, ensure geometry matches
ARG SPHINX_PACKET_LENGTH=3082
ARG SPHINX_N_WORKERS=2
```

### Fix C: Check Gateway Logs

```bash
docker logs mix-gateway --tail 50
```

Look for:
- `"listening on 0.0.0.0:64332"` — gateway ready
- `"connection from <addr>"` — proxy trying to connect
- `"invalid handshake"` — geometry mismatch
- `"unknown gateway identity"` — identity mismatch

## Health Check

After fixing, verify:

```bash
curl -s --max-time 5 http://127.0.0.1:9090/status
# Expected: JSON with gateway_connected: true

# Test SOCKS5 tunnel:
curl -s --max-time 10 --proxy socks5h://127.0.0.1:9090 https://httpbin.org/ip
# Expected: {"origin": "<gateway-ip>"}
```
