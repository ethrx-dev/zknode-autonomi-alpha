#!/bin/bash
set -euo pipefail
# state.sh — node state lifecycle: export | backup | restore
#
# Model: "topology in git, state on device, secrets in encrypted backup".
#   export   — snapshot LIVE config (compose + mixnet99 tomls + small live
#              configs) into the repo working tree, so git matches reality
#   backup   — encrypted bundle of irreplaceable state (keys, identities)
#              to /mnt/autonomi/backup (age if available, else openssl)
#   restore  — guarded decrypt + extract of a state bundle (disaster recovery)
#
# Runs ON the node (same model as deploy.sh). Backup/restore never touch
# running containers; they only read/write files under config/.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BACKUP_DIR="${BACKUP_DIR:-/mnt/autonomi/backup}"
BACKUP_KEYFILE="${BACKUP_KEYFILE:-}"

# Live config snapshot targets (relative to PROJECT_ROOT)
LIVE_COMPOSE="docker-compose.yml"
LIVE_MIXNET_DIR="config/mixnet99"
LIVE_EXTRA="config/proxy/config.json"

# Backup content: irreplaceable state only (runtime caches/logs excluded)
BACKUP_INCLUDES=(
  "config/mixnet99"
)
BACKUP_EXCLUDES=(
  "--exclude=*.log" "--exclude=*.db" "--exclude=*.sst"
  "--exclude=management_sock" "--exclude=*.sock" "--exclude=*.tmp"
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
step()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[x]${NC} $1"; }
info()  { echo -e "${CYAN}[i]${NC} $1"; }

require_keyfile() {
  if [ -z "$BACKUP_KEYFILE" ]; then
    err "BACKUP_KEYFILE is required (path to a file holding the encryption key/passphrase)"
    err "  e.g. BACKUP_KEYFILE=/root/.zknode-state-key $0 backup"
    exit 1
  fi
  [ -f "$BACKUP_KEYFILE" ] || { err "keyfile not found: $BACKUP_KEYFILE"; exit 1; }
}

encrypt() { # stdin -> encrypted stdout
  if command -v age >/dev/null 2>&1; then
    age -R "$BACKUP_KEYFILE"
  else
    openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:$BACKUP_KEYFILE"
  fi
}

decrypt() { # $1 = encrypted file -> plaintext stdout
  if head -c 16 "$1" 2>/dev/null | grep -q "age-encryption" && command -v age >/dev/null 2>&1; then
    age -d -i "$BACKUP_KEYFILE" < "$1"
  else
    openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:$BACKUP_KEYFILE" < "$1"
  fi
}

# ─── export: snapshot live config into the repo working tree ───
cmd_export() {
  local failed=0
  info "exporting live topology into repo working tree (read-only on the node)"

  # 1) compose file — the topology wiring itself
  if [ -f "$PROJECT_ROOT/$LIVE_COMPOSE" ]; then
    step "compose present: $LIVE_COMPOSE ($(wc -l < "$PROJECT_ROOT/$LIVE_COMPOSE") lines)"
  else
    err "compose not found: $LIVE_COMPOSE"; failed=1
  fi

  # 2) mixnet99 tomls — if absent from the tree, this node has no live
  #    mixnet config (fresh node) — warn rather than fail
  if [ -d "$PROJECT_ROOT/$LIVE_MIXNET_DIR" ]; then
    local n; n=$(find "$PROJECT_ROOT/$LIVE_MIXNET_DIR" -name '*.toml' 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
      step "mixnet topology: $n toml files under $LIVE_MIXNET_DIR"
    else
      warn "no toml files under $LIVE_MIXNET_DIR — run genconfig or copy from a reference node"
      failed=1
    fi
  else
    warn "$LIVE_MIXNET_DIR missing — live topology not yet exported on this node"
    failed=1
  fi

  # 3) extra live configs
  for f in $LIVE_EXTRA; do
    if [ -f "$PROJECT_ROOT/$f" ]; then step "extra config: $f"; else warn "missing: $f"; fi
  done

  # 4) drift report vs HEAD (informational; export does not auto-commit)
  if git -C "$PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    local dirty; dirty=$(git -C "$PROJECT_ROOT" status --porcelain -- config/ docker-compose.yml | wc -l)
    if [ "$dirty" -gt 0 ]; then
      warn "$dirty config/topology files differ from git HEAD — review with: git -C $PROJECT_ROOT diff --stat -- config/ docker-compose.yml"
    else
      step "config/ + compose match git HEAD (no drift)"
    fi
  fi

  # 5) container-mounted configs match the checkout (mounted-source drift)
  local n=0
  [ -d "$PROJECT_ROOT/$LIVE_MIXNET_DIR" ] && n=$(find "$PROJECT_ROOT/$LIVE_MIXNET_DIR" -name '*.toml' 2>/dev/null | wc -l)
  if command -v docker >/dev/null 2>&1 && [ "$n" -gt 0 ]; then
    local c h cm hm mismatches=0
    for pair in \
      "mix-client:/var/lib/katzenpost/client/client.toml:$LIVE_MIXNET_DIR/client/client.toml" \
      "mix-gateway:/var/lib/katzenpost/gateway1/katzenpost.toml:$LIVE_MIXNET_DIR/gateway1/katzenpost.toml" \
      "mix-servicenode:/var/lib/katzenpost/servicenode1/katzenpost.toml:$LIVE_MIXNET_DIR/servicenode1/katzenpost.toml" \
      "mix-dirauth-1:/var/lib/katzenpost/auth1/authority.toml:$LIVE_MIXNET_DIR/auth1/authority.toml"; do
      c="${pair%%:*}"; rest="${pair#*:}"; h="${rest%%:*}"; cm="${rest#*:}"
      [ -f "$PROJECT_ROOT/$cm" ] || { warn "no repo copy to verify: $cm"; continue; }
      hm=$(md5sum "$PROJECT_ROOT/$cm" | awk '{print $1}')
      cm=$(docker exec "$c" md5sum "$h" 2>/dev/null | awk '{print $1}' || true)
      if [ -z "$cm" ]; then warn "container $c not running or path missing ($h)"; continue; fi
      if [ "$hm" = "$cm" ]; then step "mounted config matches repo: $c $h"
      else err "MOUNTED CONFIG DRIFT: $c $h (container $cm != repo $hm)"; mismatches=$((mismatches+1)); fi
    done
    [ "$mismatches" -eq 0 ] || failed=1
  fi

  [ "$failed" -eq 0 ] && step "export check complete" || { err "export check found problems"; exit 1; }
}

# ─── backup: encrypted state bundle ───
cmd_backup() {
  require_keyfile
  [ -d "$PROJECT_ROOT/config/mixnet99" ] || { err "no state dir: config/mixnet99"; exit 1; }
  mkdir -p "$BACKUP_DIR"
  local ts bundle
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  bundle="$BACKUP_DIR/zknode-state-$ts.tar.gz.enc"
  info "backing up state (tomls + keys + identities, excluding runtime caches)"
  tar -C "$PROJECT_ROOT" "${BACKUP_EXCLUDES[@]}" -czf - "${BACKUP_INCLUDES[@]}" "$LIVE_EXTRA" 2>/dev/null | encrypt > "$bundle"
  chmod 600 "$bundle"
  sha256sum "$bundle" > "$bundle.sha256"
  local size; size=$(du -h "$bundle" | cut -f1)
  step "bundle: $bundle ($size)"
  step "sha256 sidecar: $bundle.sha256"
  # retention: keep the 8 most recent bundles
  local old
  ls -1t "$BACKUP_DIR"/zknode-state-*.tar.gz.enc 2>/dev/null | tail -n +9 | while read -r old; do
    rm -f "$old" "$old.sha256" && info "pruned old bundle: $(basename "$old")"
  done
}

# ─── restore: guarded decrypt + extract ───
cmd_restore() {
  require_keyfile
  local bundle="${1:-}"
  [ -n "$bundle" ] || { err "usage: $0 restore <bundle.tar.gz.enc> [--force]"; exit 1; }
  local force=false; [ "${2:-}" = "--force" ] && force=true
  [ -f "$bundle" ] || { err "bundle not found: $bundle"; exit 1; }
  [ -f "$bundle.sha256" ] && { sha256sum -c "$bundle.sha256" >/dev/null 2>&1 && step "bundle checksum OK" || { err "bundle checksum MISMATCH"; exit 1; }; }

  local tmp; tmp=$(mktemp -d)
  if ! decrypt "$bundle" | tar -C "$tmp" -xzf - 2>/dev/null; then
    err "decrypt/extract failed (wrong keyfile?)"; rm -rf "$tmp"; exit 1
  fi
  info "bundle contents:"
  (cd "$tmp" && find . -type f | sed 's|^\./|    |' | head -20)
  local nf; nf=$(cd "$tmp" && find . -type f | wc -l)
  info "total files: $nf"

  if [ "$force" = false ]; then
    if [ -e "$PROJECT_ROOT/config/mixnet99/identity" ] || [ -e "$PROJECT_ROOT/config/mixnet99/auth1/identity.private.pem" ] \
       || [ "$(find "$PROJECT_ROOT/config/mixnet99" -name '*.pem' 2>/dev/null | head -1)" ]; then
      err "existing state detected — refusing to overwrite. Re-run with --force to replace."
      rm -rf "$tmp"; exit 1
    fi
  fi

  rm -rf "$PROJECT_ROOT/config/mixnet99"
  cp -a "$tmp/config/mixnet99" "$PROJECT_ROOT/config/" 2>/dev/null || mv "$tmp/config/mixnet99" "$PROJECT_ROOT/config/"
  if [ -f "$tmp/$LIVE_EXTRA" ]; then
    mkdir -p "$(dirname "$PROJECT_ROOT/$LIVE_EXTRA")"
    cp -a "$tmp/$LIVE_EXTRA" "$PROJECT_ROOT/$LIVE_EXTRA"
  fi
  rm -rf "$tmp"
  step "state restored into $PROJECT_ROOT/config/mixnet99"
  warn "restart the mixnet stack (deploy.sh --group 1..5) so nodes load the restored keys"
}

case "${1:-}" in
  export)  shift || true; cmd_export "$@" ;;
  backup)  shift || true; cmd_backup "$@" ;;
  restore) shift || true; cmd_restore "$@" ;;
  --help|-h|*)
    cat <<EOF
Usage: $0 <command> [args]

  export                 snapshot live topology/compose into repo tree + drift check (read-only)
  backup                 create encrypted state bundle in $BACKUP_DIR
                         (env: BACKUP_KEYFILE=<file> required; BACKUP_DIR override)
  restore <bundle> [--force]
                         restore a state bundle (refuses to overwrite existing keys)

Encryption: age if installed (BACKUP_KEYFILE = recipient file), else openssl
AES-256-CBC+PBKDF2 (BACKUP_KEYFILE = passphrase file).
EOF
    ;;
esac
