#!/bin/bash
set -euo pipefail

# deploy.sh — Staged deployment for zknode-autonomi on SCM4
# Usage:
#   sudo ./scripts/deploy.sh                    # Deploy all containers
#   sudo ./scripts/deploy.sh --check            # Pre-flight check only
#   sudo ./scripts/deploy.sh --zymkey           # Deploy with Zymbit HSM override
#   sudo ./scripts/deploy.sh --group 1          # Deploy only group N
#   sudo ./scripts/deploy.sh --status           # Check deployment status

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE="docker compose -f docker-compose.yml"
COMPOSE_CMD="docker compose -f $PROJECT_ROOT/docker-compose.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[x]${NC} $1"; }
info()  { echo -e "${CYAN}[i]${NC} $1"; }

# ─── Pre-flight Checks ─────────────────────────────────────

cmd_check() {
    local failed=0

    echo "=== zknode-autonomi Pre-flight Check ==="
    echo ""

    # Architecture
    info "Architecture: $(uname -m)"
    if [ "$(uname -m)" != "aarch64" ]; then
        warn "Expected aarch64, got $(uname -m)"
    fi

    # Kernel
    info "Kernel: $(uname -r)"

    # Memory
    local mem_total=$(free -m | awk '/^Mem:/ {print $2}')
    info "Memory: ${mem_total}MB total"
    if [ "$mem_total" -lt 7000 ]; then
        warn "Less than 8GB RAM detected — memory pressure likely"
    fi

    # Disk (pool mount)
    if mountpoint -q /mnt/autonomi 2>/dev/null; then
        local pool_size=$(df -h /mnt/autonomi | awk 'NR==2 {print $2}')
        local pool_avail=$(df -h /mnt/autonomi | awk 'NR==2 {print $4}')
        step "/mnt/autonomi mounted: ${pool_size} total, ${pool_avail} available"
    else
        warn "/mnt/autonomi NOT mounted — pool/chunk storage unavailable"
        failed=1
    fi

    # I2C bus
    if ls /dev/i2c-* 2>/dev/null | grep -q i2c; then
        step "I2C bus available"
    else
        warn "I2C bus not found"
    fi

    # Zymkey device
    if [ -e /dev/zymkey ]; then
        step "/dev/zymkey present"
        if python3 -c "import zymkey" 2>/dev/null; then
            local fw=$(python3 -c "import zymkey; print(zymkey.client.get_firmware_version())" 2>/dev/null || echo "unknown")
            local status=$(python3 -c "import zymkey; print(zymkey.client.get_operational_status())" 2>/dev/null || echo "unknown")
            step "Zymkey firmware: $fw, status: $status"
        else
            warn "python3-zymkey module not installed"
        fi
    else
        warn "/dev/zymkey not found — HSM not available"
    fi

    # Docker
    if command -v docker &>/dev/null; then
        step "Docker installed: $(docker --version)"
        if docker info &>/dev/null; then
            step "Docker daemon running"
        else
            err "Docker daemon NOT running"
            failed=1
        fi
    else
        err "Docker NOT installed"
        failed=1
    fi

    # Docker Compose
    if docker compose version &>/dev/null; then
        step "Docker Compose: $(docker compose version)"
    else
        err "Docker Compose NOT available"
        failed=1
    fi

    # Git repo
    if [ -f "$PROJECT_ROOT/docker-compose.yml" ]; then
        step "Repo found at $PROJECT_ROOT"
        local branch=$(cd "$PROJECT_ROOT" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        info "Branch: $branch"
        local commit=$(cd "$PROJECT_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        info "Commit: $commit"
    else
        err "Repo not found at $PROJECT_ROOT"
        failed=1
    fi

    # .env file
    if [ -f "$PROJECT_ROOT/.env" ]; then
        step ".env file present"
        if grep -q "SECRET_KEY=0x" "$PROJECT_ROOT/.env" 2>/dev/null; then
            step "SECRET_KEY set"
        else
            warn "SECRET_KEY not set in .env"
        fi
    else
        err ".env file missing — copy from .env.example"
        failed=1
    fi

    # Docker images
    info "Required images:"
    while IFS= read -r img; do
        img=$(echo "$img" | tr -d ' ')
        [ -z "$img" ] && continue
        if docker image inspect "$img" &>/dev/null; then
            step "  $img"
        else
            warn "  $img — NOT FOUND"
        fi
    done < <(cd "$PROJECT_ROOT" && grep -rh '^\s*image:' docker-compose.yml docker-compose.zymkey.yml 2>/dev/null | sed 's/.*image: *//' | tr -d '"' | sort -u)

    # Data directories
    for dir in /var/lib/katzenpost/auth{1,2,3} /var/lib/katzenpost/gateway1 \
               /var/lib/katzenpost/servicenode1 /var/lib/katzenpost/servicenode1/courier \
               /var/lib/katzenpost/servicenode1/chatd /var/lib/katzenpost/mix{1,2,3}; do
        if [ -d "$dir" ]; then
            local perm=$(stat -c "%a" "$dir" 2>/dev/null)
            if [ "$perm" = "700" ] || [ "$perm" = "755" ]; then
                step "  $dir ($perm)"
            else
                warn "  $dir (permissions: $perm, should be 700)"
            fi
        else
            warn "  $dir — NOT FOUND (will be created)"
        fi
    done

    # ANT_REWARDS_ADDRESS check
    if grep -q "ANT_REWARDS_ADDRESS=CHANGE_ME_BEFORE_DEPLOY" "$PROJECT_ROOT/docker-compose.zymkey.yml" 2>/dev/null; then
        warn "ANT_REWARDS_ADDRESS still set to CHANGE_ME_BEFORE_DEPLOY — run setup-zymbit.sh --wallet"
    fi

    echo ""
    if [ "$failed" -eq 0 ]; then
        step "Pre-flight check PASSED"
    else
        warn "Pre-flight check has warnings — review above"
    fi
    return "$failed"
}

# ─── Data Directories ──────────────────────────────────────

cmd_dirs() {
    step "Creating data directories with 700 permissions..."
    for dir in /var/lib/katzenpost/auth1 /var/lib/katzenpost/auth2 \
               /var/lib/katzenpost/auth3 /var/lib/katzenpost/gateway1 \
               /var/lib/katzenpost/servicenode1 /var/lib/katzenpost/servicenode1/courier \
               /var/lib/katzenpost/servicenode1/chatd \
               /var/lib/katzenpost/mix1 /var/lib/katzenpost/mix2 /var/lib/katzenpost/mix3; do
        mkdir -p "$dir"
        chmod 700 "$dir"
        step "  $dir"
    done
    step "Data directories ready"
}

# ─── Staged Deployment ─────────────────────────────────────

DEPLOY_BASE="$COMPOSE_CMD"
DEPLOY_EXTRA=""
USE_ZYMMEYS=false

wait_for_healthy() {
    local container="$1"
    local max_wait="${2:-60}"
    local waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "")
        if [ "$status" = "running" ]; then
            step "  $container is running"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    warn "  $container did not start within ${max_wait}s"
    return 1
}

check_logs() {
    local container="$1"
    local pattern="$2"
    local max_wait="${3:-30}"
    local waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        if docker logs "$container" 2>&1 | grep -q "$pattern"; then
            step "  $container: pattern '$pattern' found"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    warn "  $container: pattern '$pattern' NOT found within ${max_wait}s"
    return 1
}

cmd_group() {
    local group="${1:-all}"
    local zymkey="${2:-false}"
    local base="$DEPLOY_BASE"
    local extra=""

    if [ "$zymkey" = "true" ]; then
        base="$base -f $PROJECT_ROOT/docker-compose.zymkey.yml"
        extra="--profile zymkey"
    fi

    case "$group" in
        1)
            info "Group 1: Authorities"
            $base up -d $extra mix-dirauth-1 mix-dirauth-2 mix-dirauth-3
            sleep 5
            for c in mix-dirauth-1 mix-dirauth-2 mix-dirauth-3; do
                wait_for_healthy "$c" 30
                check_logs "$c" "PKI" 30 || true
            done
            info "Waiting 30s for PKI consensus..."
            sleep 30
            ;;
        2)
            info "Group 2: Mix Nodes"
            $base up -d $extra mix-1 mix-2 mix-3
            sleep 5
            for c in mix-1 mix-2 mix-3; do
                wait_for_healthy "$c" 30
            done
            info "Waiting 20s for mixnet connections..."
            sleep 20
            ;;
        3)
            info "Group 3: Gateway"
            $base up -d $extra mix-gateway
            sleep 5
            wait_for_healthy mix-gateway 30
            info "Waiting 10s..."
            sleep 10
            ;;
        4)
            info "Group 4: Service Node"
            $base up -d $extra mix-servicenode
            sleep 5
            wait_for_healthy mix-servicenode 30
            check_logs mix-servicenode "registered" 30 || true
            info "Waiting 10s..."
            sleep 10
            ;;
        5)
            info "Group 5: Client + Proxy"
            $base up -d $extra mix-client
            sleep 5
            wait_for_healthy mix-client 60
            check_logs mix-client "PKI doc" 60 || true
            $base up -d $extra mixnet-proxy
            sleep 3
            wait_for_healthy mixnet-proxy 30
            info "Waiting 10s..."
            sleep 10
            ;;
        6)
            info "Group 6: Walletshield + Storage"
            $base up -d $extra walletshield storage-proved
            sleep 5
            for c in walletshield storage-proved; do
                wait_for_healthy "$c" 30
            done
            info "Waiting 10s..."
            sleep 10
            ;;
        7)
            info "Group 7: Ant Node (with Zymkey)"
            if [ "$zymkey" = "true" ]; then
                $base up -d $extra zkifc ant-node antd
                sleep 5
                for c in zkifc ant-node antd; do
                    wait_for_healthy "$c" 60
                done
                check_logs zkifc "zkym" 15 || true
            else
                warn "Skipping Group 7 — zymkey not enabled"
            fi
            info "Waiting 10s..."
            sleep 10
            ;;
        8)
            info "Group 8: Mesh (Reticulum + Wiki + NomadNet)"
            $base up -d $extra reticulum
            sleep 5
            wait_for_healthy reticulum 30
            info "Waiting 10s..."
            sleep 10
            ;;
        9)
            info "Group 9: Dashboard"
            $base up -d $extra zknode-dashboard zkchat
            sleep 5
            for c in zknode-dashboard zkchat; do
                wait_for_healthy "$c" 30
            done
            ;;
        all)
            for g in 1 2 3 4 5 6 7 8 9; do
                cmd_group "$g" "$zymkey"
            done
            ;;
        *)
            err "Unknown group: $group (valid: 1-9, all)"
            exit 1
            ;;
    esac
}

