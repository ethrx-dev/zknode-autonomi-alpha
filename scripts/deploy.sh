#!/bin/bash
set -euo pipefail

# deploy.sh — Deploy zknode-autonomi on SCM4 (aarch64, 8GB RAM)
# Usage: ./scripts/deploy.sh [--build | --start | --stop | --clean]
#
# Air-gapped deployment flow:
#   Build machine:   docker save ... | gzip > images.tar.gz
#   Transfer to SCM4: scp/cp images.tar.gz zero-tech@192.168.9.118:~
#   On SCM4:         ./scripts/deploy.sh --start

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

if [ -f .env ]; then
    set -a; source .env; set +a
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

banner() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      zknode-autonomi — Deploy            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
}

check_arch() {
    local arch
    arch=$(uname -m)
    if [ "$arch" != "aarch64" ] && [ "$arch" != "arm64" ]; then
        echo -e "${YELLOW}WARNING: Not running on aarch64 (detected: $arch).${NC}"
        echo "Images are compiled for arm64; they will run via QEMU emulation (slow)."
        echo "For production deployment, run on SCM4/CM4 hardware."
        echo ""
    fi
}

check_deps() {
    local missing=()
    command -v docker >/dev/null 2>&1 || missing+=("docker")
    docker compose version >/dev/null 2>&1 || missing+=("docker compose v2")
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Missing dependencies: ${missing[*]}${NC}"
        echo "Install Docker Engine 24+ and Docker Compose v2:"
        echo "  curl -fsSL https://get.docker.com | sh"
        exit 1
    fi
    echo -e "${GREEN}[ok]${NC} Docker $(docker --version | cut -d' ' -f3 | cut -d',' -f1)"
}

check_images() {
    local missing=()
    for img in "$IMAGE_MIXNET" "$IMAGE_ANT_NODE" "$IMAGE_ANTD" "$IMAGE_MIXNET_PROXY"; do
        docker image inspect "$img" >/dev/null 2>&1 || missing+=("$img")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Missing Docker images: ${missing[*]}${NC}"
        echo "Load them from the air-gapped tarball:"
        echo "  gunzip -c zknode-autonomi-images.tar.gz | docker load"
        echo "Or build from source:"
        echo "  docker build --build-arg TARGETARCH=arm64 -f Dockerfile.mixnet -t zeros/mixnet-node:arm64 ."
        echo "  docker build --build-arg TARGETARCH=arm64 -f Dockerfile.ant-node -t zeros/ant-node:arm64 ."
        echo "  docker build --build-arg TARGETARCH=arm64 -f Dockerfile.antd -t zeros/antd:arm64 ."
        echo "  docker build --build-arg TARGETARCH=arm64 -f Dockerfile.mixnet-proxy -t zeros/mixnet-proxy:arm64 ."
        exit 1
    fi
    echo -e "${GREEN}[ok]${NC} All Docker images present"
}

