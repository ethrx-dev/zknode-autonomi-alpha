# Bridge Relay Design — Cross-Mixnet Messaging between Sovereign ZKnodes

> **Status:** sketch v1 — message path recon **complete** (§3.5); flow and
> phases revised accordingly. Design only, no code yet.
> Companion to `docs/ARCHITECTURE_OPTIONS.md`. `§9` positions this against
> shared-domain options (A/B).

## 1. Problem

Each zknode can run its own **sovereign Katzenpost domain** (local topology —
Option 1). Katzenpost has no mixnet-to-mixnet routing: a client is bound to one
PKI consensus, and hop descriptors from domain A mean nothing to domain B. Two
sovereign islands therefore cannot exchange zkchat messages, and we want them
to — without forcing every node into one shared domain.

## 2. Constraints we can build on (verified in this repo)

- The servicenode launches **external CBOR plugins** as separate processes:
  `[[ServiceNode.CBORPluginKaetzchen]]` blocks declare `Capability` /
  `Endpoint` / `Command`, exchanged over a Unix socket
  (`katzenpost/server/cborplugin/{server.go,client.go,socket.go}`). Existing
  capabilities: `courier` (currently `Disable = true`), `proxy`
  (http-proxy-server), `chat` (chatd).
- A **pinned-gateway client config** (`config/mixnet/client/client-vps.toml`,
  `thinclient.toml`) lets a Go process act as a client of a *remote* domain:
  the PKI doc is fetched **through the gateway** (authority addresses in the
  config are Docker-internal and unused for remote clients) — proven pattern,
  validated against the VPS (`+echo` 5/5, `+testdest` 3/3).
- The mixnet Go sources live in-tree (`katzenpost/`), so a bridge can embed
  the mixnet client library rather than shell out to `kpclientd`.
- `SphinxGeometry`/`PigeonholeGeometry` come from one shared genconfig, so the
  two domains in scope are wire-compatible today.

## 3. Architecture (sketch)

```
 sovereign domain A                     sovereign domain B
 (node A local topology)                (node B local topology)
 ┌──────────────────────────┐           ┌──────────────────────────┐
 │ zkchat ─► kpclientd ─►   │           │  kpclientd ◄─ zkchat     │
 │            gateway1(A)   │           │   gateway1(B)            │
 │                ▲         │           │     ▲                    │
 │         mixnet hops      │           │   mixnet hops            │
 │                │         │           │     │                    │
 │.servicenode A (+chat)    │           │ servicenode B (+chat)    │
 │         │                │           │   ▲                      │
 │  ┌──────┴────────────┐   │ opaque Op │   │                      │
 │  │ mesh-bridge A     │───┼──envelope─┼──►│ (bridge B speaks     │
 │  │ [client session → │   │ (speak    │   │  the *chat* protocol │
 │  │  B: tcp://B-gw)   │   │  +chat)   │   │  as a client of B)   │
 │  └───────────────────┘   │           │                          │
 └──────────────────────────┘           └──────────────────────────┘
```

**Components per node** (each node runs a bridge for its *own* outbound path):

- `mesh-bridge` (new cmd in `katzenpost/cmd/mesh-bridge`, Go):
  1. **A-side / local role (the sending node):** a CBORPluginKaetzchen on the
     node's own servicenode (`Capability = "meshbridge"`,
     `Endpoint = "+meshbridge"`). zkchat addresses cross-domain DMs *here*
     (not to `+chat`) — this local capability is what makes "send to netID:B +
     recipient identity" expressible at all; without it a cross-domain send
     would be indistinguishable from a local peer who never polls.
  2. **B-side / remote role:** an *ordinary client* of the remote domain — one
     embedded mixnet client session per remote peer, built from a pinned
     gateway TOML (same shape as `client-vps.toml`). It receives the relay
     envelope on its local `+meshbridge`, then speaks the **chat protocol**
     (`ChatRequest` CBOR) as a client, posting into the remote domain's `+chat`
     capability addressed to the remote-recipient identity.
  - **Inbound, receiver side (DM v1):** nothing new — B needs no extra
    capability; the bridge-from-A *is* a client of B's existing `+chat`. B only
    needs its own bridge process when B wants to *send* cross-domain.
