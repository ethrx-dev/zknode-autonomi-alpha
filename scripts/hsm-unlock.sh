#!/bin/bash
# hsm-unlock.sh — Unlock Autonomi SECRET_KEY from Zymkey HSM
# Outputs the key to stdout for use as SECRET_KEY env var.
# Usage: SECRET_KEY=$(hsm-unlock.sh) ant --local file upload ...
#
# On failure, exits with non-zero (no fallback to plaintext).

LOCKED_KEY="/home/zero-tech/zknode-autonomi-alpha/data/zymbit/autonomi-key.locked"

if [ ! -f "$LOCKED_KEY" ]; then
    echo "hsm-unlock: ERROR locked key not found at $LOCKED_KEY" >&2
    exit 1
fi

python3 -c "
import sys, zymkey
try:
    zk = zymkey.client
    with open('$LOCKED_KEY', 'rb') as f:
        locked = f.read()
    unlocked = zk.unlock(locked)
    print(unlocked.decode(), end='')
except Exception as e:
    print(f'hsm-unlock: ERROR {e}', file=sys.stderr)
    sys.exit(1)
"
