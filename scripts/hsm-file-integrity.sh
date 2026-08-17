#!/bin/bash
# hsm-file-integrity.sh — Monitor critical configs with HSM-backed hash manifest
# Stores baseline hashes locked in HSM. On each run, verifies integrity.

CONFIG_DIRS=(
    "/home/user/zknode-autonomi/config"
    "/home/user/nomadnet/pages"
    "/home/user/zknode-autonomi/data/llm-wiki/wiki"
)
MANIFEST_DIR="/home/user/zknode-autonomi/data/zymbit"
MANIFEST_LOCKED="$MANIFEST_DIR/file-integrity.locked"
MANIFEST_PLAIN="$MANIFEST_DIR/file-integrity.txt"
TMP_MANIFEST=$(mktemp)
trap 'rm -f "$TMP_MANIFEST"' EXIT

# Generate current manifest
for dir in "${CONFIG_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        find "$dir" -type f \( -name '*.yml' -o -name '*.yaml' -o -name '*.toml' -o -name '*.service' -o -name '*.mu' -o -name '*.md' -o -name '*.sh' -o -name '*.py' \) \
            -exec sha256sum {} \; 2>/dev/null >> "$TMP_MANIFEST"
    fi
done
sort -o "$TMP_MANIFEST" "$TMP_MANIFEST"

# If no locked manifest exists, create baseline
if [ ! -f "$MANIFEST_LOCKED" ]; then
    echo "No baseline manifest found. Creating HSM-locked baseline..."
    python3 -c "
import zymkey
zk = zymkey.client
with open('$TMP_MANIFEST', 'rb') as f:
    data = f.read()
locked = zk.lock(data)
with open('$MANIFEST_LOCKED', 'wb') as f:
    f.write(locked)
print(f'Baseline locked: {len(locked)} bytes')
" 2>&1
    cp "$TMP_MANIFEST" "$MANIFEST_PLAIN"
    echo "Baseline manifest created and locked in HSM."
    exit 0
fi

# Verify current manifest against HSM-locked baseline
python3 -c "
import zymkey, sys

zk = zymkey.client
with open('$MANIFEST_LOCKED', 'rb') as f:
    locked = f.read()
try:
    baseline = zk.unlock(locked).decode()
except Exception as e:
    print(f'HSM UNLOCK FAILED: {e}')
    sys.exit(1)

with open('$TMP_MANIFEST', 'r') as f:
    current = f.read()

if baseline == current:
    print('File integrity: PASSED (all files unchanged)')
    sys.exit(0)
else:
    # Find differences
    blines = set(baseline.split(chr(10)))
    clines = set(current.split(chr(10)))
    added = clines - blines
    removed = blines - clines
    for f in sorted(added):
        if f: print(f'  ADDED/MODIFIED:  {f.split()[-1]}')
    for f in sorted(removed):
        if f: print(f'  REMOVED: {f.split()[-1]}')
    print('File integrity: FAILED')
    sys.exit(1)
" 2>&1
