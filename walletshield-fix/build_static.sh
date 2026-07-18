#!/bin/bash
set -e
apt-get update -qq && apt-get install -y -qq git > /dev/null 2>&1
git clone --depth 1 https://github.com/ZeroKnowledgeNetwork/opt.git /opt 2>/dev/null
cp /src/ws/main.go /opt/apps/walletshield/main.go
cp -r /src/ws/thin /opt/apps/walletshield/thin
cd /opt/apps/walletshield
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -trimpath -ldflags="-buildid= -extldflags=-static" -o /dest/walletshield .
echo "BUILD_OK"
