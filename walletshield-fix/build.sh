#!/bin/bash
set -e
apt-get update -qq && apt-get install -y -qq gcc-aarch64-linux-gnu g++-aarch64-linux-gnu git > /dev/null 2>&1
git clone --depth 1 https://github.com/ZeroKnowledgeNetwork/opt.git /opt 2>/dev/null
cp /src/ws/main.go /opt/apps/walletshield/main.go
cp -r /src/ws/thin /opt/apps/walletshield/thin
cd /opt/apps/walletshield
GOOS=linux GOARCH=arm64 CGO_ENABLED=1 \
  CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++ \
  go build -trimpath -ldflags="-buildid=" -o /dest/walletshield .
echo "BUILD_OK"
file /dest/walletshield
