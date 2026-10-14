# Cross-Review: SCM4 v0.0.99 Mixnet Assessment vs Local Codebase

## Assessment Summary
This review maps the questions/issues raised in the SCM4 live deployment assessment against what exists in the local `zknode-autonomi-v1` codebase (commit history, configs, scripts, and documentation as of the environment state).

## 1. Observation: MaxPlaintextPayloadLength (1549 vs 1553)

### Assessment Notes
> "Your daemon reports MaxPlaintextPayloadLength = 1549, not the 1553 in PIGEONHOLE_TUNNEL_SPEC.md."

### Codebase Findings
- `PIGEONHOLE_TUNNEL_SPEC.md` (repo root): states `MaxPlaintextPayloadLength=1553` (lines ~37, 39)
- Configs in repo use 1553:
  - `config/mixnet/client/thinclient.toml`: `MaxPlaintextPayloadLength = 1553`
  - `config/mixnet/client/client.toml`: `MaxPlaintextPayloadLength = 1553`
  - `config/proxy/thinclient.toml`: `1553`
  - `katzenpost/test-config/*/thinclient.toml`, `client.toml`: `1553`
  - `katzenpost/laptop-client/*.toml`: `1553`
- Test data: `katzenpost/tools/mixnet-params/tests/test_pigeonhole_geo.py` validates against 31549/1553 derived geometry (UFPL 32000 gives max plaintext 31549)
- There is a test case referencing 1549: `katzenpost/client/config/config_validation_test.go:225` adds a config with `MaxPlaintextPayloadLength = 1549` and expects rejection with "PigeonholeGeometry" (tests that full PigeonholeGeometry table is rejected in certain contexts)

### Cross-Review
**Status:** Documented mismatch observed in live deployment. The local codebase/spec are consistent at 1553. The 1549 value reported by the live daemon suggests either:
1. The deployed build is using different geometry parameters (possibly different UFPL or an older variant)
2. The geometry is computed dynamically from UFPL; actual value depends on the running configuration's UFPL and calculated overhead

The Python geometry tool (`katzenpost/tools/mixnet-params/pigeonhole_geo.py`) computes `max_plaintext_payload_from_ufpl(ufpl)` and overhead is 451 bytes with CTIDH1024-X25519 (as seen in tests). At UFPL=32000, expected is 31549. If daemon reports 1549 as the effective plaintext limit, the live UFPL/config differs from the canonical 1553-based configs. This is an environment/config discrepancy, not a codebase bug in the repo's canonical configs.

## 2. Key Changes: gen-mixnet99.sh regenerates keys on each run; how clients learn about new gateway/authority set?

### Assessment Question
> "gen-mixnet99.sh regenerates every key on each run, and scm4-local recently untracked config/mixnet. How will clients learn about a new gateway or authority set? We suggest a manifest signed by a quorum of the CURRENT authorities and published before it takes effect: in the repo, over HTTPS, and ideally in-band. Details are in the attached KEYS-AND-REGISTRATION.md."

### Codebase Findings
- `scripts/gen-mixnet99.sh`: generates a fresh topology with new keys each run (identity keys, link keys, etc.). It writes to `config/mixnet99/` (or specified OUTDIR). The script explicitly creates new authority identity keys (`auth1/identity.private.pem`, etc. as checked by tests).
- `tests/test-gen-mixnet99.sh` validates structure (auth identity keys exist, etc.) confirming regeneration is the design.
- `scripts/upgrade-node.sh`: uses `gen-mixnet99.sh` to regenerate configs when applying upgrades (Option 1/3); Option 2 (VPS-client) keeps local topology but points to VPS gateway.
- Client configs: 
  - `config/mixnet/client/client.toml` and `config/mixnet/client/client-vps.toml` contain PKI fetch/gateway info. For local networks, they point to internal hosts; for VPS mode they must be updated to point to the VPS gateway.
  - Thin client configs (`config/mixnet/client/thinclient.toml`) have only `[Dial.Tcp]` (new format per docs) — geometry comes from daemon handshake in v0.0.99.
- `docs/OPS_SESSION_2026-08-28.md`: documents "walletshield/config.toml migrated to new thin-client format: only `[Dial.Tcp] Network/Address` — geometry delivered by daemon handshake (old `Network=`/`[SphinxGeometry]` sections rejected with `unknown key(s)`)". Also notes thin client v0.0.99 strictness.
- The thin client (`katzenpost/client/thin/thin.go`) rejects configs with unknown keys (`md.Undecoded()` check) — confirms v0.0.99 is strict about config format.

