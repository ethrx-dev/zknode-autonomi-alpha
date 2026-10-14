# Local Gateway Topology — LAN Gateway Appliances + Tailscale Interconnect

> **Status:** sketch v0. Companion to `docs/ARCHITECTURE_OPTIONS.md` (adds
> **Option 5**) and `docs/BRIDGE_RELAY_DESIGN.md` (answers its §8.4: a single
> bridge host can live on the appliance).

## 1. Concept

Put the mixnet's **entry point on a small always-on appliance** in the local
network, instead of (a) inside each SCM4 or (b) on the remote VPS. Clients
(SCM4s, build box, laptops) dial their **site's local gateway**; the
control-plane between sites rides **Tailscale**; a site may additionally
publish its gateway **publicly** on the WAN (only port 30007) so external
zkchat guests can join.

Three exposure surfaces, deliberately separated:

| Surface | Who dials it | Carries | Ports |
|---------|--------------|---------|-------|
| LAN | Nodes on the same network | client ↔ gateway traffic (30007) | private |
| **Tailscale** | Sites' gateways, mix/servicenode peers, remote daemon owners (e.g. `dmax` admin) | gateway↔mix/servicenode hops, dirauth descriptor/consensus traffic (30001–30005 range) | private |
| Public WAN | External zkchat guests (optional per site) | gateway 30007 only | public |

## 2. The key structural fact

A gateway cannot exist alone — it belongs to a **PKI domain**. Two valid forms:

### Form 1 — Whole domain on the appliance ("gateway appliance", recommended)
The appliance runs the **full 13-container local topology** (same compose as a
SCM4 Option 1: 3 dirauth + 3 mix + gateway + servicenode + 5 replicas),
dashboard/proxy/walletshield/zkchat on the SCM4s behind it as thin clients.
One appliance per *sovereign group*; dirauth ports stay internal to the
appliance. SCM4s become **Option 2-profile clients** with a LAN/tailnet
address instead of the VPS:

```
config/mixnet/client/client-lan.toml   # = client-vps.toml with
  ...  Addresses = ["tcp://<site-gateway>:30007"]
```

Only the pinned-gateway address and image tags change; everything else
(health logic, dashboard VPS-aware build re-pointed at the appliance) is the
already-validated VPS-client pattern.

### Form 2 — Extra gateway in an existing shared domain ("distributed domain")
All sites' gateways join **one shared PKI** (dirauth quorum lives on any one
stable box — VPS or one trusted site). Each site runs only its gateway
(+ optionally local mixes). This makes the mixnet a truly **federated** mesh:
clients at site A dial gw-A, packets route over the shared topology, and the
exit (servicenode) can sit anywhere.

Prereq (ops): every participating node must reach the **dirauth quorum ports**
for descriptor/consensus traffic — today only gateway `:30007` is published on
the VPS. Over Tailscale this needs no public firewall change at all: bring the
dirauths onto the tailnet (bind their listen addresses to the tailnet IP or
add subnet-routing on the VPS side) and keep UFW closed on WAN.

## 3. Diagram (Form 1 per site, sites joined over Tailscale)

```
                     TAILNET (private control plane)
        ┌──────────────────┬──────────────────┬──────────────────┐
        ▼                  ▼                  ▼                  ▼
 SITE A               SITE B (SCM4 box)   SITE C             VPS 185.92.181.101
 ┌───────────────┐    ┌───────────────┐   ┌───────────────┐  ┌───────────────────┐
 │ gateway       │    │ gateway       │   │ gateway       │  │ existing full     │
 │ appliance     │    │ appliance     │   │ appliance     │  │ topology (as-is)  │
 │ (Pi 5 /       │    │ (Pi 4)        │   │ (mini-PC)     │  │ 185.92.181.101:7  │
 │  mini-PC)     │    │               │   │               │  │ :30007 PUBLIC     │
 │ 3 da + 3 mix  │    │ 3 da + 3 mix  │   │ 3 da + 3 mix  │  └───────────────────┘
 │ gw+svc+5 repl │    │               │   │               │
 └──────┬────────┘    └──────┬────────┘   └──────┬────────┘
        │ LAN                │ LAN               │ LAN
   ┌────▼─────┐         ┌────▼─────┐        ┌────▼─────┐
   │ SCM4(s)  │         │ SCM4(s)  │        │ build/sm │
   │ zkchat*  │         │ zkchat   │        │ zkchat   │
   └──────────┘         └──────────┘        └──────────┘
        ▲                   ▲                    ▲
        └── client traffic: LAN or tailnet (client-vps-AP-of-C-envelope-style)
```

Note: with **Form 2**, cross-site routing means site A's client can reach site
C's *service* node through the shared topology — that's what makes "SCM4s talk
across sites" come *for free*, with neither bridge plugins nor extra hops. The
message body still has link/onion encryption in transit; see §5 for the E2E
prerequisite.

## 4. Hardware matrix

