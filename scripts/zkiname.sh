#!/bin/bash
set -euo pipefail
# zkiname.sh — node identity lock-in for the P4P/zknode fleet.
#
# ONE command applies the node's name on every surface:
#   hostname, /etc/hosts, avahi (mDNS), Tailscale (MagicDNS), and a
#   machine-readable record at /var/lib/zknode/node-id.json.
#
# The node-id record is the fleet's source of truth — bridge-peer.sh export,
# dashboards and DomainCards read it. Never hardcode a node name anywhere.
#
# Usage:
#   zkiname.sh                # interactive: confirm/enter the tag
#   zkiname.sh <tag>          # non-interactive (provisioning, firstboot)
#   zkiname.sh --rename <tag> # deliberate rename (re-issues identity stamps)
#   zkiname.sh --show         # print the current identity record
#   zkiname.sh --reset        # clear the record (re-provision next boot)
#
# Naming rule (see ZKNODE_NAMING_FEDERATION.md):
#   name := zknode-<leaf>, leaf := [a-z0-9-]{2,12}   e.g. zknode-01, zknode-0kn-a
#
# Federation note: peer DomainCards pin the netID. Renaming a federated node
# requires re-issuing its card to every peer (bridge-peer.sh export).

SHOW=0; RESET=0; RENAME=0; NEW_TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --show)   SHOW=1 ;;
    --reset)  RESET=1 ;;
    --rename) RENAME=1; shift; NEW_TAG="${1:-}" ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) if [ -z "$NEW_TAG" ]; then NEW_TAG="$1"; fi ;;
  esac
  shift
done

NODE_DIR="${NODE_DIR:-/var/lib/zknode}"
ID_FILE="$NODE_DIR/node-id.json"
LAN_SUFFIX="${LAN_SUFFIX:-lan}"

jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],""))' "$ID_FILE" "$1" 2>/dev/null || true; }
jset() { python3 - "$1" "$2" "$ID_FILE" <<'PY'
import json,sys
key,val,p = sys.argv[1],sys.argv[2],sys.argv[3]
d={}
try: d=json.load(open(p))
except Exception: pass
d["issued"]=__import__("time").strftime("%Y-%m-%dT%H:%M:%SZ",__import__("time").gmtime())
d.update({key:val})
open(p,"w").write(json.dumps(d,indent=1,sort_keys=True))
PY
}

if [ "$SHOW" = 1 ]; then  cat "$ID_FILE" 2>/dev/null || echo "{}"; exit 0; fi
if [ "$RESET" = 1 ]; then rm -f "$ID_FILE"; echo "node-id cleared (re-provision on next boot)"; exit 0; fi

CURRENT=$(hostname 2>/dev/null || true)
OLD_LEAF=$(jget leaf); NAMED_BEFORE=0
[ -n "$OLD_LEAF" ] && NAMED_BEFORE=1

# ---- determine target leaf ------------------------------------------------
if [ -n "$NEW_TAG" ]; then
  LEAF="$NEW_TAG"
elif [ "$NAMED_BEFORE" = 1 ] && [ "$RENAME" != 1 ]; then
  echo "already locked: zknode-$OLD_LEAF  (use '--rename <tag>' to change)"
  exit 0
else
  if [ -e /dev/tty1 ] && [ -w /dev/tty1 ]; then TTY=/dev/tty1; else TTY=/dev/tty; fi
  printf 'enter fleet tag [2-12 chars, e.g. 01 | 0kn-a | lab1] (current host: %s): ' "${CURRENT:-unset}" >&2
  read -r LEAF <&3 2>/dev/null || read -r LEAF
  LEAF="${LEAF:$(hostname 2>/dev/null | sed 's/^zknode-//' | cut -c1-6)}"
fi
NAME="zknode-$LEAF"

echo "$LEAF" | grep -qE '^[a-z0-9-]{2,12}$' || { echo "invalid leaf '$LEAF' (need [a-z0-9-]{2,12})" >&2; exit 1; }

if [ "$NAMED_BEFORE" = 1 ] && [ "$LEAF" != "$OLD_LEAF" ]; then
  echo "RENAME: zknode-$OLD_LEAF → $NAME"
  echo "federated peers hold DomainCards for the old netID — re-issue the card (bridge-peer.sh export) to each peer after this."
fi

# ---- apply ---------------------------------------------------------------
printf '%s\n' "$NAME" > /etc/hostname
hostname "$NAME" 2>/dev/null || true

TSIP=""
command -v tailscale >/dev/null 2>&1 && TSIP=$(tailscale ip -4 2>/dev/null | head -1 || true)

python3 - "$NAME" "$TSIP" "$LAN_SUFFIX" <<'PY'
import sys
name, tsip, ls = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open('/etc/hosts').read().splitlines()
keep=[l for l in lines if 'zknode' not in l.split('#')[0] and l.strip() and not l.strip().startswith(f'127.0.1.1\t{name}')]
entry=f"127.0.1.1\t{name}.{ls} {name}.local {name}"
if tsip:
    ts=f"{tsip}\t{name}.ts {name}"
else:
    ts=None
out="\n".join(([ts]+[entry]+keep) if ts else ([entry]+keep))
open('/etc/hosts','w').write(out+"\n")
PY

systemctl try-restart avahi-daemon 2>/dev/null || systemctl start avahi-daemon 2>/dev/null || true
if command -v tailscale >/dev/null 2>&1; then
  tailscale set --hostname "$NAME" >/dev/null 2>&1 || true
fi

mkdir -p "$NODE_DIR"
BID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
jset name "$NAME"; jset leaf "$LEAF"; jset hostname "$NAME"
[ -n "$TSIP" ] && jset tailscale_ip "$TSIP"
[ -n "$BID" ] && jset boot_id "$(echo "$BID" | tr -d ' \n' | cut -c1-36)"
chmod 0644 "$ID_FILE"

echo "locked: $NAME"
echo "  surfaces: hostname=$NAME · $NAME.$LAN_SUFFIX · $NAME.local (mDNS) · Tailscale MagicDNS $NAME.<tailnet>.ts.net"
echo "  record:   $ID_FILE  (netID for every DomainCard)"
