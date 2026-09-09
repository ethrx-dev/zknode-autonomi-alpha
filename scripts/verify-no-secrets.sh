#!/bin/bash
set -euo pipefail

# verify-no-secrets.sh — fail if private keys, private identities, or runtime
# state are tracked. Run before every push; deploy.sh --check enforces it.
# NOTE: config/mixnet/**/identity.public.pem / link.public.pem / *.pub are
# PUBLIC key material and legitimately tracked in this repo.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
issues=0

fail() { echo -e "  ${RED}[x] $1${NC}"; issues=$((issues+1)); }
ok()   { echo -e "  ${GREEN}[+] $1${NC}"; }

echo "=== Secret scan (tracked files + git history) ==="

# 1. No PRIVATE key PEM blocks in tracked files (public PEMs are allowed)
if git grep -IE '-----BEGIN [A-Z ]*PRIVATE KEY-----' -- . 2>/dev/null | grep -q .; then
    fail "private key PEM block found in tracked files:"
    git grep -lE '-----BEGIN [A-Z ]*PRIVATE KEY-----' -- . | head -5
else
    ok "no private key PEMs in tracked files"
fi

# 2. No PRIVATE key PEM blocks anywhere in history
found_hist=0
while read -r c; do
    if git grep -qE '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$c" -- . 2>/dev/null; then
        found_hist=1; break
    fi
done < <(git rev-list --all 2>/dev/null)
if [ "$found_hist" = "1" ]; then
    fail "private key PEM block found in git history"
else
    ok "no private key PEMs in git history"
fi

# 3. Private identity / runtime-state paths must not be tracked
for p in \
    "config/mixnet/client/.zkchat" \
    "config/nomadnet/storage" \
    "config/reticulum/config/storage" \
    "config/reticulum/storage" \
    "config/x0x/identity" \
    "config/mixnet/**/identity.pem" \
    "config/mixnet/**/link.pem" \
    "data/zkchat/identity"; do
    if git ls-files -- "$p" | grep -q .; then
        fail "private identity tracked in git: $p"
    fi
done
[ "$issues" -eq 0 ] && ok "no private-identity paths tracked"

# 4. No committed chat data or spool files
if git ls-files | grep -E '(chatd/user_|chatd/group_|\.msg$|\.ratchets$|spool\.db|persistence\.db)'; then
    fail "chat data / spool files tracked (see list above)"
else
    ok "no chat data or spool files tracked"
fi

# 5. No ELF binaries committed under config/
if git ls-files -z -- config/ | xargs -0 -r -I{} sh -c 'file -b "$1" 2>/dev/null | grep -q ELF && echo "$1"' _ {} | grep -q .; then
    fail "ELF binary committed under config/ (see list above)"
    git ls-files -z -- config/ | xargs -0 -r -I{} sh -c 'file -b "$1" 2>/dev/null | grep -q ELF && echo "$1"' _ {} | head -5
else
    ok "no binaries under config/"
fi

# 6. .env must not be tracked
if git ls-files --error-unmatch .env &>/dev/null; then
    fail ".env is tracked in git"
else
    ok ".env not tracked"
fi

echo ""
if [ "$issues" -gt 0 ]; then
    echo -e "${RED}FAILED: $issues issue(s) found — do NOT push.${NC}"
    exit 1
fi
echo -e "${GREEN}PASSED: no secrets detected.${NC}"