# ─── Full Deploy ──────────────────────────────────────────

cmd_deploy() {
    local zymkey="${1:-false}"

    step "Starting zknode-autonomi deployment..."
    echo ""

    cmd_check || true
    echo ""

    cmd_dirs
    echo ""

    cmd_group all "$zymkey"

    echo ""
    step "Deployment complete!"
    echo ""
    cmd_status
}

# ─── Status ────────────────────────────────────────────────

cmd_status() {
    echo "=== Container Status ==="
    echo ""
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | head -30
    echo ""
    info "Mixnet PKI:"
    for c in mix-dirauth-1 mix-dirauth-2 mix-dirauth-3; do
        if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "$c"; then
            local epoch
            epoch=$(docker logs "$c" 2>&1 | grep -oP 'epoch \K[0-9]+' | tail -1 || echo "N/A")
            echo "  $c: epoch $epoch"
        fi
    done
}

# ─── Main ──────────────────────────────────────────────────

case "${1:-}" in
    --check)   cmd_check ;;
    --dirs)    cmd_dirs ;;
    --status)  cmd_status ;;
    --zymkey)  cmd_deploy true ;;
    --group)   cmd_group "${2:-}" "${3:-false}" ;;
    --help|-h)
        echo "Usage: sudo ./scripts/deploy.sh [OPTION]"
        echo ""
        echo "  (no flag)     Deploy all containers (no zymkey)"
        echo "  --zymkey      Deploy all containers with Zymbit HSM"
        echo "  --group N     Deploy only group N (1-9)"
        echo "  --check       Pre-flight check only (no changes)"
        echo "  --dirs        Create data directories only"
        echo "  --status      Show container status"
        echo "  --help        This message"
        echo ""
        echo "Groups:"
        echo "  1  Authorities     2  Mix nodes        3  Gateway"
        echo "  4  Service node    5  Client + Proxy   6  Walletshield + Storage"
        echo "  7  Ant node (zymkey)  8  Mesh           9  Dashboard"
        ;;
    *)
        cmd_deploy false
        ;;
esac
