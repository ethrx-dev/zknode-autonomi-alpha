# Pigeonhole TCP Tunnel - Spec (approved for review, no changes made yet)

Status: analysis complete, awaiting execution approval. No mixnet or proxy changes made.

## 1. What this delivers
A working SOCKS5 proxy at 127.0.0.1:1080 that carries arbitrary TCP app traffic (EVM RPC,
curl, wallets) through the Katzenpost mixnet to the SCM4 servicenode, which dials the real
destination on the internet. Two halves:

- Client-side (mixnet-proxy container, new binary): real SOCKS5 server. Each SOCKS5
  connection -> one pigeonhole stream (SURB-based) to the servicenode, carrying a
  CONNECT host:port request then raw TCP bytes in both directions.
- Server-side (mix-servicenode, new service): receives the stream, parses CONNECT
  host:port, dials the target, relays bytes. NO TLS termination, NO HTTP - raw TCP only.
  This is what makes it a tunnel rather than a proxy.

## 2. Facts confirmed on SCM4 (2026-07-31)
Pigeonhole stack exists but is cold:
- courier running in mix-servicenode (PID 17) with 4 unix sockets in
  /var/lib/katzenpost/servicenode1/courier/*.courier.socket. chatd + http-proxy-server
  also running.
- 5 storage replicas configured in PKI (authority.toml [[StorageReplicas]], IDs 0-4,
  addr tcp://127.0.0.1:3300{0..4}) with configs at config/mixnet/replica{1..5}/.
- BUT no replica containers running - ports 33000+ unbound, no replica service in
  docker-compose.yml, and the deployed zeros/mixnet-node:arm64 image ships courier/
  dirauth/kpclientd/server but NO replica binary. BLOCKING GAP: pigeonhole delivery
  requires the replicas to be up (courier dispatches to them). zkchat's poll loop only
  proves the send/queue path reaches courier, not end-to-end delivery.

Protocol surface (deployed kpclientd v0.0.84, verified via /tmp/kp-live.bin):
- Has: pigeonhole NewKeypair / EncryptRead / EncryptWrite,
  StartResendingEncryptedMessage, WriteStream / ReadStream (SACK/ARQ), CourierQuery.
- Does NOT have: channel APIs (CreateWriteChannel / WriteChannel / ReadChannel) - those
  exist only in the newer walletshield-fix/thin source. Streams must be driven via the
  SACK/ARQ WriteStream/ReadStream surface, not channels.

Geometry (config/proxy/thinclient.toml): MaxPlaintextPayloadLength=1553,
CourierQueryWriteLength=2000, CourierQueryReadLength=359, CourierQueryReplyReadLength=1698.
Stream chunking must respect geometry.MaxPlaintextPayloadLength - CopyStreamElementOverhead.

Payload ceiling (~2KB/message) is a message limit, not a stream limit: copy_stream chunks
large payloads across many SURB messages, so streaming TCP works despite the ceiling.

Current mixnet-proxy is the wrong binary: the container runs the old WireGuard-based
SOCKS5 proxy (cmd/mixnet-proxy/main.go, Config has MixnetGateway/WireGuardIface/
AntNodeAddr), not a thinclient one. It must be replaced.

## 3. Architecture
app -> SOCKS5 127.0.0.1:1080 (new mixnet-proxy)
    -> per-connection pigeonhole stream (thinclient, v0.0.84-compatible)
    -> mixnet (gateway 127.0.0.1:30004) -> servicenode courier
    -> NEW tcp service (pigeonhole service / cborplugin style)
    -> dial host:port -> cleartext TCP

Stream protocol (minimal framing on top of pigeonhole stream bytes):
1. Client sends CONNECT <host> <port>\r\n (SOCKS5-style, unauthenticated), waits for
   OK\r\n or ERR <reason>\r\n.
2. On OK: raw bidirectional byte relay, chunked at copy_stream size.
3. On client EOF: sends CLOSE, server closes TCP. On server EOF: server sends CLOSE,
   client closes SOCKS5 connection.

## 4. Work items (after approval)
A. Mixnet changes (required):
1. Start the 5 replicas. Build replica (Dockerfile.mixnet-native already compiles it into
   the loop; or Dockerfile.replica). Add 5 replica services to compose (image with replica,
   each with config/mixnet/replica{i}/replica.toml, host network). Verify courier log shows
   replica dispatch succeeding.
2. New servicenode tcp service. A binary registered like the existing Kaetzchen plugins
   (CBORPluginKaetzchen in katzenpost.toml), reads CONNECT, dials, relays via copy_stream.
   Modeled on pigeonhole/copy_stream.go (main) + courier/server/plugin.go + branch
   add_bacap_scratch_stream cmd/katzencopy + cmd/katzencat. Build & deploy a new
   zeros/mixnet-node:arm64 image containing it.

B. Client changes:
3. New SOCKS5+thinclient binary in cmd/mixnet-proxy (replaces WG-based main.go). Uses
   thinclient at the deployed protocol surface (NewKeypair/EncryptRead/EncryptWrite +
   WriteStream/ReadStream). One stream per SOCKS5 connection; handshake + relay per 3.
4. Rebuild zeros/mixnet-proxy:arm64; update config/proxy/config.json to point at
   thinclient config. (SOCKS5 already listens 0.0.0.0:1080.)

C. Verify:
5. curl -x socks5h://127.0.0.1:1080 https://ethereum-rpc.publicnode.com + eth_chainId, a
   large response (block header) to prove streaming beyond 2KB, and wget of a several-MB
   file (chunked streaming).

## 5. Risks / open questions
- Replica start is mandatory; if it fails, pigeonhole never delivers. Backfill/replication
  configs are pre-generated in PKI so this should be a pure bring-up.
- v0.0.84 WriteStream/ReadStream semantics (SACK/ARQ) need a live proof before building
  the relay; fallback is message-based chunking over EncryptWrite (walletshield-style)
  which works today but is slower.
- ant-node P2P QUIC stays direct - not tunnelable (no QUIC-over-mixnet; mixnet is
  message-based). This proxy serves TCP apps only.

## 6. Other state (not part of this spec)
- USB SSD auto-mount on boot verified (fstab + /mnt/usb_sda3).
- antd container relocated to USB: data at /mnt/usb_sda3/antd-data/{node-1,logs},
  compose bind mounts added, ant-node running from USB, root disk freed to 70%.
