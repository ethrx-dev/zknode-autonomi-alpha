# Privacy Boundaries — zknode-autonomi (P4P v.01)

> **Purpose**: one honest statement of what is and is not metadata-private in
> the current stack. Each boundary lists where traffic terminates and what
> an observer can and cannot learn. Companion to `DISCLAIMER.md`
> (proof-of-concept, testnet) and the playbook in `AGENTS.md`.

## Threat model assumptions

The mixnet protects against: **local network observers** (LAN/router/ISP
between the client and the RPC endpoint), **endpoint metadata correlation**
(the upstream RPC provider never sees the requester's IP), and **passive
linkability inside the mixnet** (layered Sphinx encryption, per-hop key
material, cover-traffic configuration).

The current stack does **not** protect against: a **global passive
adversary** correlating entry and exit timing, **compromised node
operators** (all mixnet hops run on this device under one operator), or
**traffic-volume analysis at scale**.

## Boundary map

| # | Path / surface | Route | Privacy status | Residual exposure |
|---|---|---|---|---|
| 1 | **WalletShield EVM RPC** (`:8080/ethereum` → walletshield → kpclientd → 3-hop mixnet → servicenode `http` plugin → upstream) | Metadata-private end to end | ✅ **Protected** | Request/response content is end-to-end TLS to the upstream; the upstream sees mixnet exit traffic, not the requester. Response payloads >2000 bytes are rejected by Sphinx geometry. |
| 2 | **zkchat / group chat** | mixnet-native (thin client → chatd on servicenode) | ⚠️ **Transport protected, metadata on node** | Message transport rides the mixnet; group membership and metadata live server-side in chatd storage (currently ephemeral `/tmp/zkchat` on the servicenode). |
| 3 | **Wiki transport (llm-wiki / NomadNet pages)** | direct HTTP on the node; mesh pages via Reticulum/NomadNet | ⚠️ **Partial** | Node-local reads are unobservabale externally; NomadNet mesh traffic rides Reticulum, not the Katzenpost mixnet. |
| 4 | **Autonomi P2P node traffic** (QUIC `:12000`, bootstrap peers, chunk upload/download) | **Direct** — no SOCKS/mixnet path | ❌ **Public by protocol design** | Peer IP is exposed to the Autonomi network and bootstrap seeds; earning/storage traffic is attributable to the node's rewards address. Routing this over the mixnet is an open design problem (latency-sensitive UDP/QUIC), tracked in `REMAINING_WORK.md`. |
| 5 | **Storage proofs & rewards** (Arbitrum Sepolia) | direct EVM | ❌ **Public** | Proofs, rewards address, and settlement are on a public ledger by design. |
| 6 | **Dashboard** (`:8080`) | LAN web app → loopback services | ⚠️ **Authenticated but LAN-local** | Token auth + rate limits; binds `127.0.0.1` unless `DASHBOARD_TOKEN` is set. Dashboard actions are visible to anyone with the token. |
| 7 | **Node identity & keys** | zymkey HSM (SCM4); encrypted state bundles | ✅ **Hardware/encrypted** | Private keys never in git (enforced by the secret-scan test); backups are age/openssl-encrypted with an out-of-band key. |
| 8 | **Management planes** (dashboard API, proxy `:9090`, client daemon `:64331`, servicenode plugins) | loopback / bridge | ⚠️ **Internal** | Bound to loopback or the internal bridge; not externally reachable except the dashboard (see #6). |

## The embedded mixnet is a lab, not an anonymity network

All three authorities, three mixes, the gateway, and the servicenode run on
one device under one operator. This is sufficient to validate the
**protocol** (post-quantum Sphinx routing, PKI consensus, thin-client RPC)
and is explicitly **not** distributed anonymity: entry and exit are
correlated by co-location, and a device-level observer sees everything.
Production privacy requires independently operated mix nodes on separate
hosts/networks/operators — the topology generator
(`scripts/gen-mixnet99.sh`) and the PKI design already support that
deployment shape.

## Data residency

| Data | Location | Persistence |
|---|---|---|
| Autonomi chunks | USB pool (`/mnt/autonomi/autonomi/chunks`) | persistent, LUKS on SCM4 |
| Mixnet node keys & configs | `config/mixnet99/` (node-local) | persistent; auto-generated on first boot |
| zkchat group metadata | servicenode container `/tmp/zkchat` | **ephemeral** — wiped on servicenode restart |
| Chat identity | `config/mixnet99/client/.zkchat/identity` | persistent node state |
| Mixnet & plugin logs | node `katzenpost.log`, `proxy.*.log` | rotated; logrotate on SCM4 |
| Encrypted state backups | `/mnt/autonomi/backup/` | 8-bundle retention, sha256 sidecars |

## Strengthening the weak boundaries (forward list)

1. **Autonomi over mixnet** — design work required (QUIC-over-mixnet or a
   proxy mode that tolerates P2P latency); until then boundary #4 stays open.
2. **Distributed mixnet operators** — redeploy the same topology across
   independently operated hosts (no code change; ops + trust work).
3. **chatd privacy + persistence** — move group metadata off `/tmp`, and
   consider encrypted-at-rest group state.
4. **Cover traffic review** — client decoy traffic is currently disabled;
   revisit as mesh peers grow.

---

*Aligned with: `DISCLAIMER.md` (PoC/testnet status), `AGENTS.md` (canonical
playbook), `REMAINING_WORK.md` (open items).*
