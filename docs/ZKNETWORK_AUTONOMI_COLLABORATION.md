# ZKNetwork × Autonomi — Collaboration Proposal

## The Opportunity

Autonomi provides decentralized, permanent, immutable data storage. ZKNetwork provides mixnet-based private communication infrastructure. Together, they solve a problem neither can solve alone: **anonymous storage node operation**.

Today, anyone running an Autonomi storage node exposes their IP address to every peer they connect to. This makes node operation a privacy risk — the operator's location, ISP, and network identity are publicly visible on the DHT. For a network that aims to be censorship-resistant, this is a critical gap.

ZKNetwork's Katzenpost mixnet can wrap Autonomi's P2P traffic in 3-hop onion routing, hiding the node's real IP behind the mixnet exit. The entire mixnet runs on the same device as the storage node — no external VPS or cloud dependency. **Any old computer laying around can become a private Autonomi node.**

---

## The PoC We Built

A single SCM4/CM4 (8GB RAM, aarch64) running 10 Docker containers:

| Component | What it does | Source |
|-----------|-------------|--------|
| **ant-node** | Autonomi storage node — chunk storage, DHT, replication | WithAutonomi/ant-node |
| **antd** | Autonomi CLI container (idle — docker exec for commands) | WithAutonomi/ant-client |
| **mixnet ×8 containers** | Katzenpost 3-hop mixnet — dirauth×3, mix×3, gateway, servicenode | katzenpost/katzenpost v0.0.73-rc3 |
| **mixnet-proxy** | Bridges ant-node traffic through the mixnet (SOCKS5) | Custom (~300 lines Go) |
| **USB pool** | 1-4 TB chunk storage via mergerfs + zymkey-bound LUKS | External USB drives |

Key properties:
- **No VPS needed** — all mixnet containers and the Autonomi node run on one SCM4
- **Host networking** — mixnet containers share host network (127.0.0.1); Autonomi uses bridge
- **Native cross-compilation** — Go and Rust binaries built for arm64 from any amd64 machine, no QEMU
- **Two-tier storage** — performance-sensitive app data on microSD, bulk chunk DB on USB
- **~4.4 GB RAM** total — fits comfortably in 8 GB
- **Dirauth retry loop** — automatic consensus recovery on startup

---

## Why This Matters

### For Autonomi

| Problem | How ZKNetwork solves it |
|---------|------------------------|
| Node IP is exposed on the DHT | Mixnet hides the real IP behind 3-hop onion routing |
| Node operators risk doxing | External peers see only the mixnet exit IP |
| Censorship by ISP/state | Traffic appears as mixnet packets, not Autonomi P2P |
| No privacy infrastructure to build | Drop in a running mixnet — no changes to ant-node core |
| Hardware cost for privacy | Same device runs mixnet + storage node — no VPS bill |

**Concrete benefit**: Autonomi can offer a "private node" mode where operators opt into mixnet routing. This differentiates Autonomi from every other decentralized storage network (Filecoin, Storj, Arweave) — none offer node-level IP privacy out of the box.

### For ZKNetwork

| Problem | How Autonomi solves it |
|---------|----------------------|
| Mixnet needs diverse use cases | Anonymous storage is a concrete, high-value application |
| Mixnet utility limited to messaging | General-purpose anonymous transport for P2P networks |
| Hard to demonstrate real-world value | Running on cheap hardware proves mixnet efficiency |
| Need for network effects | Autonomi's ecosystem provides a ready user base |
| Single-point-of-failure reliance | Storage adds redundancy to the mixnet's value proposition |

**Concrete benefit**: ZKNetwork gains a flagship integration. The mixnet becomes infrastructure for the Autonomi network — a tangible use case beyond chat/SURBs. This is a reference architecture for any future "anonymize my P2P traffic" integration.

---

## Technical Integration Depth

The integration surface is remarkably small:

```
ant-node ──QUIC──▶ mixnet-proxy ──SURB──▶ mix-servicenode ──QUIC──▶ Autonomi peer
                      │                                                 │
                  200 lines                                           unaware
                  of code                                           of mixnet
```

The mixnet-proxy is the only new component. It:
1. Receives QUIC connections from ant-node (bound to local WireGuard IP)
2. Wraps each packet in a mixnet SURB (Single-Use Reply Block)
3. Sends through the 3-hop mixnet
4. Mix-servicenode decrypts the final layer and forwards to the external Autonomi peer
5. Return traffic reverse-paths through the mixnet

No changes to `ant-node`, `saorsa-core`, `saorsa-transport`, or any Autonomi crate. The mixnet is a transparent transport layer.

---

## Collaboration Models

### Model A: Reference Integration (Lowest friction)

