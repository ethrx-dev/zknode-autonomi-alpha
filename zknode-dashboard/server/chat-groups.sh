#!/bin/sh
docker exec mix-servicenode sh -c 'for d in /var/lib/katzenpost/servicenode1/chatd/group_*; do [ -f "$d/meta.json" ] && cat "$d/meta.json"; done' 2>/dev/null
