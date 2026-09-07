#!/bin/bash
# FAIL if any tracked file contains private key material, or matches a
# state-file pattern (keys, chat identities, runtime DBs).
set -u
rc=0
while IFS= read -r f; do
  if grep -aqE -- "BEGIN [A-Z0-9 ]*PRIVATE KEY|BEGIN OPENSSH PRIVATE KEY|age-encryption" "$f" 2>/dev/null; then
    echo "FAIL: key material in tracked file: $f"; rc=1
  fi
done < <(git ls-files)
bad=$(git ls-files | grep -aE '\.private\.pem$|\.private\.key$|/\.zkchat/|(^|/)identity$|management_sock$' || true)
if [ -n "$bad" ]; then echo "FAIL: tracked state files: $bad"; rc=1; fi
[ $rc -eq 0 ] && echo "OK: no secrets tracked"
exit $rc