check_storage() {
    if [ -d "${TRINITY_MOUNT:-/mnt/trinity}" ]; then
        local free_gb
        free_gb=$(df -BG "$TRINITY_MOUNT" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
        echo -e "${GREEN}[ok]${NC} USB pool at $TRINITY_MOUNT (${free_gb:-?}GB free)"
    else
        echo -e "${YELLOW}[warn]${NC} USB pool not found at ${TRINITY_MOUNT:-/mnt/trinity}"
        echo "  Chunk storage will use ./data/chunks/ (local fallback)"
        echo "  To set up USB pool: sudo ./scripts/storage-layout.sh"
    fi
}

# ─── Commands ──────────────────────────────────────────────────

cmd_check() {
    banner
    echo "System check..."
    check_arch
    check_deps
    check_images
    check_storage
    echo ""
    echo -e "${GREEN}All checks passed. Run './scripts/deploy.sh --start' to deploy.${NC}"
}

cmd_setup() {
    echo "Generating configs and data directories..."
    bash "$SCRIPT_DIR/setup.sh"
}

cmd_start() {
    banner
    check_deps
    check_images
    check_storage
    
    echo ""
    echo "Starting zknode-autonomi..."
    
    # Stop anything running first
    docker compose down --remove-orphans 2>/dev/null || true
    
    # Start all services
    docker compose up -d
    
    echo ""
    echo "Waiting for mixnet consensus (may take 30-60 seconds)..."
    
    # Wait for services to stabilize
    local attempts=0
    while [ $attempts -lt 12 ]; do
        sleep 5
        attempts=$((attempts + 1))
        local running
        running=$(docker compose ps --format '{{.State}}' 2>/dev/null | grep -c "running" || echo 0)
        local total=10
        if [ "$running" -ge "$total" ]; then
            echo -e "${GREEN}[ok]${NC} All $total services running (after $((attempts * 5))s)"
            break
        fi
        echo "  $running/$total running (attempt $attempts)..."
    done
    
    # Restart any dirauth that didn't make it (race condition)
    for i in 1 2 3; do
        local state
        state=$(docker inspect -f '{{.State.Status}}' "mix-dirauth-$i" 2>/dev/null || echo "missing")
        if [ "$state" != "running" ]; then
            echo "  Restarting mix-dirauth-$i (was $state)..."
            docker compose restart "mix-dirauth-$i" 2>/dev/null || true
            sleep 3
        fi
    done
    
    echo ""
    docker compose ps --format 'table {{.Name}}\t{{.State}}\t{{.Status}}'
    echo ""
    
    # Check proxy API
    if curl -s --connect-timeout 2 http://127.0.0.1:9090/status >/dev/null 2>&1; then
        echo -e "${GREEN}Mixnet proxy API reachable${NC}"
    fi
    
    echo ""
    echo "=== NEXT STEPS ==="
    echo "  View logs:    docker compose logs -f"
    echo "  Monitor:      ./scripts/monitor.sh"
    echo "  Stop:         ./scripts/deploy.sh --stop"
}

cmd_stop() {
    echo "Stopping zknode-autonomi..."
    docker compose down
    echo -e "${GREEN}Stack stopped.${NC}"
}

cmd_stop_clean() {
    echo "Stopping and cleaning zknode-autonomi (removes volumes)..."
    docker compose down -v
    echo -e "${GREEN}Stack stopped and cleaned.${NC}"
}

cmd_build() {
    echo "Building images..."
    echo "  docker build --build-arg TARGETARCH=$TARGETARCH -f Dockerfile.mixnet -t $IMAGE_MIXNET ."
    echo "  docker build --build-arg TARGETARCH=$TARGETARCH -f Dockerfile.ant-node -t $IMAGE_ANT_NODE ."
    echo "  docker build --build-arg TARGETARCH=$TARGETARCH -f Dockerfile.antd -t $IMAGE_ANTD ."
    echo "  docker build --build-arg TARGETARCH=$TARGETARCH -f Dockerfile.mixnet-proxy -t $IMAGE_MIXNET_PROXY ."
    echo "Build not automated — run the commands above."
}

cmd_export() {
    local file="${1:-zknode-autonomi-images.tar.gz}"
    echo "Exporting Docker images to $file..."
    docker save "$IMAGE_MIXNET" "$IMAGE_ANT_NODE" "$IMAGE_ANTD" "$IMAGE_MIXNET_PROXY" | gzip > "$file"
    local size
    size=$(du -h "$file" | cut -f1)
    echo -e "${GREEN}Exported: $file ($size)${NC}"
    echo ""
    echo "Transfer to SCM4: cp $file /path/to/sdcard/"
}

# ─── Main ──────────────────────────────────────────────────────

case "${1:-}" in
    --check|check)  cmd_check ;;
    --start|start)  cmd_setup; cmd_start ;;
    --stop|stop)    cmd_stop ;;
    --clean|clean)  cmd_stop_clean; echo "Cleaning data..."; rm -rf data/* config/mixnet config/proxy config/autonomi 2>/dev/null || true ;; 
    --build|build)  cmd_build ;;
    --export|export) cmd_export "${2:-}" ;;
    *)
        echo "Usage: ./scripts/deploy.sh [--check|--start|--stop|--clean|--build|--export]"
        echo ""
        echo "  --check     Verify prerequisites"
        echo "  --start     Deploy and start the stack"
        echo "  --stop      Stop the stack (preserves volumes)"
        echo "  --clean     Stop, remove volumes, and clean all data"
        echo "  --build     Show build instructions"
        echo "  --export    Export images for air-gapped transfer"
        exit 1
        ;;
esac
