#!/bin/bash
# validate docker-compose.yml interpolates and parses
set -u
command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not available"; exit 77; }
cd "$(dirname "$0")/.."
if NODE_HOME=/tmp/zknode-test-home DASHBOARD_PORT=8080 WS_PORT=9200 LLM_WIKI_PORT=18765 \
   docker compose -f docker-compose.yml config -q 2>err.log; then
  rm -f err.log; echo "OK: compose config valid"
  exit 0
else
  echo "FAIL: compose config invalid"; cat err.log | head -10; rm -f err.log; exit 1
fi
