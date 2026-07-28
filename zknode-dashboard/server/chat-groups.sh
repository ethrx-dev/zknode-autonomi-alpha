#!/bin/sh
docker exec mix-servicenode find /tmp/zkchat /var/lib/katzenpost/servicenode1/chatd -name meta.json -exec cat {} +