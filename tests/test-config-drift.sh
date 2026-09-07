#!/bin/bash
# repo topology vs live device (SCM4). SKIP if device unreachable.
set -u
cd "$(dirname "$0")/.."
HOST="${SCM4_HOST:-zero-tech@192.168.1.3}"
KEY="${SCM4_KEY:-$HOME/.ssh/id_ed25519_scm4}"
if ! timeout 6 ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=4 "$HOST" true 2>/dev/null; then
  echo "SKIP: device unreachable ($HOST) — export pending"; exit 77
fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "$HOST" \
  "echo r00ts3c | sudo -S sh -c 'cd /home/zero-tech/zknode-autonomi && find config/mixnet99 -name \"*.toml\" | tar czf /tmp/mix99drv.tar -T -' 2>/dev/null; chmod 644 /tmp/mix99drv.tar" >/dev/null 2>&1
scp -q -i "$KEY" -o StrictHostKeyChecking=accept-new "$HOST:/tmp/mix99drv.tar" "$T/" 2>/dev/null
mkdir -p "$T/live" && tar xzf "$T/mix99drv.tar" -C "$T/live"
rc=0
while IFS= read -r f; do
  rel="${f#$T/live/}"
  if [ ! -f "config/mixnet99/$rel" ]; then
    echo "MISSING in repo: config/mixnet99/$rel"; rc=1; continue
  fi
  if ! cmp -s "config/mixnet99/$rel" "$f"; then
    echo "DRIFT: config/mixnet99/$rel"; rc=1
  fi
done < <(find "$T/live" -name '*.toml' | sort)
# reverse: repo tomls that no longer exist on device
while IFS= read -r f; do
  rel="${f#config/mixnet99/}"
  [ -f "$T/live/$rel" ] || { echo "STALE in repo (not on device): config/mixnet99/$rel"; rc=1; }
done < <(find config/mixnet99 -name '*.toml' | sort)
[ $rc -eq 0 ] && echo "OK: repo mixnet99 topology matches device"
exit $rc
