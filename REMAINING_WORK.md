# Remaining Work - WalletShield End-to-End RPC

## Current Status (as of 2026-08-20)

### ✅ Completed
- **Dirauth consensus**: 3/3 signatures for epochs 242488-242496
- **Gateway in consensus**: Successfully uploading descriptors
- **PKI document fallback**: Working for failed epochs (242491, 242493, etc.)
- **Thin client listener**: Port 64332 on kpclientd accepting connections
- **Thin client PKI sync**: Working via fallback mechanism
- **Service discovery**: Walletshield finds proxy service (epoch 242492+)
- **Servicenode descriptors**: Successfully accepted for epochs 242491-242496
- **http-proxy-server**: Running on servicenode, processed requests earlier (17:xx UTC)
- **Echo service**: Need to deploy for SURB testing
- **Mixnet consensus**: Stable at 3/3 signatures

### ❌ Blocked: WalletShield End-to-End RPC

#### Root Cause
WalletShield uses a **forked thin client** (`walletshield-fix/thin/`) with old `client2` import paths that are incompatible with the updated kpclientd (which uses `client/thin`). The protocol mismatch causes:
1. WalletShield connects to kpclientd and gets PKI docs successfully
2. But `BlockingSendMessage` fails silently or messages aren't routed
3. Gateway shows no incoming messages for proxy service

#### Error Symptoms
- WalletShield: "GetService(proxy) ok" but RPC times out
- Gateway: Only RetrieveMessage (PKI docs), no service messages
- kpclientd: WalletShield connects but no message processing logs
- http-proxy-server: Last activity 17:xx UTC, no recent requests

### 🔧 Required Fixes

#### 1. Rebuild WalletShield with Updated Thin Client (HIGH PRIORITY)
**Problem**: WalletShield's forked thin client (`walletshield-fix/thin/`) uses old `client2` imports, incompatible with updated `client/thin`.

**Attempted Solutions** (all failed due to dependency conflicts):
- `go get` pulls incompatible hpqc v0.0.78 vs opt repo's v0.0.68
- `go mod tidy` pulls client2 imports from other opt packages
- Pre-built binary uses old client2 protocol

**Remaining Approaches**:
- [ ] Patch walletshield-fix go.mod to use hpqc v0.0.78 + update go.sum
- [ ] Update all opt repo packages to use `client/thin` instead of `client2`
- [ ] Cross-compile walletshield on local machine with local katzenpost
- [ ] Use a minimal walletshield binary that only uses the new thin client

#### 2. Deploy Echo Service for SURB Testing (MEDIUM)
- Add echo-plugin to mix1 config
- Redeploy mix1
- Test ping tool for SURB round-trip verification

#### 3. Debug Forward Path (MEDIUM)
- Verify gateway routing to servicenode
- Check SURB generation/forwarding
- Test basic mixnet round-trip with ping tool

### Disk Space
- Root: 14G total, 11G used, **2.3G free (83%)** - OK

### Next Session Priority
1. **Fix walletshield-fix/go.mod** to use hpqc v0.0.78, run `go mod tidy`, rebuild
2. Deploy echo-plugin on mix1
3. Test ping tool → verify SURB path
4. Verify walletshield RPC end-to-end

### Files Modified This Session
- `katzenpost/client/pki.go` - PKI fallback accept mismatched epochs
- `katzenpost/authority/voting/server/state.go` - Widen DB fallback
- `katzenpost/authority/voting/client/client.go` - Accept mismatched epochs
- `katzenpost/client/thin/thin.go` - TOML config fixes, Dial/Listen support
- `katzenpost/client/thin/thin_messages.go` - Added missing message types
- `katzenpost/client/thin/thin_events.go` - InstanceToken support
- `katzenpost/client/thin/thin_pigeonhole.go` - (copied to walletshield-fix)
- `katzenpost/client/thin/transport/` - (copied to walletshield-fix)
- `katzenpost/core/log/log.go` - discardCloser fix
- `katzenpost/client/common/common.go` - FindServices panic fix
- `katzenpost/pigeonhole/geo/geometry.go` - TOML tags
- `katzenpost/core/sphinx/geo/geo.go` - TOML tags
- `walletshield-fix/main.go` - Fixed imports to use client/thin
- `walletshield-fix/thin/*` - Copied updated thin client
- `KATZENPOST_CHANGES.md` - Documentation
- `REMAINING_WORK.md` - This file

### Git Status
- Committed: `f92b941` - "Fix katzenpost thin client, PKI fallback, and SURB issues"
- Pushed to `main` and `p4p-alpha-unified`