- **Static address book** (v1): `config/mixnet/bridge/bridge.toml` mapping
  `{netID → gateway addr, pinned gateway identity/link keys, remote chatdest,
  recipient identities [allow-list]}`. The bridge holds no secrets of either
  domain; it only must be able to (a) dial B's gateway and (b) know which
  recipient identities are authorized.
- **Dashboard health:** `/api/mixnet` gains `bridge_sessions` (per remote
  peer: pinned PKI doc present + gateway session live).

## 3.5 Message path (recon results — §8.1 resolved)

Verified by reading `katzenpost/cmd/zkchat/main.go` and
`katzenpost/cmd/chatd/main.go`:

| Fact | Detail |
|------|--------|
| Transport used | zkchat is a **thin client** that resolves `GetService("chat")` → destHash, and sends with `BlockingSendMessage(payload, destHash, queue)`. Direct request/response to the **`+chat` capability (chatd)** — **not** the courier pigeonhole spool. |
| Protocol | Plain CBOR `ChatRequest{Op, UserID, Recipient, Content, MsgType, GroupID, GroupName, Members}` → `ChatResponse{Success, Error, Messages, Addr, GroupID, Groups}` (no crypto fields). |
| Ops | `send` (DM), `poll`, `ai`, `group_create`, `group_send`, `group_poll`, `group_invite`, `group_leave`, `group_list`. |
| Recipient addressing | `UserID`/`Recipient` = a **random 16-byte identity** (`loadOrCreateIdentity` — `rand.Read(16)`, persisted at `<cfg>/identity`, mode 0600). **Not a public key** — there is today **no key pair behind the identity** and therefore **no end-to-end content encryption**: `Content` is a plaintext `string` stored as plain CBOR on the hosting chatd (file mode 0600 only). Mixnet hops provide link/onion encryption **in transit only**. |
| Server storage | Filesystem on the chatd host: `storeDir/user_<hex>/*.msg`, `group_<gid>/meta.json` (+ messages), `user_<hex>/groups.json`. **No DB.** Optional `useAnt` mode stores blobs via the `ant` CLI and returns an Autonomi `addr` (local file removed) — remember for the receive side. |
| Group membership | `group_<gid>/meta.json` with `Owner`, `Members [][]byte`; `group_poll` reads `user_<hex>/groups.json`. Groups live **on the domain hosting their chatd** — a foreign-domain identity cannot poll them (poll is a local `GetService("chat")` call). |

Implications for the bridge, in priority order:

1. **DMs are the natural v1**: the inbound side needs *zero new capability* —
   the bridge presents a valid-looking `ChatRequest{Op:"send",
   Recipient:<B-identity>, Content:<base64>}` over the mixnet to B's existing
   `+chat`. Both directions require one bridge per sending node.
2. **Cross-domain groups are NOT a straightforward insert**: group membership
   is anchored to the *originating* domain's chatd, and a foreign-domain member
   can't poll it. Cross-domain groups require a **mirroring** design — see
   Phase 2b — and are deliberately not the v1 target.
3. **E2E content encryption is a bridge prerequisite** (today the content is
   stored plaintext on chatd and, with the bridge, would additionally be
   visible to both bridge processes). Enabling it requires a zkchat identity
   upgrade: `identity` (16 random bytes) must become a **private key** whose
   X25519/Ed25519 public half is the 16-byte recipient address. That is a
   zkchat migration, independent of but *required by* the bridge.

## 4. Message flow (revised; DM cross-domain)

A→B, B sovereign, both bridges running:

