#!/bin/bash
set -euo pipefail

# setup-zymbit.sh — Automated Zymbit/SCM4 security setup
# Run on SCM4 as root (sudo) to configure all Zymbit security features
#
# Usage:
#   sudo ./scripts/setup-zymbit.sh                      # Full setup
#   sudo ./scripts/setup-zymbit.sh --check              # Health check only
#   sudo ./scripts/setup-zymbit.sh --encrypt-usb /dev/sda # Encrypt USB drive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

step()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[x]${NC} $1"; }

die() {
    err "FATAL: $1"
    exit 1
}

# ─── Health Check ─────────────────────────────────────────

cmd_check() {
    echo "=== Zymbit SCM4 Health Check ==="
    echo ""

    # Architecture
    local arch=$(uname -m)
    if [ "$arch" != "aarch64" ]; then
        warn "Not running on aarch64 (detected: $arch). Zymkey only on SCM4."
    else
        step "Architecture: aarch64 ✓"
    fi

    # I2C bus
    if ls /dev/i2c-* 2>/dev/null | grep -q i2c; then
        step "I2C bus: available ✓"
    else
        warn "I2C bus not found. Enable with: sudo raspi-config → Interface → I2C"
    fi

    # zymkey device
    if [ -e /dev/zymkey ]; then
        step "Device node: /dev/zymkey ✓"
    else
        err "Device node: /dev/zymkey MISSING"
        echo "  Check I2C bus, wiring, and driver installation"
        echo "  Is this an actual SCM4 or a device with zymkey attached?"
        return 1
    fi

    # Python API
    if python3 -c "import zymkey" 2>/dev/null; then
        step "Python API: zymkey module ✓"
    else
        warn "Python API: zymkey module not found. Install: sudo apt install python3-zymkey"
    fi

    # Firmware
    local fw
    fw=$(python3 -c "import zymkey; print(zymkey.client.get_firmware_version())" 2>/dev/null || echo "unknown")
    echo "  Firmware: $fw"

    # Operational status
    local status
    status=$(python3 -c "import zymkey; print(zymkey.client.get_operational_status())" 2>/dev/null || echo "unknown")
    case "$status" in
        secure)     step "Status: secure ✓" ;;
        production) step "Status: production (locked) ✓" ;;
        *)          warn "Status: $status (not secure — check binding/tamper)" ;;
    esac

    # Device ID
    local devid
    devid=$(python3 -c "import zymkey; print(zymkey.client.get_unique_device_id())" 2>/dev/null || echo "unknown")
    echo "  Device ID: $devid"

    # Tamper events
    local tamper
    tamper=$(python3 -c "
import zymkey
events = zymkey.client.get_tamper_events()
print(len(events))
" 2>/dev/null || echo "unknown")
    if [ "$tamper" = "0" ]; then
        step "Tamper events: none ✓"
    elif [ "$tamper" != "unknown" ]; then
        warn "Tamper events: $tamper detected"
        python3 -c "import zymkey; [print(f'  {e}') for e in zymkey.client.get_tamper_events()]" 2>/dev/null || true
    fi

    # zkifc service
    if systemctl is-active --quiet zkifc 2>/dev/null; then
        step "zkifc service: running ✓"
    else
        warn "zkifc service: not running (start: sudo systemctl start zkifc)"
    fi

    # LED status
    step "LED should be: 1 blink every 3 seconds (system ready)"

    echo ""
    echo "Health check complete."
}

# ─── Disable Unattended Upgrades ──────────────────────────

cmd_disable_upgrades() {
    step "Disabling unattended-upgrades..."
    systemctl stop unattended-upgrades 2>/dev/null || true
    systemctl disable unattended-upgrades 2>/dev/null || true
    apt remove --purge unattended-upgrades -y 2>/dev/null || true
    step "Unattended upgrades disabled"
}

# ─── Configure Tamper Detection ──────────────────────────

