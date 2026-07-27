#!/bin/bash
set -e

WORKDIR=/tmp/wallet-build
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

git clone --depth 1 https://github.com/ZeroKnowledgeNetwork/opt.git "$WORKDIR/opt" 2>/dev/null

cp /src/main.go "$WORKDIR/opt/apps/walletshield/main.go"
cp -r /src/thin "$WORKDIR/opt/apps/walletshield/thin"

cd "$WORKDIR/opt/apps/walletshield"

# Remove the problematic replace directives and fix go.mod
sed -i '/^replace/d' go.mod 2>/dev/null || true
go mod tidy 2>&1 || true

GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-buildid= -s -w" -o /dest/walletshield . 2>&1
echo "BUILD_OK"
file /dest/walletshield