1. A's zkchat (with E2E phase) seals the message to B's recipient identity key
   and — because the recipient maps to `netID:B` in the local bridge address
   book — sends `ChatRequest{Op:"meshbridge_send", netID:"B",
   Recipient: B-identity, Content: base64(ct)}` to **A's local `+meshbridge`**
   capability (a normal mixnet round: thin client → A's hops → A's
   servicenode; opaque to A's gateway beyond "client sent to +meshbridge").
2. mesh-bridge A (the plugin process) validates the envelope, then uses its
   **B-side client session** (pinned to B's `gateway1:30007`) to post
   `ChatRequest{Op:"send", UserID: bridgeID-A, Recipient: B-identity,
   Content: base64(ct), MsgType:"mesh-e2e"}` into domain B's existing `+chat`
   — plain client traffic of domain B, no B-side bridge involvement.
3. B's chatd stores the sealed blob under `user_<B-identity>/*.msg` — an
   ordinary local message from B's perspective.
4. B's zkchat polls normally (its own domain, own identity), decrypts with
   its identity key, displays sender "via bridge A (netID:B)".

Reply path is symmetric: B's zkchat → B's `+meshbridge` → bridge B's A-side
client session → A's `+chat` → A's user poll.

Notes:
- The bridge is **outside both domains' consensus**; it can be restarted
  epoch-independent (unlike mix nodes).
- Because the recipient address is a raw identifier chatd happily stores
  anything for, the bridge injects without needing B-side authentication —
  see the threat table for why that must tighten.
- **Peer count is O(n²) for fully-connected sovereign islands**: each node
  runs one bridge process per peer (or one process with N peer sessions).
  For the devnet's handful of islands this is fine; revisit at scale.

### 4.5 Peer onboarding — the DomainCard (recycles the invite machinery)

`bridge.toml` entries are not configured by a central authority; they arrive
out-of-band as a **DomainCard**, the cross-domain analog of the zkchat invite
the dashboard already produces (`groupId.inviterIdentity.ts.sig`):

```
DomainCard := {
  netID:        "zknode-<id>"            (self-chosen, stable)
  gateway:      { addr: "tcp://<gw-addr>:30007",
                  identity: PEM(ed25519),   # pinned gateway identity key
                  link:    PEM(mlkem768) }  # pinned gateway link key
  operators:    [ allow-listed recipient identities accepted inbound ]
  issued:       <epoch>,
  sig:          ed25519 by the issuing node's signing key
}
```

Exchange paths (all out-of-band, operator-run): the dashboard invite link
(Tailscale/HTTP), a QR/screen transfer, or git. On acceptance, the local
dashboard (new `/api/mixnet/domain-card`) writes the peer's card into
`bridge.toml` and the bridge opens its pinned session. This is what makes
*"each node has what it needs"* operational: **local PKI + local zkchat + one
bridge process + the peers' DomainCards — no VPS, no shared gateway, no
central registry.** Key rotation then becomes a re-issued DomainCard
(same flow as today's `client-vps.toml` rotation, but self-serviceable).

## 5. Threat model / trust

| Risk | Assessment / mitigation |
|------|--------------------------|
| Bridge is a **metadata nexus** (sees cross-domain sends on both sides) | Inherent; soften with batching, randomized delay, per-epoch decoys (Phase 3). Not eliminable. |
| **Content is not E2E today** — stored plaintext at chatd; with the bridge it would also transit both bridges in the clear | **Bridge prerequisite**: Phase 2c adds content encryption via a zkchat identity-file migration (private key, public half = 16-byte address). Without this, the bridge *widens* the plaintext exposure. |
| Recipient-address fabrication on the inbound (bridge) path | Any party facing the remote gateway could inject as a chat client. Hardening (Phase 3): signed envelopes (bridge signing key pinned in the remote `bridge.toml`) and allow-list of recipient identities. |
| Mix hops | Preserved within each domain (same 3-hop Sphinx, each domain's own PKI). Cross-domain pays one extra trust boundary at each bridge. |
| Key rotation on remote path | Same problem as `client-vps.toml` rotation: if B's gateway/identity keys rotate, bridge A's pinned config breaks until re-deployed. Operational. |
| Autonomi (`useAnt`) interaction | Inbound bridged messages must be forced to **local file** storage (or a per-bridge ant path) — the remote `Addr` would otherwise point someone else's fetch into Autonomi ambiguity. |

## 6. Implementation phases

- **Phase 0 — recon ✅ DONE:** message path verified (§3.5).
- **Phase 0b — spike (½–1 day):** confirm one embedded mixnet Go client can
  keep a pinned-gateway session into *another local topology* (not just the
  VPS), and carry a `BlockingSendMessage` to `+chat` — end-to-end B-receives.
- **Phase 1 — opaque DM relay (1–2 days Go):** `mesh-bridge` skeleton, static
  bridge.toml, B-side session; "~test" plaintext DM path bridge→B.
- **Phase 2a — zkchat outbound wiring (1–2 days):** zkchat gains a
  `send --via <netID>`-equivalent path: when a Recipient is in the bridge
  address book, route through mesh-bridge A (or: mesh-bridge itself exposes a
  local thin-client shim / management socket). **DMs only; both ends bridged.**
- **Phase 2c — E2E content (2–3 days, prerequisite for "private"):** zkchat
  identity-file migration → keypair; content `sealed(msg)`; MSG type
  `mesh-e2e`. Independent uplift that improves zkchat for same-domain too.
- **Phase 2b — cross-domain group mirroring (open-ended; optional):** bridges
  replicate `group_<gid>` objects across domains for foreign members
  (per-domain mirrored gid, per-member poll digests, membership reconciliation).
  Defer until DM federations are proven.
- **Phase 3 — hardening:** signed envelopes, allow-list enforcement, batching,
  decoys, rate limits, dashboard `bridge_sessions`, `upgrade-node.sh` —
  "Option 4: Sovereign + bridge" deployment profile.

## 7. Effort & risk

| Item | Estimate |
|------|----------|
| Design + recon (0) | done |
| 0b spike | ~½–1 day, low risk |
| Phase 1 opaque relay | 1–2 days |
| Phase 2a zkchat wiring | 1–2 days |
| Phase 2c E2E encryption | 2–3 days — *also lifts no-bridge zkchat* |
| Phase 2b group mirroring | open-ended; explicitly deferred |
| Phase 3 hardening | when needed |
| **Working two-node DM demo** | **~3–4 days focused work** |

Risk notes: (i) E2E migration touches zkchat's identity/file semantics — needs
the same review discipline as any crypto change; (ii) `GetService` behavior
with **multiple** servicenodes per domain is a known ambiguity — devnet uses
one servicenode per domain, which sidesteps it, but the doc must note it.

## 8. Open questions

1. ~~Does zkchat use courier spool or direct `+chat`?~~ **Resolved §3.5: direct
   `+chat` (chatd); courier capability is present but disabled here, and the
   interop concern is DM-vs-group anchoring, not spool mechanics.**
2. **Multi-servicenode `GetService` discovery** in a domain with >1 provider —
   does `GetService("chat")` pin the *same* servicenode consistently? Devnet is
   1-per-domain; must be resolved before any multi-node domain federation.
3. **Identity-file migration compatibility** — whether an existing SCM4
   `data/zkchat/identity` should be treated as a seed for a derived keypair or
   16-byte-original kept (czar: no preserve — regenerate and accept local
   island rebinding, per the Box owner).
4. **Deterministic per-domain chatd "which is mine"** — with `GetService` being
   PB-the-source-of-truth, bridging into *B* delivers to a deterministic
   `+chat` host only if B's topology stays single-servicenode.
5. **Single shared bridge host vs per-node bridges** — a single bridge host
   (e.g. the future **local gateway appliance**, `docs/LOCAL_GATEWAY_TOPOLOGY.md`
   Option 5) is simpler ops at the cost of that box observing all cross-domain
   patterns. Acceptable for devnet; revisit for federation.

## 9. Why keep this on the shelf — and why it may be *the most* self-sovereign option

The devnet path of least resistance today is **Option A** (VPS gateway; both
nodes clients) — but Option A concentrates trust in one external gateway. The
bridge converts that into **bilateral dependencies only**: each node depends on
nothing but its own PKI, its own zkchat, one bridge process, and the peers it
chose to accept. There is no third party that all nodes transit. The costs are
stated plainly — O(n²) bridge sessions, a metadata nexus at each bridge, and
out-of-band DomainCard exchange on rotation — and the devnet should still reach
for shared domain A when those costs don't buy it anything. The bridge is the
right structure when nodes must stay **organizationally sovereign** or when the
shared-gateway model is disallowed. Recorded so it can be pulled up without
re-deriving. (One dependency remains unavoidable at IP level: path
reachability — LAN, WAN or an overlay like Tailscale; the mixnet doesn't route
around a dead gateway.)
