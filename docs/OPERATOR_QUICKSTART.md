# Operator Quickstart — Connect or Add a zknode

The short, practical checklist. For the full design see
[BRIDGE_RELAY_DESIGN.md](BRIDGE_RELAY_DESIGN.md); for end users see
[USER_GUIDE.md](USER_GUIDE.md).

```
        Tailscale (private WireGuard mesh)
   box 100.66.60.127  ◄──────────────►  SCM4 100.75.15.108
   dashboard :8080                       dashboard :8080
   gateway   :31008  ◄── mesh bridge ──► gateway :31007
   mixnet99 + ZeroAI                     mixnet99 + wiki/MCP
```

Only the **gateways** need to be reachable across the tailnet. The bridge’s
embedded client fetches the peer PKI document **through the peer gateway**, so
peer authority ports do not need to be published.

---

## 1. Tailscale (both nodes)

Install once, then join with an auth key from the tailnet admin:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up --auth-key "tskey-auth-<KEY>" --hostname "zknode-<id>" --accept-dns
tailscale status          # both nodes should be visible, direct or relayed
```

## 2. Start the mixnet

**Box (compose project `zkomain`):**

```bash
cd ~/zknode-autonomi-v1
docker compose -p zkomain up -d
```

**SCM4:**

```bash
cd ~/zknode-autonomi-P4P-v.01/config/mixnet99
docker compose up -d
```

Verify an authority is producing consensus:

```bash
docker logs <auth-container> --tail 500 | grep "Consensus made for epoch"
```

All nodes must advertise a **reachable** address (hostname/IP), never
`tcp://0.0.0.0`. `BindAddresses` may stay `0.0.0.0`. If nodes dial
`0.0.0.0`, you will see `MAC mismatch` and handshake EOFs.

## 3. Publish each island’s gateway on the tailnet

- **Box:** gateway `30007` published as `0.0.0.0:31008` (docker port mapping).
- **SCM4:** exposure without restarting the gateway:

```bash
docker run -d --name scm4-gw-proxy --restart unless-stopped \
  --network mixnet99_katzenpost-net -p 0.0.0.0:31007:31007 \
  alpine/socat TCP-LISTEN:31007,fork,reuseaddr TCP:gateway1:30007
```

Check both directions:

```bash
nc -vz 100.75.15.108 31007     # from the box
nc -vz 100.66.60.127 31008     # from SCM4
```

## 4. Exchange bridge peer cards

Each side’s bridge needs a client config pinned to the **peer gateway**:

| Side | Peer | Gateway address in peer config |
|---|---|---|
| SCM4 servicenode1 | `box-0kn` | `tcp://100.66.60.127:31008` |
| Box mix-servicenode | `scm4-0kn` | `tcp://100.75.15.108:31007` |

Files land in `config/mixnet99/bridge/peers/`:
`<netid>.toml` (net_id + config path) and `<netid>-client.toml` (the peer’s
client config with the gateway address rewritten).

Restart the servicenode **at an epoch boundary** (or restart just the plugin via
the management socket). A mid-epoch restart causes ~2 epochs of `MAC mismatch`.

## 5. Dashboards + poll runner

```bash
# dashboard (host network)
docker run -d --name zknode-dashboard --restart unless-stopped --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e DASHBOARD_AUTH=optional zknode-dashboard

# keep DM history warm (45 s, non-blocking)
docker run -d --name zkchat-poll-runner --restart unless-stopped --network host \
  alpine sh -c 'while true; do wget -qO- --timeout=60 http://127.0.0.1:8080/api/chat/poll >/dev/null 2>&1; sleep 45; done'
```

Use `DASHBOARD_TOKEN=<secret>` instead of `optional` for token auth.

## 6. ZeroAI (local model)

On the node with Ollama:

```bash
ollama pull gemma4:latest
# dashboard env:
OLLAMA_MODEL=gemma4:latest
```

To let the other island use it over the tailnet (private, no cloud):

```bash
# expose Ollama to the tailnet only
docker run -d --name ollama-proxy --restart unless-stopped --network host \
  alpine/socat TCP-LISTEN:11434,bind=<tailnet-ip>,fork,reuseaddr TCP:127.0.0.1:11434

# on the other node's dashboard:
OLLAMA_HOST=http://<tailnet-ip>:11434
OLLAMA_MODEL=gemma4:latest
```

Use in any zkchat group: `/ai <question>`.

## 7. Verify

