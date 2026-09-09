#!/bin/bash
# FAIL if any tracked file contains private key material, or matches a
# state-file pattern (keys, chat identities, runtime DBs).
# Detector files (tests/, scripts/state.sh) define the patterns and are
# excluded from the content scan; the filename scan still covers them.
set -u
rc=0
DETECTOR_RE='(^tests/|^scripts/state\.sh$|\.md$)'
while IFS= read -r f; do
  echo "$f" | grep -qE "$DETECTOR_RE" && continue
  if grep -aqE -- "BEGIN [A-Z0-9 ]*PRIVATE KEY|BEGIN OPENSSH PRIVATE KEY|age-encryption" "$f" 2>/dev/null; then
    echo "FAIL: key material in tracked file: $f"; rc=1
  fi
done < <(git ls-files)
bad=$(git ls-files | grep -aE '\.private\.pem$|\.private\.key$|/\.zkchat/|(^|/)identity$|management_sock$' || true)
if [ -n "$bad" ]; then echo "FAIL: tracked state files: $bad"; rc=1; fi
# detector files must never contain REAL key material: scan them for actual
# PEM blocks (the literal pattern strings above don't match a real block)
for f in $(git ls-files | grep -aE '^tests/|^scripts/state\.sh$'); do
  if grep -aqE -- '^-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----$' "$f" 2>/dev/null; then
    echo "FAIL: real key block in detector file: $f"; rc=1
  fi
done
[ $rc -eq 0 ] && echo "OK: no secrets tracked"
exit $rc
