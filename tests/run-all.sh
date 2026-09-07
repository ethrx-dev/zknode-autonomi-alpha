#!/bin/bash
set -u
# run-all.sh — test runner for the zknode-autonomi repo
# PASS/FAIL per test; SKIP is allowed for environment-dependent tests
cd "$(dirname "$0")"
TESTDIR="$PWD"
cd ..
declare -a RESULTS
FAILED=0; SKIPPED=0

for t in "$TESTDIR"/test-*.sh; do
  name=$(basename "$t")
  [ "$name" = "run-all.sh" ] && continue
  out=$(bash "$t" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then
    RESULTS+=("PASS  $name")
  elif [ $rc -eq 77 ]; then
    RESULTS+=("SKIP  $name  ($(echo "$out" | grep -a 'SKIP:' | head -1 | cut -d: -f2- | xargs))")
    SKIPPED=$((SKIPPED+1))
  else
    RESULTS+=("FAIL  $t")
    echo "$out" | tail -5
    FAILED=$((FAILED+1))
  fi
done

echo "=== test matrix ==="
for r in "${RESULTS[@]}"; do echo "$r"; done
n_pass=$(printf '%s\n' "${RESULTS[@]}" | grep -c '^PASS')
echo "=== $n_pass passed, $FAILED failed, $SKIPPED skipped ==="
[ "$FAILED" -eq 0 ]
