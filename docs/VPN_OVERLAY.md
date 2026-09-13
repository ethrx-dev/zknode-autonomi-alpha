# VPN Overlay — Bootable P4P Wiki Mesh Node

> First-boot WireGuard provisioner for the portable USB / live-image node.
> No key material is ever baked into the image.

## Design

| Decision | Choice | Why |
|----------|--------|-----|
| Base transport | WireGuard (kernel module first, wireguard-go fallback) | Self-sovereign, zero third-party, mature, fast |
| Hub topology | Hub-and-spoke 10.66.0.0/24 | Simple NAT traversal to a single authenticated endpoint |
| Key lifetime | Generated on first boot, persisted on PERSIST partition | Re-flash safe; no secret in the image |
| Roaming overlay | Optional Tailscale ephemeral authkey | For mobile / travel nodes that need NAT piercing |
| Provisioning | `vpn-provision.sh` (idempotent, runs every boot) | Safe on reboots, live ISO, or persistent install |

## Addressing

```
10.66.0.0/24   wireguard mesh
  10.66.0.1    hub (operator VPS or home lab)
  10.66.0.2+   spoke nodes (each gets .x on first boot; peer [Peer] block
               records it; hub registers as AllowedIPs on the spoke)
```

## Files

| Path (on image) | Purpose |
|------------------|---------|
| `/usr/local/sbin/vpn-provision.sh` | First-boot provisioner (idempotent, kernel + wg-go fallback) |
| `/etc/systemd/system/vpn-provision.service` | systemd unit run at boot |
| `/etc/zknode/vpn/peers.conf` | Operator-provided hub [Peer] block (pre-seeded or dropped on PERSIST) |
| `<PERSIST>/vpn/privatekey` | Generated WireGuard private key (mode 0600) |
| `<PERSIST>/vpn/publickey` | Generated WireGuard public key |
| `<PERSIST>/vpn/peers.conf` | Runtime peer config (copied from seed or operator drop) |

## How it works

```
first boot
  ├─ modprobe wireguard  ── kernel module available
  │     wg-quick up wg0  (resolves 10.66.0.x, routes AllowedIPs)
  └─ modprobe fails (Wolfi / no module)
        wireguard-go wg0
        wg setconf wg0 /etc/wireguard/wg0.conf
        ip addr add dev wg0 10.66.0.2/24
        ip link set wg0 up
```

`wg0.conf` is written from:
- `[Interface]` — `PrivateKey` (read from persisted key) + `Address = 10.66.0.2/24`
- `[Peer]` — copied verbatim from `<PERSIST>/vpn/peers.conf`

The node prints its public key to the console on first boot:
```
[vpn] node public key: zRzV3sESGSTwBpMpcuLCx4/eWLrcyzWxE4+3e0kUr2g=
```
Register this key on the hub as `AllowedIPs 10.66.0.2/32` (or the
operator's chosen allocation). Persistent keepalive = 25 s.

## Operator hub setup (quick start)

On the hub VPS (e.g. zknet-vps `217.60.7.200`):

```bash
# install wireguard-tools
apt-get update && apt-get install -y wireguard-tools

# generate hub keypair
wg genkey > /etc/wireguard/hub.key
chmod 600 /etc/wireguard/hub.key
wg pubkey < /etc/wireguard/hub.key > /etc/wireguard/hub.pub

# write hub interface
cat > /etc/wireguard/hub0.conf <<EOF
[Interface]
Address = 10.66.0.1/24
PrivateKey = $(cat /etc/wireguard/hub.key)
ListenPort = 51820
EOF
chmod 600 /etc/wireguard/hub0.conf

# bring up
ip link add dev hub0 type wireguard
wg setconf hub0 /etc/wireguard/hub0.conf
ip addr add dev hub0 10.66.0.1/24
ip link set hub0 up

# open UDP in firewall
ufw allow 51820/udp

# register each spoke (add as nodes report their public keys)
wg set hub0 peer <SPOKE_PUBKEY> allowed-ips 10.66.0.2/32
```

## First-boot walkthrough

1. Flash image to USB, mount PERSIST, optionally pre-seed:
   `<PERSIST>/vpn/peers.conf` with the hub block above.
2. Boot. Provisioner runs automatically.
3. Console output shows:
   ```
   [vpn] first boot: generating fresh WireGuard keypair
   [vpn] node public key: <your-pubkey>  (register this on the hub)
   [vpn] kernel wireguard: wg-quick up wg0
   [vpn] wg0 up (kernel)
   ```
4. Register the spoke on the hub (copy the public key, run `wg set hub0 peer <key> allowed-ips 10.66.0.X/32`).
5. Tunnel is live. Hub can reach the node at 10.66.0.X; node routes to 10.66.0.0/24 via wg0.

## Running locally on the wiki mesh node (this machine)

The provisioner has been tested end-to-end on `blaqbox` (the local P4P wiki
mesh node):

1. Keys persisted to `/home/zero-tech/zknode-autonomi/data/vpn/`
2. A hub container brought up on the docker bridge (10.66.0.1)
3. `wg0` brought up in the host netns via `--network host --cap-add NET_ADMIN`
4. Hub registered the node's key; handshake established; ping verified at
   ~0.4 ms RTT — zero packet loss.

Full isolated test (no host impact):
```bash
bash tests/test-vpn-overlay.sh   # hub container ↔ provisioned node container
```

## Optional: Tailscale overlay

For roaming / travel nodes where UDP is blocked, drop a Tailscale ephemeral
authkey on PERSIST:

```bash
cat > <PERSIST>/vpn/tailscale-authkey <<EOF
tskey-auth-...
EOF
# On first boot, provisioner will install tailscale and join your tailnet
# as an ephemeral node with 10.66.x.x as its address via rerouteip.
```

## Test matrix

| Test | What | Requires |
|------|------|----------|
| `bash scripts/build-usb-image.sh --dry-run` | Build stub image with VPN overlay embedded | no root |
| `bash tests/test-vpn-overlay.sh` | End-to-end hub↔node tunnel (isolated docker) | docker only |
| Live host test (this machine) | Real wg0 in host netns, ping 10.66.0.1 | docker + NET_ADMIN |
| `bash tests/run-all.sh` | Full matrix including `test-vpn-overlay.sh` | docker |
