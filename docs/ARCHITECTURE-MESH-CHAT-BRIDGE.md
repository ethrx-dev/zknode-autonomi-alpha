# Mesh Chat Bridge — Architecture

## Goal

Allow users on **reticulum/nomadnet** networks to communicate with users inside
the **zkchat mixnet** without exposing mixnet identity to the mesh.

## High-Level Design

```
┌─────────────────┐     ┌───────────────────┐     ┌──────────────┐
│  nomadnet peer   │────▶│  chat-bridge      │────▶│  zkchat      │
│  (reticulum)     │     │  daemon           │     │  (mixnet)    │
└─────────────────┘     │                   │     └──────────────┘
                         │  ┌─────────────┐  │
                         │  │ reticulum    │  │
                         │  │ transport    │  │
                         │  │ (RNS API)    │  │
                         │  └─────────────┘  │
                         │  ┌─────────────┐  │
                         │  │ mixnet       │  │
                         │  │ transport    │  │
                         │  │ (katzenpost  │  │
                         │  │  thinclient) │  │
                         │  └─────────────┘  │
                         └───────────────────┘
```

## Components

### chat-bridge daemon (`cmd/chat-bridge/`)

A Rust binary that:
1. Listens on reticulum for nomadnet messages (via RNS API)
2. Translates to zkchat group/DM format
3. Sends into mixnet via katzenpost thinclient
4. Reverse: listens on mixnet for outbound messages and publishes to reticulum

### Reticulum Transport

- Uses `reticulum` Rust crate or RNS JSON API
- Listen on a dedicated nomadnet channel/identity for zkchat bridge
- Parse incoming messages as zkchat-compatible CBOR

### Mixnet Transport

- Reuses existing thinclient config from `config/mixnet/client/`
- Sends to `chatd` provider via Kaetzchen interface
- Receives via long-poll or event subscription

## Message Flow

### Mesh → Mixnet

```
1. nomadnet peer sends message to bridge identity
2. Bridge receives via RNS, extracts:
   - recipient: mixnet group_id or user hex
   - content: plaintext
3. Bridge constructs zkchat CBOR message
4. Bridge sends to chatd via mixnet thinclient
5. chatd delivers to group/DM recipient
```

### Mixnet → Mesh

```
1. Bridge subscribes to zkchat group(s) via chatd
2. On new message, bridge extracts content
3. Bridge publishes to nomadnet channel as mesh broadcast
4. nomadnet peers receive the message
```

## Configuration

```toml
# config/nomadnet/chat-bridge-config.toml
[mixnet]
thinclient_config = "/app/config/client/thinclient.toml"
chatd_provider = "chatd.mixnet.local"  # provider name in PKI

[reticulum]
rns_api_url = "http://127.0.0.1:9494"  # RNS JSON API
bridge_identity = "zkchat-bridge"        # nomadnet identity
channel = "zkchat-bridge"               # channel name

[groups]
listen = ["default-group-id"]            # which mixnet groups to bridge
```

## Implementation Plan

1. **Phase 1** — Build bridge skeleton with reticulum listener (no mixnet yet)
2. **Phase 2** — Add mixnet send/receive via thinclient
3. **Phase 3** — Two-way relay, error handling, reconnection
4. **Phase 4** — Docker integration, compose file, health checks

## Files

```
cmd/chat-bridge/          → Rust binary source
config/nomadnet/          → config TOML
scripts/bridge-setup.sh   → setup script
```

## Security Considerations

- Bridge has its own mixnet identity (not user identities)
- Group messages are encrypted in mixnet transit but decrypted by bridge
- Bridge should be containerized with minimal network access
- Rate limiting to prevent spam from mesh to mixnet