### Cross-Review
**Partially addressed / design gap.**

Current approach: regeneration is intentional for "fresh" deployments. But for live networks with remote clients (like the SCM4 client dialing 185.92.181.101:30007), rotating authority/gateway keys breaks clients until they get new pinned configs.

What exists:
- `gen-mixnet99.sh` supports `PUBLIC_ADDR_MODE` (ip/dns) to rewrite gateway/client gateway addresses when generating for remote access — this handles address changes but not key rotation signaling.
- `upgrade-node.sh` documents Option 2 as "VPS-client: local mixnet retired; box is thin client dialing VPS gateway" — operational workflow for clients.
- No manifest/signaling mechanism in repo (no `KEYS-AND-REGISTRATION.md` found in tree; references appear only in node_modules/search artifacts in the broader filesystem search earlier, not in the main repo).

**Unaddressed by repo code:** the suggested manifest signed by quorum of CURRENT authorities is not implemented. Clients learn about new topology via manual config updates (e.g. deploying new `client-vps.toml`/thinclient configs). For the devnet, this is acceptable operationally but not robust for rotation.

**Recommendation:** implement the manifest proposal (authority-signed topology manifest, published out-of-band or in-band) if frequent rotation is expected. The assessment's concern is valid.

## 3. Stable authority identities across redeploys?

### Assessment Question
> "Can the authority identity keys stay the same across redeploys, so that only deliberate rotations need a re-pin?"

### Codebase Findings
- `gen-mixnet99.sh` unconditionally generates new keys each time it runs (no flag to preserve existing keys). It writes identity.private.pem, link keys, etc. fresh.
- Test expects fresh generation.
- Authority server code (`katzenpost/authority/voting/server/server.go` around line 277) initializes identity key from config/files — but the generator controls initial creation.
- No existing mechanism to reuse/preserve keys (e.g. no `--preserve-keys` flag, no backup/restore logic in gen-mixnet99.sh).

### Cross-Review
**Not supported by current tooling.**

`gen-mixnet99.sh` is designed to produce a fresh deployment (e.g. for local testing, or when creating a new topology). To keep stable identities across redeploys, operators must:
1. Back up the generated `config/mixnet99/auth*/identity.private.pem` and other authority identity material
2. Restore them before/after regeneration (or modify gen-mixnet99.sh to skip key generation if files exist)

But the script as written does not support this. The assessment is asking for a deliberate design choice - current codebase favors regeneration over stability. For production devnet with remote clients, stable authority identities are strongly preferable.

**Recommendation:** add a `--preserve-authority-keys` (or similar) mode to `gen-mixnet99.sh` that reuses existing authority identity/link keys when present.

## 4. Registration and quotas (node registration vs client registration; hardware-attested identity, anonymous tokens)

### Assessment Question
> "Are client rate limits or Pigeonhole storage quotas planned? We suggest never registering clients at the gateway, because that links traffic. Instead, enroll NODES, for example with a hardware-attested identity like the Zymbit's, and issue anonymous tokens. Would that fit your Phase 1 incentive design?"

### Codebase Findings
- Gateway/servicenode code exists (`katzenpost/server`, `katzenpost/gateway`, `katzenpost/courier`, etc.) but no obvious client registration ACL at gateway in the visible codebase logic.
- Pigeonhole/courier: `katzenpost/courier`, `katzenpost/pigeonhole`, `katzenpost/replica` implement storage layer. No explicit per-client storage quota enforcement visible in quick scan; geometry limits message sizes but not aggregate storage per client identity.
- Thin client connects to daemon (kpclientd) which connects to gateway — authentication model appears to be mixnet-native (Sphinx, no obvious account-based registration linking client identity at gateway layer).
- Zymkey/HSM integration: present in deployment (see `docs/ZYMBIT_SETUP.md`, `docker-compose.zymkey.yml`, references to zkifc, zymbit in USB build scripts). Hardware attestation mentioned in context of SCM4/Zymbit.
- Incentives/tokenomics: references to tokenomics in repo (e.g. tokenomic-router in filesystem, articles mentioning Regenerative Tokenomics Router) but Phase 1 design specifics not fully visible in this repo slice.

### Cross-Review
**Partially aligned with suggestion.**

