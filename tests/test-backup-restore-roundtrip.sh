#!/bin/bash
# staging roundtrip: fake node tree -> backup -> wipe -> restore -> identical
set -u
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/scripts" "$T/backup" "$T/keys"
# fake state
mkdir -p "$T/repo/config/mixnet99/client/.zkchat" "$T/repo/config/mixnet99/auth1" "$T/repo/config/proxy"
echo "identity-secret-bytes" > "$T/repo/config/mixnet99/auth1/identity.private.pem"
echo "client-toml" > "$T/repo/config/mixnet99/client/client.toml"
echo "chat-identity" > "$T/repo/config/mixnet99/client/.zkchat/identity"
echo '{"a":1}' > "$T/repo/config/proxy/config.json"
echo "cache-junk-should-survive-backup" > "$T/repo/config/mixnet99/auth1/katzenpost.log"
cp "$PWD/../scripts/state.sh" "$T/repo/scripts/" 2>/dev/null || cp "$(dirname "$0")/../scripts/state.sh" "$T/repo/scripts/"
K="$T/keys/k"; echo "test-passphrase-0906" > "$K"
export BACKUP_KEYFILE="$K" BACKUP_DIR="$T/backup"
if ! bash "$T/repo/scripts/state.sh" backup >"$T/backup.log" 2>&1; then
  echo "FAIL: backup step"; cat "$T/backup.log"; exit 1
fi
B=$(ls "$T/backup"/zknode-state-*.tar.gz.enc 2>/dev/null | head -1)
[ -n "$B" ] || { echo "FAIL: no bundle created"; cat "$T/backup.log"; exit 1; }
# plaintext check: bundle must NOT contain the secret
if grep -aq "identity-secret-bytes" "$B" 2>/dev/null; then echo "FAIL: bundle is not encrypted"; exit 1; fi
# wipe state and restore
rm -rf "$T/repo/config/mixnet99"
bash "$T/repo/scripts/state.sh" restore "$B" --force >"$T/restore.log" 2>&1 || { echo "FAIL: restore step"; cat "$T/restore.log"; exit 1; }
grep -q "identity-secret-bytes" "$T/repo/config/mixnet99/auth1/identity.private.pem" || { echo "FAIL: key not restored"; exit 1; }
grep -q "chat-identity" "$T/repo/config/mixnet99/client/.zkchat/identity" || { echo "FAIL: zkchat identity not restored"; exit 1; }
grep -q "client-toml" "$T/repo/config/mixnet99/client/client.toml" || { echo "FAIL: toml not restored"; exit 1; }
grep -q "cache-junk-should-survive-backup" "$T/repo/config/mixnet99/auth1/katzenpost.log" 2>/dev/null \
  && { echo "FAIL: runtime log must NOT be restored (excluded from backup)"; exit 1; }
[ ! -f "$T/repo/config/mixnet99/auth1/katzenpost.log" ] || { echo "FAIL: log unexpectedly present"; exit 1; }
# guard test: restore WITHOUT --force must refuse when keys exist
if bash "$T/repo/scripts/state.sh" restore "$B" >"$T/guard.log" 2>&1; then
  echo "FAIL: restore without --force overwrote existing state"; exit 1
fi
echo "OK: backup/restore roundtrip + encryption + guard"
