# P4P Wiki Mesh - Living Beta Program

## Private & Secure Peer-to-Peer Infrastructure for the P2P Foundation

---

**Presented by:** ZKNetwork Team
**In Collaboration with:** Autonomi
**Date:** July 2026

---

## Executive Summary

We propose a living beta program to deploy **200 Secure Core Nodes** globally, forming the foundation of a private, secure, and sovereign P4P (Peer-for-Peer) wiki mesh network. This infrastructure enables uncensorable communication, data storage, and application hosting for communities worldwide — from local mesh networks to global p2p applications.

The program is built on two hardware tracks — **DIY SCM4 Compute Module** for makers and **SEN400 Beta Node** for plug-and-play deployment — and leverages a formal collaboration between **ZKNetwork** (mixnet privacy layer) and **Autonomi** (autonomous data storage network).

---

## 1. The Problem

| Challenge | Description |
|-----------|-------------|
| **Surveillance** | Internet traffic is monitored, logged, and analyzed at every layer |
| **Censorship** | DNS, IP, and application-level blocking silos information |
| **Centralization** | Cloud infrastructure creates single points of failure and control |
| **Digital Sovereignty** | Communities lack ownership of their communication infrastructure |
| **Environmental Cost** | Traditional data centers consume enormous energy |

Existing solutions (Tor, VPNs, Signal) address pieces but lack a unified, self-sovereign infrastructure that is both private AND autonomous.

---

## 2. The Vision: P4P Wiki Mesh

A **global mesh of Secure Core Nodes** providing:

- **Private Mixnet Routing** — Katzenpost Sphinx packet cryptography with post-quantum wire KEM (MLKEM768)
- **Autonomous Data Storage** — Autonomi network for decentralized, self-healing storage
- **Zero-Knowledge Identity** — Self-sovereign identity with ZK proofs
- **Mesh Networking** — Reticulum protocol for resilient peer-to-peer connectivity
- **Uncensorable Applications** — Chat, proxy, file sharing, and custom services over the mixnet

> *"A wiki mesh — where every node is both a peer and an infrastructure provider, secured by cryptography, governed by community."*

---

## 3. Hardware Tracks

### Track A: DIY Node — SCM4 Compute Module

| Component | Specification |
|-----------|---------------|
| **SoC** | Broadcom BCM2711 (Quad-core Cortex-A72, 1.8GHz) |
| **RAM** | 8GB LPDDR4 |
| **Storage** | 32GB eMMC + optional NVMe (via PCIe) |
| **HSM** | Zymkey ZK (I2C HAT) — secure key storage & attestation |
| **FPGA (optional)** | Lattice iCE40 for hardware acceleration |
| **Networking** | Gigabit Ethernet, WiFi 5, optional 4G/LTE HAT |
| **Power** | 5V/3A USB-C, PoE HAT compatible |
| **Cost** | ~$250 per node |
| **Enclosure** | 3D-printable or lasercut case |
| **Assembly** | No soldering required — all HATs use GPIO headers |

### Track B: SEN400 Beta Node

| Component | Specification |
|-----------|---------------|
| **SoC** | CM4-based custom carrier board |
| **RAM** | 8GB LPDDR4 |
| **Storage** | 128GB eMMC + NVMe SSD slot |
| **HSM** | Zymkey ZK (onboard, integrated) |
| **FPGA** | Lattice iCE40 for hardware-accelerated Sphinx packet processing |
| **Networking** | Gigabit Ethernet, WiFi 6, optional 5G module |
| **Power** | 12V DC, PoE+ IEEE 802.3at, solar input compatible |
| **Enclosure** | CNC aluminum, passive cooling, DIN-rail mountable |
| **Cost** | ~$500-800 per node |

Both tracks run identical software stacks — the difference is hardware capacity and form factor.

---

## 4. Software Stack

```
┌─────────────────────────────────────────────┐
│            Applications Layer               │
│  Chat  │  Proxy  │  Storage  │  Custom      │
├─────────────────────────────────────────────┤
│         Zero-Knowledge Identity (ZK)        │
├─────────────────────────────────────────────┤
│          Katzenpost Mixnet (Sphinx)         │
│   Post-Quantum Wire KEM │ Decoy Traffic     │
├─────────────────────────────────────────────┤
│        Autonomi Storage Network             │
│   Pigeonhole Courier │ Storage Replicas     │
├─────────────────────────────────────────────┤
│          Reticulum Mesh Transport           │
├─────────────────────────────────────────────┤
│     Zymkey HSM │ Encrypted Root FS          │
├─────────────────────────────────────────────┤
│         Raspberry Pi CM4 / SEN400           │
│              ARM64 Linux                    │
└─────────────────────────────────────────────┘
```

**Key cryptographic primitives:**

| Component | Algorithm | Type |
|-----------|-----------|------|
| Sphinx NIKE | X25519 | Classic ECDH |
| Wire KEM | MLKEM768 | Post-quantum (FIPS 203) |
| PKI Signatures | Ed25519 | Classic |
| Storage NIKE | CTIDH1024-X25519 | Hybrid post-quantum |
| HSM Attestation | Zymkey ECDSA | Hardware-backed |
| Disk Encryption | LUKS + AES-256-CBC | At-rest |

---

## 5. Autonomi Partnership

**ZKNetwork** and **Autonomi** are collaborating to integrate:

