#!/bin/bash
set -euo pipefail

# upgrade-node.sh — choose and apply a zknode-autonomi architecture on a node.
# A node (SCM4 or mesh box) can run one of three architectures; this script
# detects the current deployment, asks which one to target, and applies the
# matching path using the canonical repo tooling (gen-mixnet99.sh, deploy.sh).
#
#   Option 1 — Full local PoC      : whole mixnet on the box, local dashboard
#   Option 2 — VPS-client          : local mixnet retired; box is a thin
#                                    client (kpclient-vps) dialing the VPS
#                                    gateway; dashboard is VPS-aware (main)
#   Option 3 — Hybrid (RECOMMENDED): main code + Pigeonhole replicas + RNS,
#                                    but KEEP the box's local-topology
#                                    dashboard  (dirauth_consensus / mix_nodes)
#
# Non-interactive:  UPGRADE_MODE=1|2|3 ./scripts/upgrade-node.sh --run
# Answers: the user is prompted where the script needs facts. Most inputs can
# be pre-supplied as environment variables (see INPUTS below).
#
# Inputs (env vars, all optional — prompted when missing):
#   UPGRADE_MODE          1|2|3  (skip the menu)
#   REPO_URL              git URL to upgrade from (default: the origin of the
#                         running checkout if present, else the zknet repo)
#   REPO_REF              branch/tag to check out (default: main)
#   DASHBOARD_IMAGE       image:tag of the LOCAL-topology dashboard to keep for
#                         Option 1/3 (default: auto-detect the currently
#                         running dashboard image on the box)
#   MIXNET_IMAGE          image:tag for the mixnet node (default: mixnet-node)
#   VPS_GATEWAY_ADDR      gateway to dial for Option 2 (default
#                         tcp://<VPS_PUBLIC_IP>:30007 if VPS_PUBLIC_IP set,
#                         else prompts)
#   VPS_PUBLIC_IP         public IP of the Option-2 mixnet gateway
#   BACKUP_DIR            where the pre-upgrade runtime tarball goes
#                         (default: ./upgrade-backup-<date>)
#   SKIP_BACKUP=1         skip the runtime tarball
#   SKIP_GIT=1            do not clone/check out; use the current repo tree
#   DRY_RUN=1             print the plan for the chosen option and exit

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