cmd_tamper() {
    step "Configuring tamper detection..."

    python3 << 'PYEOF'
import zymkey

# Log current tamper events
events = zymkey.client.get_tamper_events()
print(f"Current tamper events: {len(events)}")

# Set perimeter detect actions (notify on breach, no self-destruct for PoC)
try:
    zymkey.client.set_perimeter_event_actions(
        action_notify=True,
        action_self_destruct=False
    )
    print("Perimeter detect: enabled (notify only)")
except Exception as e:
    print(f"Perimeter detect config: {e} (may already be set)")

# Check accelerometer
try:
    accel = zymkey.client.get_accelerometer_data()
    print(f"Accelerometer: {accel}")
except Exception as e:
    print(f"Accelerometer: not available ({e})")

print("Tamper detection configured.")
PYEOF

    step "Tamper detection setup complete"
    echo "  NOTE: Self-destruct is OFF for PoC."
    echo "  Enable in production: set action_self_destruct=True"
}

# ─── Encrypt USB Drive ────────────────────────────────────

cmd_encrypt_usb() {
    local device="${1:-}"
    if [ -z "$device" ]; then
        err "Usage: setup-zymbit.sh --encrypt-usb /dev/sdX"
        echo "  Available block devices:"
        lsblk -d -o NAME,SIZE,TYPE | grep disk
        exit 1
    fi

    if [ ! -b "$device" ]; then
        die "Device $device does not exist"
    fi

    echo ""
    warn "=== USB ENCRYPTION ==="
    warn "This will DESTROY all data on $device"
    warn "The encryption key will be permanently bound to this SCM4's zymkey."
    echo ""
    echo "Device: $device"
    lsblk "$device"
    echo ""
    read -p "Type 'ENCRYPT $device' to confirm: " confirm
    if [ "$confirm" != "ENCRYPT $device" ]; then
        echo "Aborted."
        exit 0
    fi

    step "Generating LUKS key..."
    local KEYFILE="/tmp/trinity-luks.key"
    dd if=/dev/urandom of="$KEYFILE" bs=64 count=1 2>/dev/null

    step "Locking key in zymkey HSM..."
    python3 << PYEOF
import zymkey
with open("$KEYFILE", "rb") as f:
    plaintext = f.read()
locked = zymkey.client.lock(plaintext)
with open("/etc/zymbit/trinity_key.bin", "wb") as f:
    f.write(locked)
print(f"Key locked to device: {zymkey.client.get_unique_device_id()}")
PYEOF

    step "Creating LUKS partition on $device..."
    cryptsetup luksFormat --type luks2 --key-file="$KEYFILE" "$device"

    step "Opening LUKS volume..."
    cryptsetup luksOpen --key-file="$KEYFILE" "$device" trinity_crypt

    step "Creating filesystem..."
    mkfs.ext4 -L TRINITY /dev/mapper/trinity_crypt

    step "Mounting at /mnt/trinity..."
    mkdir -p /mnt/trinity
    mount /dev/mapper/trinity_crypt /mnt/trinity

    step "Creating directory structure..."
    mkdir -p /mnt/trinity/autonomi/chunks
    mkdir -p /mnt/trinity/autonomi/logs
    mkdir -p /mnt/trinity/backup

    step "Cleaning up plaintext key..."
    shred -u "$KEYFILE"

    step "Adding to fstab..."
    if ! grep -q "/mnt/trinity" /etc/fstab; then
        echo "/dev/mapper/trinity_crypt /mnt/trinity ext4 defaults,noatime 0 2" >> /etc/fstab
    fi

    step "Adding to crypttab..."
    if ! grep -q "trinity_crypt" /etc/crypttab; then
        echo "trinity_crypt $device /etc/zymbit/trinity_key.bin luks" >> /etc/crypttab
    fi

    echo ""
    step "USB encryption complete!"
    echo "  Mount:    /mnt/trinity"
    echo "  Key:      /etc/zymbit/trinity_key.bin (locked to zymkey)"
    echo ""
    echo "  Verify:   df -h /mnt/trinity"
    echo "  Unmount:  sudo umount /mnt/trinity && sudo cryptsetup luksClose trinity_crypt"
}

# ─── Setup Hardware Wallet ────────────────────────────────

