#!/bin/sh
# List group metadata from the LOCAL chat servicenode (chatd stores group
# metas under /tmp/zkchat/group_*). No VPS/SSH required.
# Override with ZKCHAT_SERVICENODE; otherwise auto-detect.
if [ -n "${ZKCHAT_SERVICENODE:-}" ]; then
  CONTAINER="$ZKCHAT_SERVICENODE"
elif docker inspect -f "{{.State.Running}}" mix-servicenode >/dev/null 2>&1; then
  CONTAINER=mix-servicenode
else
  CONTAINER=servicenode1
fi
docker exec "$CONTAINER" find /tmp/zkchat -name meta.json -exec cat {} + 2>/dev/null || true
