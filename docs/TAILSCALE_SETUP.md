# Tailscale Setup for ZKNetwork SCM4 Nodes

Configuration for connecting zknode nodes over a private, encrypted Tailscale
mesh so nodes can reach each other and share zkchat groups without exposing
services to the public internet.

---

## 0. Quick start (for the node being onboarded)

You need an **auth key** from the tailnet admin (see §3.2). Then:

```bash
# 1. install
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled

# 2. join the ZK tailnet (replace <id> and the key)
sudo tailscale up \
  --auth-key "tskey-auth-<YOUR_KEY>" \
  --hostname "zknode-<id>" \
  --accept-dns

# 3. verify
tailscale status
tailscale ping zknode-<id-1>   # an existing node
```

Once joined you can reach the existing node's dashboard at
`http://zknode-<JSNode-NAME>` shared invite links. Tailnet:
`<tailnet>.ts.net` (MagicDNS enabled).

---

## 1. Why Tailscale

- Private, encrypted mesh between authorized nodes: traffic rides
  WireGuard-protocol tunnels (ChaCha20-Poly1305 / Noise) under the hood, but
  it is a Tailscale-userspace implementation, not the kernel `wg0` driver —
  coordinated by Tailscale's control plane with Disco UDP discovery, NAT
  hole-punching, and DERP relays as fallback. Cross-compat with a plain
  `wg` peer is NOT possible; only key-issued nodes join.
- No router port-forwarding; works behind NAT/CGNAT.
- Non-interactive node onboarding via reusable auth keys.
- Lets remote peers reach the zkchat dashboard (`http://<tailscale-ip>:8080`) so
  invite links generated there are reachable outside the local LAN.

> The zkchat dashboard builds invite links from the request `Host` header
> (`zknode-dashboard/server/index.js`, `createInviteToken` /
> `/api/chat/groups/invite-token`). Always generate invites while accessing the
> dashboard through the address peers will use (Tailscale IP or MagicDNS name),
> otherwise the link will contain an an unreachable LAN IP.

---

## 2. Global Configuration (apply to every node)

| Setting            | Value                                   |
|--------------------|-----------------------------------------|
| Tailnet            | One shared tailnet for all ZK nodes     |
| Hostname scheme    | `zknode-<id>` (`zknode-01`, `zknode-02`) |
| Node auth          | Reusable auth key (tagged)              |
| Default port       | `8080` for zkchat dashboard             |
| MagicDNS           | Enabled — reach peers by node name    |

Recommended ACL tags (Tailscale admin console):

- Tag nodes on join with `tag:zknode` so ACLs can target them as a group.
- Define an auth key that only issues `tag:zknode` devices.

---

## 3. Host Node Setup (the SCM4 being provisioned)

### 3.1 Install

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
```

### 3.2 Onboard with an auth key (non-interactive)

Generate a reusable, tagged auth key in the Tailscale admin console
(**Settings → Keys → Generate auth key**, choose *Reusable* and tag `tag:zknode`),
then:

```bash
sudo tailscale up \
  --auth-key "tskey-auth-<YOUR_KEY>" \
  --hostname "zknode-<id>" \
  --accept-dns
```

### 3.3 One-off / interactive alternative

```bash
sudo tailscale up --hostname "zknode-<id>"
# then open the printed https://login.tailscale.com/a/<code> URL
```

### 3.4 Verify

```bash
tailscale status
tailscale ip -4          # e.g. 100.x.y.z  -> peers use this
tailscale status --json | grep -i dnsname
```

The node is reachable at `http://zknode-<id>:8080` (MagicDNS) or
`http://100.x.y.z:8080`.

---

## 4. Connecting Another Node

On each additional SCM4:

1. Install Tailscale (section 3.1).
2. Onboard with the same tailnet's auth key and a unique `zknode-<id>` hostname:
   ```bash
   sudo tailscale up --auth-key "tskey-auth-<YOUR_KEY>" --hostname "zknode-<id>" --accept-dns
   ```
3. Confirm both nodes see each other:
   ```bash
   tailscale status
   tailscale ping zknode-<existing-id>
   ```

All nodes on the tailnet can now reach each other's advertised services
(including the zkchat dashboard on port `8080`).

---

## 5. Sharing a zkchat Group Across Nodes

### 5.1 Required: expose the dashboard on the tailnet

The dashboard (`zknode-dashboard`) **binds `127.0.0.1` only unless a
`DASHBOARD_TOKEN` is set** (`zknode-dashboard/server/index.js:32-33`, and the
compose entry `${DASHBOARD_TOKEN:-}` / `DASHBOARD_BIND`). A loopback-only
dashboard cannot be reached over Tailscale. Set both in `.env`:

```bash
# .env  (never commit real values)
DASHBOARD_TOKEN=$(openssl rand -hex 24)
DASHBOARD_BIND=<this-node-tailscale-ip>   # e.g. 100.x.y.z
```

Prefer binding to the node's **Tailscale IP** (`100.x.y.z`) rather than
`0.0.0.0`, so the dashboard is reachable only over the private tailnet and
never on the LAN/public interface. Then recreate the container:

```bash
docker compose up -d zknode-dashboard
```

### 5.2 Generate and share the invite

1. Open the dashboard **via its Tailscale address** (with the token if set):
   ```
   http://zknode-<id>:8080/?token=<DASHBOARD_TOKEN>
   ```
2. Create the group and generate an invite link.
3. Share the link with peers on the tailnet. Because it was generated from the
   Tailscale address, the link host resolves for every tailnet member.
4. Peers open the link and join; chat then flows over the mixnet.

> The invite host is taken from the request `Host` header
> (`zknode-dashboard/server/index.js`, `createInviteToken`,
> `/api/chat/groups/invite-token`). If you generate the invite from
> a LAN address, the link is only usable from that LAN. Use the
> Tailscale hostname/IP (or another externally-reachable address) instead.

---

## 6. Optional: Exit Node / Subnet Router

Only if a node must route traffic for others (requires admin approval):

```bash
sudo tailscale up --advertise-exit-node
sudo tailscale up --advertise-routes=<LAN-subnet>
```

Approve the advertised node/route in the Tailscale admin console.

---

## 7. Global Node Provisioning (fleet)

For a fleet of SCM4 nodes, wrap onboarding in a provisioning script. Use one
reusable, tagged auth key across the fleet and a unique hostname per node:

```bash
#!/usr/bin/env bash
set -euo pipefail
NODE_ID="${1:?usage: tailscale-provision.sh <node-id>}"
: "${TS_AUTHKEY:?export TS_AUTHKEY=tskey-auth-...}"

curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
tailscale up \
  --auth-key "$TS_AUTHKEY" \
  --hostname "zknode-${NODE_ID}" \
  --accept-dns
tailscale status
```

Keep `TS_AUTHKEY` out of source control (env var / secret store / systemd
credential). Rotate the key periodically.

---

## 8. Security Notes

- Treat the tailnet as your private network; only admit trusted nodes.
- Use reusable auth keys scoped with `tag:zknode`; set an expiry and rotate.
- Never commit auth keys. Store them in a secret manager.
- Review Tailscale ACLs regularly (default allows all tailnet members).
- Consider [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh) for
  secure node administration.