cmd_wallet() {
    step "Setting up Zymbit hardware wallet for Autonomi..."

    # Generate wallet and extract EVM address
    local wallet_output
    wallet_output=$(python3 << 'PYEOF'
import zymkey, hashlib, json, os

# Generate BIP32 master seed (secp256k1 for EVM/blockchain keys)
master = zymkey.client.gen_wallet_master_seed("secp256k1", "", "zknode-wallet")
print(f"MASTER_SLOT={master}")

# Generate child key for Autonomi rewards
rewards = zymkey.client.gen_wallet_child_key(master, 0, False)
print(f"REWARDS_SLOT={rewards}")

# Get public key
pubkey = zymkey.client.get_public_key(rewards)

# Derive EVM address (last 20 bytes of keccak256 of uncompressed pubkey)
keccak = hashlib.sha3_256(pubkey).digest()
evm_addr = "0x" + keccak[-20:].hex()
print(f"EVM_ADDRESS={evm_addr}")

# Write address to a file for docker compose
os.makedirs("/etc/zymbit", exist_ok=True)
with open("/etc/zymbit/rewards_address.txt", "w") as f:
    f.write(evm_addr)
print("ADDRESS_FILE=/etc/zymbit/rewards_address.txt")
PYEOF
)
    echo "$wallet_output"

    # Parse output
    local evm_addr
    evm_addr=$(echo "$wallet_output" | grep "EVM_ADDRESS=" | cut -d= -f2)
    local master_slot
    master_slot=$(echo "$wallet_output" | grep "MASTER_SLOT=" | cut -d= -f2)
    local rewards_slot
    rewards_slot=$(echo "$wallet_output" | grep "REWARDS_SLOT=" | cut -d= -f2)

    if [ -z "$evm_addr" ]; then
        err "Failed to generate wallet"
        exit 1
    fi

    # Update docker-compose.zymkey.yml with the rewards address
    local compose_file="$PROJECT_ROOT/docker-compose.zymkey.yml"
    if [ -f "$compose_file" ]; then
        # Replace placeholder or add environment variable
        if grep -q "ANT_REWARDS_ADDRESS" "$compose_file"; then
            sed -i "s|ANT_REWARDS_ADDRESS=.*|ANT_REWARDS_ADDRESS=$evm_addr|g" "$compose_file"
        else
            # Insert after ZYMBIT_WALLET_NAME line
            sed -i "/ZYMBIT_WALLET_NAME=/a\\      - ANT_REWARDS_ADDRESS=$evm_addr" "$compose_file"
        fi
        step "Updated $compose_file with rewards address: $evm_addr"
    fi

    # Also update the base docker-compose.yml placeholder
    local base_compose="$PROJECT_ROOT/docker-compose.yml"
    if [ -f "$base_compose" ] && grep -q "0x0000000000000000000000000000000000000000" "$base_compose"; then
        sed -i "s|0x0000000000000000000000000000000000000000|$evm_addr|g" "$base_compose"
        step "Updated $base_compose placeholder with real address"
    fi

    echo ""
    step "Wallet integrated with Autonomi node"
    echo "  Rewards address: $evm_addr"
    echo "  Master slot:     $master_slot"
    echo "  Rewards slot:    $rewards_slot"
    echo ""
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║  INTEGRATION STATUS                                 ║"
    echo "  ╠══════════════════════════════════════════════════════╣"
    echo "  ║  ✓ Rewards address set in ant-node config           ║"
    echo "  ║  ✓ Key stored in HSM (never leaves device)          ║"
    echo "  ║  ✓ EVM address derived from zymkey public key       ║"
    echo "  ║                                                      ║"
    echo "  ║  ⚠ Transaction signing NOT yet integrated           ║"
    echo "  ║    (requires ant-node code changes for HSM signing) ║"
    echo "  ║    To spend rewards: use zymkey wallet separately   ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo ""
    echo "  To set up SLIP39 recovery (3-of-5):"
    echo "    python3 -c \""
    echo "import zymkey"
    echo "m = zymkey.client.create_slip39_mnemonic(3, 5, $master_slot)"
    echo "for i, s in enumerate(m): print(f'Share {i+1}: {s}')\""
}

