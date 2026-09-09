#!/bin/bash
# structural validation of scripts/gen-mixnet99.sh output (no fleet boot)
set -u
cd "$(dirname "$0")/.."
command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not available"; exit 77; }
IMG="${IMAGE_MIXNET_TEST:-zeros/mixnet-node:amd64}"
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "SKIP: image $IMG not built"; exit 77; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
rc=0
if [ "$(id -u)" = "0" ]; then
  ./scripts/gen-mixnet99.sh "$IMG" "$T/out" >"$T/log" 2>&1 || { echo "FAIL: generator run"; tail -3 "$T/log"; exit 1; }
else
  sudo -n ./scripts/gen-mixnet99.sh "$IMG" "$T/out" >"$T/log" 2>&1 2>/dev/null \
    || SUDO_PW=./scripts/gen-mixnet99.sh "$IMG" "$T/out" 2>/dev/null \
    || { echo "SKIP: needs root (run via sudo)"; exit 77; }
fi
O="$T/out"
check() { # $1=desc $2=cmd
  if eval "$2" >/dev/null 2>&1; then echo "  ok: $1"; else echo "  FAIL: $1"; rc=1; fi
}
check "servicenode toml exists"     "test -f $O/servicenode1/katzenpost.toml"
check "courier cmd -> image path"   "grep -q 'Command = \"/usr/local/bin/courier\"' $O/servicenode1/katzenpost.toml"
check "http cmd -> image path"      "grep -q 'Command = \"/usr/local/bin/http-proxy-server\"' $O/servicenode1/katzenpost.toml"
check "http capability named http"  "grep -q 'Capability = \"http\"' $O/servicenode1/katzenpost.toml"
check "thinclient binds 127.0.0.1"  "grep -q '127.0.0.1:64331' $O/client/thinclient.toml"
check "gateway hostname address"    "grep -q 'tcp://gateway1:30007' $O/gateway1/katzenpost.toml"
check "node dirs are 700"           "find $O -mindepth 1 -type d -perm 700 | wc -l | grep -q '$(find $O -mindepth 1 -type d | wc -l)'"
check "auth identity keys exist"    "test -f $O/auth1/identity.private.pem"
[ $rc -eq 0 ] && echo "OK: gen-mixnet99 output structurally valid"
exit $rc
