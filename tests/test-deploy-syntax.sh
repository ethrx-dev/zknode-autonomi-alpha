#!/bin/bash
# syntax + flag-surface: existing flags unchanged, new flags additive
set -u
rc=0
cd "$(dirname "$0")/.."
for f in deploy.sh scripts/state.sh tests/run-all.sh tests/test-*.sh; do
  bash -n "$f" || { echo "FAIL: syntax $f"; rc=1; }
done
case_grep=$(grep -A20 '^case "\${1:-}" in' deploy.sh)
for flag in --check --dirs --status --zymkey --group --help; do
  echo "$case_grep" | grep -q -- "$flag" || { echo "FAIL: missing existing flag $flag"; rc=1; }
done
for flag in --export-config --backup-state --restore-state; do
  echo "$case_grep" | grep -q -- "$flag" || { echo "FAIL: missing new flag $flag"; rc=1; }
done
[ $rc -eq 0 ] && echo "OK: syntax + flag surface"
exit $rc