# ─── Lock to Production Mode ──────────────────────────────

cmd_production() {
    warn "=== PRODUCTION MODE LOCK ==="
    warn "This is IRREVERSIBLE."
    warn "All security policies become permanent."
    warn "The device cannot be reprogrammed after locking."
    echo ""
    warn "!!! CRITICAL: After locking, ANY change to /boot/config.txt will BRICK the device."
    warn "!!! Supervised Boot checks the config.txt hash against the signed manifest."
    warn "!!! Run 'sudo zbcli manifest --verify' before making any future boot changes."
    echo ""

    # Warn about config.txt changes
    local config_hash
    config_hash=$(sha256sum /boot/config.txt 2>/dev/null | cut -d' ' -f1 || echo "unknown")
    if [ "$config_hash" != "unknown" ]; then
        warn "Current /boot/config.txt hash: $config_hash"
        warn "If this changes after locking, the device will be bricked."
        echo ""
    fi

    # Check current status
    local status
    status=$(python3 -c "import zymkey; print(zymkey.client.get_operational_status())" 2>/dev/null || echo "unknown")
    if [ "$status" = "production" ]; then
        warn "Device is ALREADY in production mode."
        exit 0
    fi
    if [ "$status" != "secure" ]; then
        err "Device status is '$status', must be 'secure' to lock. Check tamper/binding."
        exit 1
    fi

    echo "Current status: secure"
    echo ""
    read -p "Type 'LOCK FOREVER' to proceed: " confirm
    if [ "$confirm" != "LOCK FOREVER" ]; then
        echo "Aborted."
        exit 0
    fi

    python3 -c "import zymkey; zymkey.client.lock_binding()"
    step "Production mode enabled. Device is now locked."
    step "Status: $(python3 -c "import zymkey; print(zymkey.client.get_operational_status())")"
    echo ""
    warn "!!! REMEMBER: Never modify /boot/config.txt on this device."
    warn "!!! If you must, update the manifest FIRST with: sudo zbcli update-config && sudo zbcli manifest --verify"
}

# ─── Full Setup ───────────────────────────────────────────

cmd_full() {
    echo "=== Zymbit SCM4 Full Setup ==="
    echo ""

    cmd_check
    echo ""

    cmd_disable_upgrades
    echo ""

    cmd_tamper
    echo ""

    step "All Zymbit security features configured."
    echo ""
    echo "Next steps (manual):"
    echo "  sudo ./scripts/setup-zymbit.sh --encrypt-usb /dev/sdX     # Encrypt USB drive"
    echo "  sudo ./scripts/setup-zymbit.sh --wallet                    # Set up hardware wallet"
    echo "  sudo ./scripts/setup-zymbit.sh --production                # Lock to production (IRREVERSIBLE)"
    echo ""
    echo "Then deploy zknode-autonomi with zymkey access:"
    echo "  docker compose -f docker-compose.yml -f docker-compose.zymkey.yml up -d"
}

# ─── Main ─────────────────────────────────────────────────

case "${1:-}" in
    --check)       cmd_check ;;
    --full)        cmd_full ;;
    --tamper)      cmd_tamper ;;
    --encrypt-usb) cmd_encrypt_usb "${2:-}" ;;
    --wallet)      cmd_wallet ;;
    --production)  cmd_production ;;
    *)
        echo "Usage: sudo ./scripts/setup-zymbit.sh [COMMAND]"
        echo ""
        echo "Commands:"
        echo "  --check               Health check (zymkey status, firmware, tamper)"
        echo "  --full                Full setup (check + tamper + disable upgrades)"
        echo "  --tamper              Configure tamper detection"
        echo "  --encrypt-usb DEV     Encrypt USB drive for chunk storage (e.g. /dev/sda)"
        echo "  --wallet              Set up hardware wallet for Autonomi rewards"
        echo "  --production          Lock device to production mode (IRREVERSIBLE)"
        echo ""
        echo "After setup, deploy with:"
        echo "  docker compose -f docker-compose.yml -f docker-compose.zymkey.yml up -d"
        exit 1
        ;;
esac