Katzenpost's design is naturally privacy-preserving (Sphinx packets, no per-packet client identity at gateway in the traditional sense). The suggestion to avoid registering clients at gateway matches the mixnet threat model. The codebase does not show explicit client enrollment/quotas — which suggests either:
1. Not yet implemented (planned)
2. Left to application layer (Pigeonhole access control is application-level)
3. Relies on network-level behavior

Enrolling NODES with hardware attestation (Zymbit) aligns with the hardware-rooted identity work seen (zymkey integration in zknode builds). Anonymous tokens fit well with the privacy goals. This appears consistent with Phase 1 thinking, though concrete implementation isn't visible in the current codebase.

## 5. Incident contact

### Assessment Question
> "Who should we contact about the dev network, and how would you like clients to report problems?"

### Codebase Findings
- No explicit incident contact listed in README, AGENTS.md, or docs scanned (README mentions community/links but not a specific ops contact for the dev mixnet).
- Docs mention remotes: `origin` on GitHub (`ethrx-dev/zknode-autonomi-alpha`) and `zknet` on `git.zknet.cloud` per `docs/OPS_SESSION_2026-08-28.md`.
- Issues/feedback channels not specified in the repo docs visible here.

### Cross-Review
**Unspecified in codebase/docs.**

The repo doesn't document an incident response contact or reporting process for the dev mixnet. This is operational rather than code — needs to be communicated out-of-band (email, Matrix/Discord, GitHub issues, etc.). The assessment is asking for clarification.

## 6. Additional Observations (Context from Live Tests)

### Confirmed Working (matches codebase expectations)
- kpclientd v0.0.99 connecting, verifying consensus with 3 authorities — matches topology generated by `gen-mixnet99.sh` (3 voting authorities)
- Sphinx ping working (5/5), Pigeonhole write/read working with reasonable latencies — confirms the stack is operational as configured
- Thin client config format issue ("unknown key(s)") is explicitly addressed in codebase: `katzenpost/client/thin/thin.go` enforces strict decoding and rejects configs with unknown keys; `walletshield/config.toml` migration noted in docs (only `[Dial.Tcp]` allowed, geometry from handshake)

### Config Discrepancies to Track
1. **MaxPlaintextPayloadLength 1549 vs 1553**: Live daemon reports 1549. Canonical repo uses 1553. Needs verification against live geometry/UFP parameters.
2. **client-vps.toml** in repo at `config/mixnet/client/client-vps.toml` has the v0.0.99-compatible structure for the client daemon (not the thin client). The assessment notes thinclient.toml pre-v0.0.99 had inline geometry — that's consistent with thin client config now being minimal.
3. **gen-mixnet99 regenerates keys**: By design in current tooling. If stable identities are required for the dev network, tooling needs enhancement.

## Summary

| Assessment Item | Addressed in Codebase? | Notes |
|---|---|---|
| MaxPlaintextPayloadLength discrepancy (1549 vs 1553) | Partially | Canonical is 1553; live may differ due to runtime geometry calculation/UFP settings. No code forces 1549. |
| Key regeneration & client discovery | Not implemented | `gen-mixnet99.sh` regenerates keys (design). No authority-signed manifest mechanism exists for distributing new topology to clients. |
| Stable authority identities | Not supported | No preservation flag in generator. Operators must manually backup/restore keys to maintain stability. |
| Registration/quotas, hardware-attested identities | Design-aligned, not implemented | Privacy model fits (no client registration at gateway). Zymbit/HSM present; quotas/tokens not implemented in visible code. |
| Incident contact | Not documented | No contact/reporting process specified in repo docs. |

## Action Items (Brief)

- **Geometry verification:** Confirm live daemon's UFPL and compare computed `MaxPlaintextPayloadLength` against 1553. If different, align deployed config/spec or document rationale.
- **Key rotation signaling:** Design and implement an authority-signed topology manifest (quorum-signed) published before taking effect, supporting in-band/HTTPS distribution for clients (addresses the "how do clients learn of new gateway/authority set?" question). Consider adding KEYS-AND-REGISTRATION.md.
- **Stable authority identities:** Add `--preserve-authority-keys` (or similar) to `gen-mixnet99.sh` to reuse existing authority identity keys across redeploys when deliberate rotation is not intended.
- **Registration/quotas:** Define policy - clarify if client rate limits/Pigeonhole storage quotas are planned for Phase 1. If adopting node-based enrollment with hardware attestation + anonymous tokens, document the design.
- **Incident contact:** Document official incident contact and reporting process (channel, email, GitHub issues) in README/OPS docs for the dev network.
