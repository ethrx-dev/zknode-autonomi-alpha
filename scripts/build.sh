#!/bin/bash
set -euo pipefail
# build.sh — canonical multi-arch image builder for zknode-autonomi
#
# Usage:
#   ./scripts/build.sh                 # build for this host's arch (fast local)
#   ./scripts/build.sh --both          # build amd64 + arm64 tags locally
#   ./scripts/build.sh --multiarch     # buildx multi-platform manifest (push)
#   ./scripts/build.sh --push          # with --multiarch: push to $REGISTRY
#
# Canonical image map (one Dockerfile per image; no more variant sprawl):
#   mixnet-node     <- Dockerfile.mixnet        (all katzenpost binaries)
#   walletshield    <- Dockerfile.walletshield  (from repo source)
#   mixnet-proxy    <- Dockerfile.mixnet-proxy
#   ant-node        <- Dockerfile.ant-node
#   antd            <- Dockerfile.antd
#   storage-proved  <- Dockerfile.storage-proved-rs
#   dashboard       <- Dockerfile in zknode-dashboard/ (if present)

cd "$(cd "$(dirname "$0")/.." && pwd)"
HOST_ARCH="$(docker version --format '{{.Architecture}}' | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
MODE="host"; PUSH=false; REGISTRY="${REGISTRY:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --both)      MODE="both" ;;
    --multiarch) MODE="multiarch" ;;
    --push)      PUSH=true ;;
    *) echo "unknown flag: $1"; exit 2 ;;
  esac; shift
done

build_host() { # $1=ARCH $2=dockerfile $3=tag
  docker build -f "$2" --build-arg TARGETARCH="$1" -t "$3" . \
    && echo "  [built] $3"
}
build_multi() { # $1=dockerfile $2=tag (no arch suffix)
  if [ "$PUSH" = true ]; then
    docker buildx build -f "$1" --platform linux/amd64,linux/arm64 -t "$2" --push .
  else
    echo "  [multiarch manifests require --push; use --both for local per-arch tags]"
    return 1
  fi
}

tag_for() { # $1=base-name $2=arch -> zeros/name:arch or registry/name:arch
  local prefix="zeros/"
  [ -n "$REGISTRY" ] && prefix="$REGISTRY/"
  echo "${prefix}$1:$2"
}

IMAGES=(
  "mixnet-node|Dockerfile.mixnet"
  "walletshield|Dockerfile.walletshield"
  "mixnet-proxy|Dockerfile.mixnet-proxy"
  "ant-node|Dockerfile.ant-node"
  "antd|Dockerfile.antd"
  "storage-proved|Dockerfile.storage-proved-rs"
)

fail=0
for entry in "${IMAGES[@]}"; do
  name="${entry%%|*}"; dockerfile="${entry##*|}"
  [ -f "$dockerfile" ] || { echo "SKIP (no $dockerfile): $name"; continue; }
  case "$MODE" in
    host)
      build_host "$HOST_ARCH" "$dockerfile" "$(tag_for "$name" "$HOST_ARCH")" || fail=1 ;;
    both)
      build_host amd64 "$dockerfile" "$(tag_for "$name" amd64)" || fail=1
      build_host arm64 "$dockerfile" "$(tag_for "$name" arm64)" || fail=1 ;;
    multiarch)
      t="$(tag_for "$name" latest)"
      build_multi "$dockerfile" "$t" || fail=1 ;;
  esac
done

exit $fail