| ZKNetwork Provides | Autonomi Provides |
|--------------|-------------------|
| Private mixnet routing (Katzenpost) | Autonomous data storage network |
| Decoy traffic & metadata protection | Pigeonhole storage proof system |
| Sphinx packet cryptography | Storage replica consensus |
| Wallet Shield (HTTP-to-mixnet proxy) | ANT token economics |
| Secure Core Node hardware integration | Autonomi Node (antd) integration |

**Integration architecture:**

```
User App → WalletShield → Mixnet (ZKNetwork) → Courier → Autonomi Storage
  (ZK proof)    (privacy)    (anonymity)   (bridge)    (persistence)
```

This enables private access to Autonomi's storage network through the mixnet — users interact without exposing their IP, location, or identity.

---

## 6. Living Beta Program — 200 Nodes

### Phased Deployment

**Phase 1 — Pilot (20 nodes) — Months 1-3**
- Core team & early adopters
- DIY SCM4 nodes
- Testing & hardening
- Documentation & onboarding

**Phase 2 — Growth (80 nodes) — Months 4-6**
- Community contributors
- Mix of DIY and SEN400 nodes
- Geographic diversity (min 15 countries)
- Application ecosystem development

**Phase 3 — Scale (100 nodes) — Months 7-12**
- Global distribution
- SEN400 priority for underserved regions
- Enterprise & NGO partners
- Mesh network interconnections

### Node Distribution Goals

| Region | Nodes | Focus |
|--------|-------|-------|
| North America | 50 | Community mesh, education |
| Europe | 50 | Privacy advocacy, research |
| Latin America | 30 | Underserved connectivity |
| Africa | 30 | Infrastructure independence |
| Asia-Pacific | 30 | Disaster resilience |
| Middle East | 10 | Censorship circumvention |

### Beta Program Benefits

- **Free SEN400 units** for qualifying community organizers in underserved regions
- **DIY build guides** and subsidized SCM4 kits
- **Direct support channel** with core developers
- **Governance participation** in protocol evolution
- **Early access** to new features and applications

---

## 7. Use Cases

### Communication
- Private messaging over mixnet (zkchat)
- Group chat with forward secrecy
- Uncensorable broadcast channels

### Data Storage
- Autonomous file storage via Autonomi
- Encrypted backup & sync
- Content-addressed publishing

### Web Access
- HTTP proxy through mixnet
- Uncensored browsing
- .onion-style hidden services

### Mesh Networking
- Off-grid community networks
- Disaster recovery infrastructure
- Rural connectivity

### Financial Sovereignty
- Wallet Shield for private Ethereum RPC access
- ZK-proof-based identity for DeFi
- Private transaction relay

---

## 8. Security Model

| Threat | Mitigation |
|--------|------------|
| Traffic analysis | Sphinx packet layering + constant-rate decoy traffic |
| Node compromise | HSM key storage, encrypted root FS, remote attestation |
| Network surveillance | Mixnet routing through 3+ hops with post-quantum KEM |
| Censorship | Entry via gateway nodes, exit via service nodes — no visible destination |
| Physical seizure | LUKS encryption, HSM tamper response, ephemeral keys |
| Sybil attacks | PKI voting consensus, proof-of-uptime, stake-based registration |

---

## 9. Governance

The beta program is governed by:

- **ZKNetwork Core Team** — Protocol development, security audits, hardware validation
- **Autonomi** — Storage network integration, token economics
- **Node Operators** — Community representatives from each region
- **P2P Foundation** — Advisory role, community coordination, ethical oversight

Decisions made via:
- Open RFC process
- Signed consensus among operator representatives
- Transparent voting on protocol upgrades

---

## 10. Call to Action

We invite the **P2P Foundation** to:

1. **Endorse** the living beta program as a framework for community-owned infrastructure
2. **Connect** us with community organizers in target deployment regions
3. **Collaborate** on governance models for the node operator network
4. **Help refine** the ethical and social impact framework

---

## Appendix A: Node Specifications

### Minimum Requirements (DIY SCM4)

- Raspberry Pi SCM4 (8GB RAM)
- 32GB eMMC
- Zymkey ZK HAT
- Gigabit Ethernet
- 16GB+ microSD (boot) or NVMe
- Debian 12 (Bookworm) ARM64

### Recommended (SEN400 Beta)

- CM4-based carrier board
- 8GB RAM, 128GB storage
- Integrated Zymkey
- WiFi 6 + 5G optional
- DIN-rail aluminum enclosure
- Passive cooling, fanless

---

## Appendix B: Quick Start

```bash
# Clone the deployment repo
git clone https://github.com/Alchemi1/zknode-autonomi-alpha.git

# Build and deploy with Docker
cd zknode-autonomi-alpha
docker compose -f docker-compose.yml up -d

# Check node status
./scripts/monitor.sh
```

---

## Appendix C: Current Deployments

| Node | Type | Location | Status |
|------|------|----------|--------|
| zknode | SCM4 (DIY) | North America | Operational |
| *(200 target)* | Mix of DIY + SEN400 | Global | Planned |

---

*This document is a living proposal. Join the conversation:*

- **GitHub:** https://github.com/Alchemi1/zknode-autonomi-alpha
- **Contact:** ZKNetwork Core Team

---

*"Privacy is not about hiding. It's about sovereignty."*
