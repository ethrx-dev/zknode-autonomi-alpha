#!/bin/bash
set -euo pipefail
# gen-mixnet99.sh — generate a fresh, deployment-ready Katzenpost v0.0.99
# topology (config/mixnet99) using the genconfig binary from the built
# mixnet image, then apply every post-generation fix the mixnet needs.
#
# Validated locally (2026-09-09): generated fleet reached PKI consensus,
# 3-hop echo round-trip 5/5, and walletshield /ethereum E2E 200 (chainId
# 0x1) — see the v0.2 consolidation notes.
#
# Post-generation fixes encoded here (each was a real fresh-deploy failure):
#   1. servicenode plugin Commands point at image paths
#      (/usr/local/bin/courier, /usr/local/bin/http-proxy-server)
#   2. http plugin allowed host defaults to * (walletshield enforces its own)
#   3. courier plugin config path made absolute (relative path = silent
#      plugin death = "dial unix: missing address" panic on servicenode)
#   4. ALL node directories chmod 700 (katzenpost hard requirement — nested
#      plugin dirs too, not just the top level)
#   5. client/thinclient.toml binds 127.0.0.1 (localhost resolves ::1 first
#      and the daemon listens on IPv4)
#   6. generated docker-compose.yml inside the tree: binary + config paths
#      fixed (reference only — the repo compose is authoritative)
#
# Usage: sudo ./scripts/gen-mixnet99.sh [IMAGE_MIXNET] [OUTDIR]
#   IMAGE_MIXNET defaults to zeros/mixnet-node:arm64 (override for amd64)

IMAGE_MIXNET="${1:-zeros/mixnet-node:arm64}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="${2:-$PROJECT_ROOT/config/mixnet99}"

# Topology parameters (match the fleet: 3 authorities, 3 mixes in 1 layer
# topology of 3, 1 gateway, 1 service node, 3 voting authorities)
GEN_ARGS=(--voting --wirekem MLKEM768 --nike x25519 --layers 3 --nodes 3
  --gateways 1 --serviceNodes 1 --nrVoting 3
  --baseDir /var/lib/katzenpost
  --dockerImage "$IMAGE_MIXNET" --noMetrics)

step()  { echo -e "[+] $1"; }
warn()  { echo -e "[!] $1"; }
err()   { echo -e "[x] $1"; }

command -v docker >/dev/null 2>&1 || { err "docker required"; exit 1; }
[ "$(uname -m)" = "x86_64" ] || [ "$(uname -m)" = "aarch64" ] || { err "unsupported arch $(uname -m)"; exit 1; }
docker image inspect "$IMAGE_MIXNET" >/dev/null 2>&1 || { err "image not found: $IMAGE_MIXNET (build with scripts/build.sh)"; exit 1; }

if [ -e "$OUTDIR" ]; then
  warn "output dir exists: $OUTDIR — refusing to overwrite keys/configs"
  err "move it aside or pass a different OUTDIR"
  exit 1
fi
mkdir -p "$OUTDIR"

step "generating topology into $OUTDIR (image: $IMAGE_MIXNET)"
docker run --rm -v "$OUTDIR:/out" "$IMAGE_MIXNET" \
  genconfig "${GEN_ARGS[@]}" --outDir /out >/dev/null

SN_TOML="$OUTDIR/servicenode1/katzenpost.toml"
[ -f "$SN_TOML" ] || { err "genconfig output missing servicenode1/katzenpost.toml"; exit 1; }

step "fixing servicenode plugin Commands (image paths)"
sed -i \
  -e 's|Command = "/var/lib/katzenpost/courier"|Command = "/usr/local/bin/courier"|' \
  -e 's|Command = "/var/lib/katzenpost/proxy_server"|Command = "/usr/local/bin/http-proxy-server"|' \
  -e 's|host = "localhost:4242"|host = "*"|' \
  "$SN_TOML"
# make the courier plugin config path absolute (fix 3)
sed -i 's|c = "courier.toml"|c = "/var/lib/katzenpost/servicenode1/courier/courier.toml"|' "$SN_TOML"

step "fixing thinclient bind (127.0.0.1, fix 5)"
[ -f "$OUTDIR/client/thinclient.toml" ] && \
  sed -i 's|Address = "localhost:64331"|Address = "127.0.0.1:64331"|' "$OUTDIR/client/thinclient.toml"

step "fixing generated compose paths (reference only, fix 6)"
if [ -f "$OUTDIR/docker-compose.yml" ]; then
  sed -i \
    -e 's|/var/lib/katzenpost/dirauth|dirauth|g' \
    -e 's|/var/lib/katzenpost/server|server|g' \
    -e 's|/var/lib/katzenpost/kpclientd|kpclientd|g' \
    -e 's|command: /var/lib/katzenpost/replica -f /var/lib/katzenpost/|command: replica -f /var/lib/katzenpost/|g' \
    "$OUTDIR/docker-compose.yml"
fi

step "permissions: node dirs 700, tree traversable (fix 4)"
chmod 755 "$OUTDIR"
find "$OUTDIR" -mindepth 1 -type d -exec chmod 700 {} \;
[ -f "$OUTDIR/docker-compose.yml" ] && chmod 644 "$OUTDIR/docker-compose.yml"

step "generated topology summary"
echo "    $(find "$OUTDIR" -name '*.toml' | wc -l) toml files, nodes:"
for d in auth1 auth2 auth3 mix1 mix2 mix3 gateway1 servicenode1 client; do
  [ -d "$OUTDIR/$d" ] && printf '      %s\n' "$d"
done
step "DONE — config/mixnet99 ready. Deploy with the repo compose (services mount ./config/mixnet99)."
step "RESTART RULE: restart nodes only at epoch boundaries (:00/:20/:40 UTC) —"
step "  mid-epoch restarts regenerate mix keys and invalidate the current doc."