step() { echo -e "[+] $1"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
err()  { echo -e "${RED}[x] $1${NC}"; }
ok()   { echo -e "${GREEN}[ok]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

declare -A ARCH_NAMES=([1]="Full local PoC" [2]="VPS-client" [3]="Hybrid (recommended)")
declare -A ARCH_NICKS=([1]="local-poc" [2]="vps-client" [3]="hybrid")
declare -A ARCH_DOC=(
  [1]="docs/ARCHITECTURE_OPTIONS.md (Option 1)"
  [2]="docs/ARCHITECTURE_OPTIONS.md (Option 2), AGENTS.md 'VPS Mixnet Deployment'"
  [3]="docs/ARCHITECTURE_OPTIONS.md (Option 3), AGENTS.md 'SCM4 Architecture Options'"
)

# ─── helpers ────────────────────────────────────────────────────────────────

has_docker()  { command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }
next_epoch_utc() {
  # next katzenpost epoch boundary (:00/:20/:40 UTC) as YYYY-MM-DD HH:MM:SS
  local now next
  now=$(date -u +%s)
  next=$(( (now / 1200) * 1200 + 1200 ))
  date -u -d "@$next" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date -ud "@$next" +"%Y-%m-%d %H:%M:%S"
}
running_image_id() { docker inspect "$1" --format '{{.Image}}' 2>/dev/null || true; }
local_dashboard_image() {
  # the currently running dashboard image (what the box actually deploys) —
  # the LOCAL build checks dirauth_consensus/mix_nodes and must be kept for
  # Option 1/3 (never main's VPS-aware dashboard). Prefer DASHBOARD_IMAGE.
  [ -n "${DASHBOARD_IMAGE:-}" ] && { echo "$DASHBOARD_IMAGE"; return 0; }
  local tag
  tag=$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null | awk -F'\t' '$1=="zknode-dashboard"{print $2}' | head -1)
  [ -n "$tag" ] && { echo "$tag"; return 0; }
  docker inspect zknode-dashboard --format '{{.Image}}' 2>/dev/null || true
}

ask() { # ask <var> <prompt> [default]
  local var="$1" prompt="$2" def="${3:-}"
  if [ -z "${!var:-}" ]; then
    if [ -n "$def" ]; then
      read -r -p "  $prompt [$def]: " ans
      eval "$var=\"${ans:-$def}\""
    else
      read -r -p "  $prompt: " ans
      eval "$var=\"$ans\""
    fi
  fi
}

# ─── preflight ──────────────────────────────────────────────────────────────

guard_golden_rule() {
  # never intervene during an I/O storm (golden rule from the watchdog)
  local load iowait
  load=$(awk '{print $1}' /proc/loadavg 2>/dev/null | cut -d. -f1)
  iowait=$(awk 'NR==1{print $5}' /proc/stat 2>/dev/null) # single sample; watchdog is authoritative
  load=${load:-0}
  if [ "$load" -ge 25 ]; then
    err "system load $load >= 25 (golden rule) — deferring upgrade. Aborting."
    exit 1
  fi
  echo "  load $(awk '{print $1; exit}' /proc/loadavg)"
}

backup_runtime() {
  [ -n "${SKIP_BACKUP:-}" ] && { warn "SKIP_BACKUP set — skipping runtime backup"; return 0; }
  local dest="${BACKUP_DIR:-$PROJECT_ROOT/upgrade-backup-$(date +%Y%m%d-%H%M%S)}"
  mkdir -p "$dest"
  step "backing up runtime to $dest"
  # running container snapshot
  docker ps --format '{{.Names}}|{{.Image}}|{{.Status}}' > "$dest/containers-before.txt" 2>/dev/null || true
  docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | sort > "$dest/images-before.txt" 2>/dev/null || true
  # runtime state dirs (keys, DBs, configs) — exclude provenance-less churn
  for d in config/mixnet99 config/mixnet config/reticulum config/nomadnet data .env; do
    [ -e "$d" ] && tar czf "$dest/$(basename "$d").tgz" "$d" 2>/dev/null || warn "no $d to back up"
  done
  ok "runtime backed up: $dest"
}

# ─── option-specific apply steps ────────────────────────────────────────────

apply_option1_local() {
  step "applying Option 1 — full local PoC (self-contained mixnet + local dashboard)"
  # topology: 3 dirauth, 3 mix, gateway, servicenode, client, proxy — replicas optional
  if [ -d config/mixnet99 ]; then
    warn "config/mixnet99 exists — keeping it (delete it to regenerate with gen-mixnet99.sh)"
  else
    MIXNET_IMAGE="${MIXNET_IMAGE:-zeros/mixnet-node:arm64}"
    sudo bash "$SCRIPT_DIR/gen-mixnet99.sh" "$MIXNET_IMAGE" config/mixnet99
  fi
  # ensure the loopback thin client bind (genconfig writes hostname/::1 sometimes)
  sudo sed -i 's|Address = "localhost:64331"|Address = "127.0.0.1:64331"|' \
    config/mixnet99/client/thinclient.toml 2>/dev/null || true
  # dashboard: keep LOCAL build (Option 1/3) — never main's VPS-aware code
  DI="$(local_dashboard_image)"
  if [ -n "$DI" ]; then
    step "pinning dashboard to local build: $DI"
    sed -i "s|^IMAGE_DASHBOARD=.*|IMAGE_DASHBOARD=$DI|" .env 2>/dev/null || true
    grep -q 'IMAGE_DASHBOARD' .env || echo "IMAGE_DASHBOARD=$DI" >> .env
  else
    warn "no running dashboard detected — leaving IMAGE_DASHBOARD from .env"
  fi
}

apply_option2_vpsclient() {
  step "applying Option 2 — VPS-client (box is a thin client to the VPS gateway)"
  # The canonical client daemon config ships in the repo; make a node-specific
  # copy with the real gateway address (NOT the repo's example IP when it is a
  # placeholder for that box).
  mkdir -p config/mixnet/client
  if [ ! -f config/mixnet/client/client-vps.toml ]; then
    err "config/mixnet/client/client-vps.toml missing from repo (Option 2 needs it)"
    exit 1
  fi
  if [ -z "${VPS_PUBLIC_IP:-}" ]; then
    ask VPS_PUBLIC_IP "public IP of the VPS mixnet gateway"
  fi
  VPS_GATEWAY_ADDR="${VPS_GATEWAY_ADDR:-tcp://${VPS_PUBLIC_IP}:30007}"
  step "pinning gateway -> $VPS_GATEWAY_ADDR"
  cp config/mixnet/client/client-vps.toml config/mixnet/client/client-vps.toml.bak
  sed -i -E "s#tcp://([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):30007#$VPS_GATEWAY_ADDR#" \
    config/mixnet/client/client-vps.toml
  # stop/retire a local mixnet if present so the box does not double-route
  if docker ps --format '{{.Names}}' | grep -qE '^(mix-dirauth-1|mix-1|mix-client)$'; then
    warn "local mixnet detected — retiring it for Option 2"
    docker compose stop mix-dirauth-1 mix-dirauth-2 mix-dirauth-3 \
      mix-1 mix-2 mix-3 mix-gateway mix-servicenode mix-client 2>/dev/null || true
  fi
  # dashboard: main's VPS-aware code is correct here (no local pin needed)
}

apply_option3_hybrid() {
  step "applying Option 3 — hybrid (main features + local dashboard)"
  apply_option1_local        # local topology incl. Pigeonhole replicas + RNS
  # hybrid runs the FULL main compose (replicas, RNS 1.3.7) — gen-mixnet99.sh
  # already produces --storageNodes 5, so nothing extra beyond option 1.
  ok "hybrid profile applied (local dashboard pinned, Pigeonhole replicas present)"
}

verify_deploy() {
  step "verifying deployment"
  local mode="${1:-}"
  case "$mode" in
    1|3)
      sleep 5
      echo "  <- dirauth consensus: $(docker exec mix-dirauth-1 grep -acE 'Achieved threshold|SUCCESS' /var/lib/katzenpost/auth1/katzenpost.log 2>/dev/null || echo 'n/a (container not up yet)')"
      echo "  <- walletshield /ethereum:" "$(curl -s -m 20 -X POST http://127.0.0.1:9200/ethereum \
            -H 'Content-Type: application/json' \
            -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' 2>/dev/null | head -c 120)"
      ;;
    2)
      echo "  <- kpclient-vps: $(docker inspect -f '{{.State.Status}}' kpclient-vps 2>/dev/null || echo 'not created yet')"
      echo "  <- mixnet-proxy: $(docker inspect -f '{{.State.Status}}' mixnet-proxy 2>/dev/null || echo 'not created yet')"
      ;;
  esac
  echo ""
  echo "  NEXT: full checks -> bash scripts/monitor.sh ; dashboard -> your box IP:8080"
  echo "  PLANNED RESTART -> align mixnet restarts to the next epoch boundary: $(next_epoch_utc) UTC"
}

