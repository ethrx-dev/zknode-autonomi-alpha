#!/bin/sh
# List group metadata from the LOCAL chat servicenode (chatd stores group
# metas under /tmp/zkchat/group_*). No VPS/SSH required.
CONTAINER="${ZKCHAT_SERVICENODE:-mix-servicenode}"
docker exec "$CONTAINER" find /tmp/zkchat -name meta.json -exec cat {} + 2>/dev/null || true