| Device | Arch / RAM | Runs what | Verdict |
|--------|-----------|-----------|---------|
| **Raspberry Pi 5 (4–8 GB, SSD)** | aarch64 / fast disk | **Form 1 whole domain** (compose mem limits sum ≈ 3.1 GB) — comfortable; also Form 2 gw | **Recommended appliance.** Uses the *same* `zeros/mixnet-node:arm64` images as the SCM4 — zero rebuild. Run from USB-SSD, not SD card, for write reliability. |
| Raspberry Pi 4 (2–4 GB) | aarch64 | Form 2 gw-only (256 MB lim), or trimmed Form 1 (2 mixes is below 3-hop requirement — keep 3) | Fine for Form 2; tight for Form 1 |
| Raspberry Pi 3B+ (1 GB) | aarch64 | Form 2 gw-only, devnet only | Marginal; Pi 4 preferred at same price today |
| **GL.iNet MT6000 "Flint 2"** | aarch64 (MT7986 quad A53 2.0 GHz) / 2 GB | One **gateway container** (mem limit 256 MB) via embedded Dockerd, or Form 2 gw | Possible but cramped; OpenWrt userspace makes ops fragile. **Best used as plumbing** |
| **GL.iNet MT3000 "Beryl AX"** | aarch64 (MT7981 dual A53 1.3 GHz) / 1 GB | Too weak for containers with headroom | **Plumbing role only** (see below) |
| x86 mini-PC (N100 etc.) | amd64 | Whole Form 1 domain, most headroom | If buying, consider `:amd64` image existance on this path |

**GL.iNet plumbing roles** (the honest use case for the nano routers):
1. **Tailscale subnet router** — MT3000/MT6000 run `tailscaled` (GL firmware has
   built-in Tailscale integration on recent releases, else `opkg install
   tailscale`) with `--advertise-routes` to expose the whole site LAN to the
   tailnet. Remote SCM4s then reach the site's gateway/LAN without per-node
   tailscale installs.
2. **Public WAN sidecar** — NAT port-forward of `WAN:30007 → appliance:30007`,
   with UFW on the appliance itself still closed except to tailnet/LAN sources;
   the router IS the public exposure device (keeps the appliance off WAN).
3. **Guest Wi-Fi VLAN** for external guests who use `http://<public-entry>:…`
   invite/dashboard URLs via the site's WAN IP.

A nano router **should not** be the mixnet node host: RAM and OpenWrt's
container-in-OpenWrt discipline make it the weakest link on the network. Use
the Pi/mini-PC as the appliance and the router as its network front.

## 5. E2E content note (carried over)

Content is still stored plaintext on chatd (`cmd/chatd/main.go`, plain CBOR,
no E2E) whatever the topology. This topology doesn't change that — it makes
 hops/entrypoints better distributed. Same recommendation as the bridge doc:
**Phase 2c (zkchat identity-file migration → content keys) is the uplift that
makes any of these meaningful.**

## 6. Concretely: what "running Form 1" looks like (recipe)

1. Provision the appliance (Pi 5 + Debian 12 arm64 lite or Raspberry Pi OS
   arm64, Docker, USB SSD; hostname `zknode-mixgw-a` convention for the fleet).
2. `git clone` the repo, `.env` with `IMAGE_*=:arm64` (same as SCM4).
3. Regenerate topology configs: `scripts/gen-mixnet99.sh` (same generator as
   the SCM4 PoC), 13-container stack; endpoints per current configs.
4. **Gateway exposure**: bind the gateway to the LAN + tailnet addresses
   (`VPS_GATEWAY_BIND`-equivalent, call it `LOCAL_GATEWAY_BIND` — set it to the
   station's LAN IP so it doesn't bind `0.0.0.0`, mirroring the VPS guidance).
5. **Tailscale** join (`tailscale up --auth-key ... --hostname mixgw-a`,
   naming scheme `mixgw-<site>`).
6. Client-side (each SCM4): stop the local `mix-*` core (Option 1) and run
   kpclient-vps-style container pointed at the local gateway
   (Option 2 profile, or already-documented profile) — a `.env`-level change
   of the container's `client-vps.toml` → `client-lan.toml` address.
7. Public entry (optional per site): router forwards only **30007** into the
   appliance; invites for external guests then use the WAN IP (or DynDNS)
   pinned gateway address in their `*client*` config.
8. Verify: `tailscale ping mixgw-a`, `/api/health` (dashboard pointing at the
   appliance), `+echo` 5/5 cross-shell, epoch advancing, `eth_chainId` 0x1.

Estimated effort: **2–4 hours** of ops (reusing validated VPS-client and
gen-mixnet99 tooling), plus inherent Pi provisioning if hardware is new.

## 7. Risks / notes

- **Single-domain APOF**: in Form 1, each sovereign group's appliance is the
  availability gate for its clients' PKI docs (directories cache the document
  for a couple of epochs, so brief outages are tolerable; multi-epoch outages
  not). Form 2 with a shared dirauth quorum moves that risk to one shared
  quorum — acceptable trade for true federation.
- **Restart discipline** on the appliance's mix/watchnodes: same as today —
  epoch boundaries only (dirauth+mixes); gateway/client/proxy anytime.
- **Public exposure** is a deliberate trade (same as the VPS): the gateway IP
  becomes known. Keep UFW closed except 30007.
- **Bridge compatibility**: the appliance can also host the sovereign-island
  `mesh-bridge` (answers bridge doc §8.4) — this is a single box running all
  mixnet plumbing plus any future bridge plugin.