# ─── entrypoint ─────────────────────────────────────────────────────────────

banner() {
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║      zknode-autonomi — Node Upgrade          ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
}

usage() {
  echo "Usage: ./scripts/upgrade-node.sh [--run]"
  echo ""
  echo "  (no args)          interactive: detect state, show menu, apply"
  echo "  --run              non-interactive (uses UPGRADE_MODE=1|2|3)"
  echo "  --detect           print the detected architecture and exit"
  echo "  --help             this help"
  echo ""
  echo "Env inputs: UPGRADE_MODE REPO_URL REPO_REF DASHBOARD_IMAGE MIXNET_IMAGE"
  echo "            VPS_GATEWAY_ADDR VPS_PUBLIC_IP BACKUP_DIR SKIP_BACKUP SKIP_GIT DRY_RUN"
  exit 0
}

detect_arch() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^(mix-dirauth-1|mix-1|mix-servicenode)$'; then
    echo "local-mixnet (Option 1/3 basis)"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^kpclient-vps$'; then
    echo "vps-client (Option 2 basis)"
  elif docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -qE 'mixnet-node'; then
    echo "images-present-but-no-fleet (fresh upgrade)"
  else
    echo "unknown (fresh box)"
  fi
}

menu() {
  echo "Detected current deployment: $(detect_arch)"
  echo ""
  echo "Choose the target architecture:"
  echo "   1. Full local PoC   — mixnet self-hosted on this box, local dashboard"
  echo "   2. VPS-client       — thin client to the VPS gateway (light footprint)"
  echo "   3. Hybrid           — RECOMMENDED: latest repo features + local dashboard"
  ask UPGRADE_MODE "select option" 3
}