```bash
curl -s http://127.0.0.1:8080/api/health        # status: healthy
curl -s http://127.0.0.1:8080/api/llm/status    # ollama ok, model listed

# DM round-trip
docker exec zkchat /usr/local/bin/zkchat send /etc/zkchat/thinclient.toml <own-id-hex> "test"
docker exec zkchat /usr/local/bin/zkchat poll /etc/zkchat/thinclient.toml

# cross-island relay (operator mode; the relay completes even if the reply times out)
mesh-bridge -send -c <thinclient.toml> -net-id <peer-netid> -to <peer-id-hex> -msg "hello"
```

Expect **20–40 s** mixnet latency; the bridge path can take ~30 s per hop.

## 8. Backups / restore points

```bash
# snapshots (configs + keys + dashboards + binaries + manifest + checksums)
/mnt/autonomi/backups/scm4-bridge-live-*     # SCM4
~/backups/box-bridge-live-*                  # box
```

Git tags in each repo: `bridge-live-2026-10-21`, `zeroai-live-2026-10-21`.

---

### Common gotchas

- **Epochs are law:** restart authorities/servicenodes at the epoch boundary.
  Changing a servicenode identity requires restarting the authorities so they
  reload the pinned public key.
- **Never advertise `0.0.0.0`** in the `[Server] Addresses` field on a bridge
  network; peers will dial themselves.
- **Image tags lie:** on the x86_64 box the `…:arm64` tag no longer runs. Keep
  `IMAGE_MIXNET=zeros/mixnet-node:amd64-fleet*` in `.env`.
- **Group/dashboard polls** can take ~30 s; keep chat handlers async so the UI
  stays responsive.

---

## Dashboard variants (important)

The repo ships two dashboard backends:

| File | Mode | Use for |
|---|---|---|
| `zknode-dashboard/server/index.js` | upstream (VPS-aware) | VPS mixnet deployments |
| `zknode-dashboard/server/index.local.js` | standalone islands | local `mixnet99` (this guide) |

`index.local.js` uses the local container names (`auth1`, `mix1..6`,
`gateway1`, `servicenode1`, `mix-servicenode`), reads chat groups from the
local chatd, implements async chat commands (no UI stalls), fixes the mix-count
display, and enables the **ZeroAI** persona.

To deploy local mode:

```bash
cd zknode-dashboard
cp server/index.local.js server/index.js
docker build -t zknode-dashboard .
```

Keep both files in sync when adding features. Upstream `main` may be ahead on
VPS-dashboard features; do not replace it wholesale with the local variant.

---

## SCM4 (arm64) local mode

Use the SCM4 variant of the local dashboard (container names `auth1`,
`mix1..6`, `gateway1`, `servicenode1`):

```bash
cd zknode-dashboard
cp server/index.local-scm4.js server/index.js
docker build -t zknode-dashboard .

docker rm -f zknode-dashboard
docker run -d --name zknode-dashboard --restart unless-stopped --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e DASHBOARD_AUTH=optional \
  -e OLLAMA_HOST=http://<box-tailnet-ip>:11434 \
  -e OLLAMA_MODEL=gemma4:latest \
  zknode-dashboard
```

Groups are read locally by `chat-groups.sh` (auto-detects `mix-servicenode` or
`servicenode1`, or set `ZKCHAT_SERVICENODE`).

## walletshield RPC (MetaMask)

`walletshield` is loopback-only (`127.0.0.1:9200`). Expose it per interface
with socat if a wallet must reach it:

```bash
# tailnet
docker run -d --name ws-rpc-tailnet --restart unless-stopped --network host \
  alpine/socat TCP-LISTEN:9200,bind=<tailnet-ip>,fork,reuseaddr TCP:127.0.0.1:9200
# LAN (off-tailscale)
docker run -d --name ws-rpc-lan --restart unless-stopped --network host \
  alpine/socat TCP-LISTEN:9200,bind=<lan-ip>,fork,reuseaddr TCP:127.0.0.1:9200
```

MetaMask fields:
- RPC URL: `http://<node-ip>:9200/ethereum` (JSON-RPC POST, note the `/ethereum` path)
- Chain ID: `1` (upstream is Ethereum mainnet; `eth_chainId` = `0x1`)
- Symbol: `ETH`

Notes: calls take ~20-95 s through the mixnet, so wallets may time out; CORS
preflight is not supported (fine for the MetaMask extension, not for browser
dApps). Chain ID 1 is built into MetaMask — add this as an RPC URL under
Ethereum Mainnet, or point `-upstream` at another chain for a separate network.
