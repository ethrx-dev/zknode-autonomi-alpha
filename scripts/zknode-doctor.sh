#!/bin/bash
# zknode-doctor: one-shot full fleet diagnostics
# Machine-readable verdict: HEALTHY / DEGRADED / CRITICAL
# Placeholders parameterized by NODE_HOME (default /home/zero-tech/zknode-autonomi)
NODE_HOME="${NODE_HOME:-/home/zero-tech/zknode-autonomi}"
LOG_TAG="[doctor $(date -u +%FT%TZ)]"

iowait() { top -bn1 | awk '/^%Cpu/{for(i=1;i<=NF;i++) if($i=="wa,") print $(i-1)}'; }
load1()  { awk '{print int($1)}' /proc/loadavg; }

echo "$LOG_TAG === SYSTEM ==="
echo "uptime: $(uptime -p 2>/dev/null || uptime | sed 's/.*up //;s/,.*//')"
echo "load: $(cat /proc/loadavg | cut -d' ' -f1-3)"
echo "iowait: $(iowait)%"
free -h | awk 'NR==2{print "mem_used: "$3" / "$2}'

echo "$LOG_TAG === DISK ==="
df -h /mnt/autonomi /mnt/usb_sda3 2>/dev/null | awk 'NR>1{print $6": "$4" free ("$5" used)"}'
dmesg 2>/dev/null | grep -aiE "not properly unmounted|I/O error|usb.*reset" | tail -3 || true
DIRTY=$(dmesg 2>/dev/null | grep -ac "not properly unmounted" || true)
[ "$DIRTY" -gt 0 ] && echo "WARNING: exFAT dirty flag present (fsck sda3 at next maintenance window)"

echo "$LOG_TAG === FLEET ==="
TOTAL=0; UP=0; RESTARTING=0; EXITED=0
while IFS='|' read -r name status; do
  [ -z "$name" ] && continue
  TOTAL=$((TOTAL+1))
  case "$status" in
    Up*) UP=$((UP+1));;
    Restarting*) RESTARTING=$((RESTARTING+1));;
    Exited*) EXITED=$((EXITED+1));;
  esac
  rc=$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo "?")
  echo "$name | $status | restarts=$rc"
done < <(docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null)
echo "fleet: total=$TOTAL up=$UP restarting=$RESTARTING exited=$EXITED"

echo "$LOG_TAG === MIXNET ==="
# Dirauth consensus freshness: last "Achieved threshold consensus" in dirauth-1 log
NOWE=$(date +%s)
LAST=$(docker exec mix-dirauth-1 sh -c "grep -a 'Achieved threshold' /var/lib/katzenpost/auth1/katzenpost.log 2>/dev/null | tail -1" 2>/dev/null)
if [ -n "$LAST" ]; then
  EPOCH=$(echo "$LAST" | grep -oE 'epoch [0-9]+' | awk '{print $2}')
  echo "dirauth_consensus: epoch=$EPOCH (last: $(echo "$LAST" | cut -c1-19))"
else
  echo "dirauth_consensus: NO THRESHOLD ENTRY FOUND"
fi
# Gateway PKI health
GW=$(docker exec mix-gateway sh -c "grep -aE 'Failed to fetch PKI' /var/lib/katzenpost/gateway1/katzenpost.log 2>/dev/null | tail -1" 2>/dev/null)
[ -n "$GW" ] && echo "gateway_pki: last failure: $(echo "$GW" | cut -c1-60)" || echo "gateway_pki: no recent failures"

echo "$LOG_TAG === NOMADNET ==="
NN=$(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}} started={{.State.StartedAt}}' nomadnet 2>/dev/null)
echo "nomadnet: ${NN:-NOT_FOUND}"

echo "$LOG_TAG === ANT THROTTLE ==="
CG=$(find /sys/fs/cgroup -maxdepth 4 -path '*docker*' -name 'io.max' 2>/dev/null | xargs grep -l 'wbps=41943040' 2>/dev/null | head -1)
if [ -n "$CG" ]; then echo "antd_throttle: ACTIVE ($CG)"; else echo "antd_throttle: MISSING (apply 8:0 rbps=104857600 wbps=41943040)"; fi

echo "$LOG_TAG === VERDICT ==="
WA=$(iowait | cut -d. -f1); L=$(load1)
V="HEALTHY"
[ "$EXITED" -gt 0 ] && V="DEGRADED"
[ "$RESTARTING" -gt 0 ] && V="DEGRADED"
[ "$DIRTY" -gt 0 ] && V="DEGRADED"
[ "$WA" -ge 60 ] && V="CRITICAL (io storm: back off, no interventions)"
[ "$L" -ge 25 ] && V="CRITICAL (load storm)"
echo "VERDICT: $V"
