#!/bin/bash
# zknode-watchdog: I/O-aware self-healing engine
# GOLDEN RULE (learned 2026-08-30): NEVER intervene during an I/O storm.
# Interventions during jbd2/sda storms compound the stall and wedge the box.
# Escalation: verify -> wait -> cheap fix (start/throttle) -> coordinated restart.
# Cooldowns prevent flapping. Every decision is logged.

NODE_HOME="${NODE_HOME:-/home/zero-tech/zknode-autonomi}"
LOG=/var/log/zknode-watchdog.log
STATE=/var/run/zknode-watchdog.state
IOWAIT_MAX=60          # percent — above this, back off
LOAD_MAX=25            # 1-min load — above this, back off
DIRAUTH_STALE_EPOCHS=4 # consensus older than N epochs => desync (epoch ~23min)
DIRAUTH_COOLDOWN=7200  # seconds between coordinated dirauth restarts
NOMAD_COOLDOWN=1800
START_COOLDOWN=600

log() { echo "[$(date -u +%FT%TZ)] $*" >> "$LOG"; }

iowait_pct() { top -bn1 | awk '/^%Cpu/{for(i=1;i<=NF;i++) if($i=="wa,") print int($(i-1))}'; }
load1() { awk '{print int($1)}' /proc/loadavg; }
cooldown_ok() { # $1=key $2=seconds
  local last; last=$(grep "^$1=" "$STATE" 2>/dev/null | cut -d= -f2)
  [ -z "$last" ] && return 0
  [ $(( $(date +%s) - last )) -ge "$2" ]
}
mark() { # $1=key
  grep -v "^$1=" "$STATE" 2>/dev/null > "$STATE.tmp"; echo "$1=$(date +%s)" >> "$STATE.tmp"; mv "$STATE.tmp" "$STATE"
}

WA=$(iowait_pct); L=$(load1)
log "--- cycle start (iowait=$WA load=$L) ---"

# ============ GOLDEN RULE: storm backoff ============
if [ "$WA" -ge "$IOWAIT_MAX" ] || [ "$L" -ge "$LOAD_MAX" ]; then
  log "BACKOFF: io storm or load storm (iowait=$WA load=$L) — no interventions this cycle"
  exit 0
fi

# ============ CHECK 1: antd throttle present ============
if ! find /sys/fs/cgroup -maxdepth 4 -path '*docker*' -name 'io.max' 2>/dev/null | xargs grep -l 'wbps=41943040' 2>/dev/null | grep -q .; then
  CG=$(docker inspect -f '{{.CgroupPath}}' antd 2>/dev/null)
  if [ -n "$CG" ] && [ -f "/sys/fs/cgroup$CG/io.max" ]; then
    echo "8:0 rbps=104857600 wbps=41943040" > "/sys/fs/cgroup$CG/io.max" && log "FIX: reapplied antd blkio throttle (was missing)"
  else
    log "WARN: antd throttle missing and cgroup not found — verify manually"
  fi
fi

# ============ CHECK 2: exited containers (cheap start) ============
# storage-proved has a known boot race; generic: any non-antd exited container gets one start attempt
docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null | while IFS='|' read -r name status; do
  case "$status" in
    Exited*)
      case "$name" in
        antd) log "SKIP: antd exited — manual/staggered path only (heavy I/O)"; continue;;
      esac
      if cooldown_ok "start_$name" "$START_COOLDOWN"; then
        docker start "$name" >/dev/null 2>&1 && { log "FIX: started exited container $name"; mark "start_$name"; } \
          || log "FAIL: could not start $name (dockerd busy?)"
      else
        log "COOLDOWN: $name start attempted recently — skipping"
      fi;;
  esac
done

# ============ CHECK 3: nomadnet stability ============
NN_STATUS=$(docker inspect -f '{{.State.Status}}' nomadnet 2>/dev/null)
NN_RC=$(docker inspect -f '{{.RestartCount}}' nomadnet 2>/dev/null || echo 0)
if [ "$NN_STATUS" = "restarting" ] && cooldown_ok "nomadnet_fix" "$NOMAD_COOLDOWN"; then
  log "FIX: nomadnet restart-loop detected (rc=$NN_RC) — recreating with isolated storage"
  docker compose -f "$NODE_HOME/docker-compose.yml" up -d --force-recreate nomadnet >/dev/null 2>&1 \
    && { log "FIX: nomadnet recreated"; mark nomadnet_fix; } || log "FAIL: nomadnet recreate"
fi

# ============ CHECK 4: dirauth consensus desync ============
LAST=$(docker exec mix-dirauth-1 sh -c "grep -a 'Achieved threshold' /var/lib/katzenpost/auth1/katzenpost.log 2>/dev/null | tail -1 | grep -oE 'epoch [0-9]+' | awk '{print \$2}'" 2>/dev/null)
NOWEPOCH=$(docker exec mix-dirauth-1 sh -c "grep -aoE 'epoch [0-9]+' /var/lib/katzenpost/auth1/katzenpost.log 2>/dev/null | tail -1 | awk '{print \$2}'" 2>/dev/null)
if [ -n "$LAST" ] && [ -n "$NOWEPOCH" ]; then
  AGE=$(( NOWEPOCH - LAST ))
  if [ "$AGE" -ge "$DIRAUTH_STALE_EPOCHS" ] && cooldown_ok "dirauth_sync" "$DIRAUTH_COOLDOWN"; then
    log "FIX: dirauth consensus stale $AGE epochs (last=$LAST now=$NOWEPOCH) — SIMULTANEOUS restart of all 3"
    docker restart -t 3 mix-dirauth-1 mix-dirauth-2 mix-dirauth-3 >/dev/null 2>&1 \
      && { log "FIX: dirauths restarted together"; mark dirauth_sync; } || log "FAIL: dirauth restart"
  fi
else
  log "INFO: cannot read dirauth consensus epochs (containers down or logs absent)"
fi

log "--- cycle end ---"