ZKNetwork publishes the mixnet-proxy as an open-source reference. Autonomi documents it as a recommended add-on for privacy-conscious node operators.

- **ZKNetwork provides**: mixnet-proxy code + documentation
- **Autonomi provides**: links from docs, recommendation for private node operation
- **Timeline**: 2-3 weeks to working PoC, 1-2 months to production-grade
- **Cost**: Engineering time only

### Model B: Bundled Distribution

ZKNetwork's mixnet is bundled with the `ant` CLI as an optional `--private` flag. When a user runs `ant node start --private`, the mixnet-proxy starts alongside ant-node.

- **ZKNetwork provides**: embedded mixnet-proxy library + maintains mixnet image
- **Autonomi provides**: `--private` flag in CLI and SDK
- **Timeline**: 1-2 months for CLI integration, 3-4 months for SDK
- **Complexity**: Medium — requires changes to ant CLI, packaging of mixnet images

### Model C: Deep Integration (Most ambitious)

The mixnet becomes a built-in transport option in `saorsa-transport`. Instead of QUIC-only, nodes can negotiate "mixnet mode" during peer discovery and route traffic through the mixnet natively.

- **ZKNetwork provides**: Sphinx (onion encryption) library for inclusion in saorsa-core
- **Autonomi provides**: mixnet transport trait in saorsa-transport
- **Timeline**: 3-6 months
- **Complexity**: High — requires changes to core networking, peer protocol upgrade

### Recommendation

**Start with Model A** (reference integration). It proves the concept with zero changes to Autonomi code. If the community adopts it, move to **Model B** (bundled). Model C is aspirational and should only be considered if the anonymity requirement becomes core to Autonomi's product strategy.

---

## What Each Side Contributes

### ZKNetwork

| Deliverable | Description | Timeline |
|-------------|-------------|----------|
| Mixnet-proxy reference implementation | Go binary, ~300 lines SOCKS5 bridge | Week 1-2 |
| Docker images | Pre-built arm64 images for SCM4 (4 images) | Week 1-2 |
| docker-compose.yml | 10-service deployment template | Week 1-2 |
| Configuration generator | genconfig-based mixnet PKI + node configs | Week 2-3 |
| Documentation | Architecture, setup, operation, troubleshooting | Week 2-3 |

### Autonomi

| Deliverable | Description | Timeline |
|-------------|-------------|----------|
| ant-node arm64 binaries or Dockerfile | Currently may need Rust cross-compile setup | Week 1 |
| ant CLI binaries or Dockerfile | From ant-client repo, for management | Week 1-2 |
| Bootstrap peer list | For testnet/mainnet connectivity | Week 1 |
| EVM testnet wallet + tokens | For payment during PoC | Week 1 |
| Review of mixnet-proxy approach | Sign off on the transport bridge design | Week 1 |

---

## Operational Models

For a production deployment, there are several possible arrangements:

**Self-hosted**: Node operators run their own mixnet (all 9 containers on their own SCM4). Fully self-contained — this is what the PoC demonstrates. No external infrastructure required.

**ZKNetwork-operated authorities**: Critical mixnet infrastructure (directory authorities) run by ZKNetwork for security. Mix and gateway nodes run on the operator's device for locality. Balances trust and self-sovereignty.

**Fully-hosted**: ZKNetwork runs the entire mixnet infrastructure. Operators connect to it as a service. Lowest operator overhead but requires trust in ZKNetwork's infrastructure.

The PoC architecture supports all three — the mixnet containers are standard Docker images that can be deployed anywhere.

---

## Next Steps

1. **Complete the PoC build** — build all 5 Docker images, validate end-to-end
2. **Record a demo** — 5-minute walkthrough: setup → start → store → verify anonymity → retrieve
3. **Present to Autonomi team** — technical review of the mixnet-proxy approach
4. **Publish the reference implementation** — open-source the mixnet-proxy + docker-compose
5. **If interest**: move to Model B (bundled CLI flag)

The hardware bill for a complete demo setup:
- Zymbit Secure Compute Module (SCM) with 8GB RAM: ~$245 (SCM Pro, includes integrated CM4 + HSM)
- Zymbit carrier/motherboard + PSU: ~$130
- USB SSD (2TB): ~$120
- SD card + case: ~$30
- **Total: ~$525**

Note: The SCM is a single encapsulated module containing the CM4, zymkey HSM, tamper sensors, secure boot, and hardware crypto engine — it replaces separate CM4 + zymkey. Pricing is from Zymbit's published SCM Pro ($245 with 8GB/32GB). Current store pricing for bundled Secure Edge Node kits ranges from $475-$675. Contact Zymbit for OEM/volume pricing.

This fits in a small Pelican case and runs on 5V/3A USB power.