# ─── run ────────────────────────────────────────────────────────────────────

case "${1:-}" in
  --help|-h) usage ;;
  --detect)  detect_arch; exit 0 ;;
esac

banner
guard_golden_rule

RUN_NONINTERACTIVE="${1:-}"
case "$RUN_NONINTERACTIVE" in
  --run)
    [ -n "${UPGRADE_MODE:-}" ] || { err "UPGRADE_MODE=1|2|3 required with --run"; exit 1; }
    ;;
  "")
    menu
    ;;
  *)
    usage
    ;;
esac

case "$UPGRADE_MODE" in
  1|2|3) ;;
  *) err "UPGRADE_MODE must be 1|2|3 (got: $UPGRADE_MODE)"; exit 1 ;;
esac

echo ""
step "target: Option $UPGRADE_MODE — ${ARCH_NAMES[$UPGRADE_MODE]}"
echo "  ${ARCH_DOC[$UPGRADE_MODE]}"

if [ -n "${DRY_RUN:-}" ]; then
  echo "  DRY_RUN set — plan above; nothing applied."
  exit 0
fi

# repo source
if [ -z "${SKIP_GIT:-}" ]; then
  REPO_URL="${REPO_URL:-$(git config --get remote.origin.url 2>/dev/null || true)}"
  REPO_URL="${REPO_URL:-https://github.com/ethrx-dev/zknode-autonomi-alpha.git}"
  REPO_REF="${REPO_REF:-main}"
  step "fetching $REPO_URL @ $REPO_REF"
  git fetch --all --tags 2>/dev/null || { warn "fetch failed (offline?) — continuing with current tree"; }
  git checkout "$REPO_REF" 2>/dev/null || git pull --ff-only origin "$REPO_REF" 2>/dev/null || \
    { err "cannot reach $REPO_REF in this tree; use SKIP_GIT=1 to keep the current tree"; exit 1; }
fi

[ -f .env ] && { set -a; source .env; set +a; }
has_docker || { err "docker + compose v2 required"; exit 1; }

backup_runtime

case "$UPGRADE_MODE" in
  1) apply_option1_local ;;
  2) apply_option2_vpsclient ;;
  3) apply_option3_hybrid ;;
esac

step "deploying (see scripts/deploy.sh --start or docker compose up -d)"
if command -v bash >/dev/null && [ -x "$SCRIPT_DIR/deploy.sh" ]; then
  bash "$SCRIPT_DIR/deploy.sh" --start
else
  warn "deploy.sh unavailable — run docker compose up -d yourself"
fi

verify_deploy "$UPGRADE_MODE"

step "UPGRADE COMPLETE — restart mixnet nodes only at epoch boundaries (:00/:20/:40 UTC); next $(next_epoch_utc)"