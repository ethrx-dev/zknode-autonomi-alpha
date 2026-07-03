# zknode-autonomi — Zymbit/SCM4 Setup Guide

> Comprehensive setup for the Zymbit Secure Compute Module 4 (SCM4) with all security features enabled: zymkey HSM, Bootware, LUKS encryption, tamper detection, hardware wallet, and production locking.

---

## 1. Hardware Overview

The SCM4 integrates a Raspberry Pi CM4 with a Zymbit Hardware Security Module into a single tamper-encapsulated module.

| Feature | Description |
|---------|-------------|
| **CPU** | Broadcom BCM2711, quad-core Cortex-A72 @ 1.5 GHz |
| **RAM** | 8 GB LPDDR4-3200 |
| **eMMC** | 32 GB (pre-encrypted, not field-replaceable) |
| **HSM** | Zymbit security co-processor (USB serial /dev/ttyACM7) |
| **Boot** | Supervised Boot (verified boot chain) |
| **Tamper** | Perimeter breach, accelerometer, voltage monitoring |
| **Pinout** | 100% CM4 compatible |
| **OS** | Pre-loaded Debian Bookworm 64-bit |

### LED Status Sequence (90s boot)

| Pattern | Meaning |
|---------|---------|
| 1 slow blink | Initializing SCM |
| 1→2→3→4 blinks | Supervised Boot verifying signature |
| Rapid blinking | Boot verification passed, booting OS |
| Off (seconds) | USB enumeration |
| 1 blink / 3s | zkifc loaded, system ready |

---

## 2. Initial SCM4 Setup

### Default Credentials

```
Hostname: ######
Username: ######
Password: ######
```

**Change password on first login:**

```bash
passwd
sudo passwd ######  # also change root
```

### Verify Zymbit Hardware

```bash
# Check USB serial device (zymkey on SCM4 uses USB ACM, not I2C)
ls -la /dev/ttyACM* /dev/zscm_*

# Check zkifc systemd service
systemctl status zkifc

# Verify firmware
python3 -c "import zymkey; print(zymkey.client.get_firmware_version())"

# Check operational status (should return "secure")
python3 -c "import zymkey; print(zymkey.client.get_operational_status())"

# Get device serial number / unique ID
python3 -c "import zymkey; print(zymkey.client.get_unique_device_id())"
```

Expected output:
```
/dev/zymkey          ← device node exists
01.02.02release      ← firmware version
secure               ← operational status
<hex-string>         ← unique device ID
```

### Critical: Disable Unattended Upgrades

Zymbit warns unattended-upgrades can break encrypted boot:

```bash
sudo systemctl stop unattended-upgrades
sudo systemctl disable unattended-upgrades
sudo apt remove --purge unattended-upgrades -y
```

### Critical: Never Remove dtoverlay

The SCM requires `dtoverlay=dwc2,dr_mode=host` in `/boot/config.txt`. Removing this **bricks** the unit because the eMMC is pre-encrypted and `rpiboot` is disabled.

```bash
grep dwc2 /boot/config.txt
# Expected: dtoverlay=dwc2,dr_mode=host
```

---

## 3. Bootware™ — Supervised Boot

Bootware provides verified boot with tamper-responsive policies.

### 3.1 Check Bootware Status

```bash
# Verify bootloader
vcgencmd bootloader_version
# Expected: 1/11/2023 (or later)

# Check Bootware installation
zbcli --version 2>/dev/null || echo "Bootware CLI not installed"
```

### 3.2 Install/Update Bootware

```bash
# Install Bootware CLI
curl -sSL https://s3.amazonaws.com/zk-sw-repo/install_zbcli.sh | sudo bash

# Verify
zbcli --version
```

### 3.3 Configure Boot Policies

```bash
# Generate default config
sudo zbcli update-config

# View current policies
sudo zbcli manifest
```

**Boot Policies (editable in /etc/zymbit/bootware/config.toml):**

| Policy | Description | Recommended |
|--------|-------------|-------------|
| `verify_boot` | Validate boot artifacts | `true` |
| `verify_kernel` | Validate kernel image | `true` |
| `encrypt_root` | Require encrypted root | `true` |
| `tamper_policy` | Action on tamper detect (1=halt, 2=self-destruct) | `2` |

### 3.4 Sign Custom Software Images

```bash
# Create a signed image of your root filesystem
sudo zbcli imager --include /home/zymbit/zknode-autonomi

# Verify signature
sudo zbcli manifest --verify
```

---

## 4. Root File System Encryption (LUKS + zymkey)

The SCM4 ships with a pre-encrypted eMMC. To encrypt external USB storage (for the chunk DB), use LUKS with zymkey-bound keys.

### 4.1 Option A: Encrypt USB Drive (Recommended for zknode-autonomi)

```bash
# Run the official Zymbit script for external USB encryption
curl -sSL https://s3.amazonaws.com/zk-sw-repo/mk_encr_ext_rfs.sh | sudo bash

# Or with custom device:
# sudo bash mk_encr_ext_rfs.sh -x /dev/sdX -p 1
```

This creates a LUKS volume on the USB drive with the key locked to the zymkey HSM:
- LUKS key generated randomly
- Key encrypted and signed by zymkey → `/etc/zymbit/encr_key.bin`
- USB partition encrypted with dm-crypt/LUKS
- Auto-unlock on boot (initramfs presents locked key to zymkey)

### 4.2 Option B: Manual LUKS Setup for Data Partition

For the Autonomi chunk DB (non-root partition):

```bash
# 1. Generate a random LUKS key
sudo dd if=/dev/urandom of=/tmp/luks.key bs=64 count=1

# 2. Lock the key with zymkey
python3 << 'EOF'
import zymkey
with open('/tmp/luks.key', 'rb') as f:
    plaintext = f.read()
locked = zymkey.client.lock(plaintext)
with open('/etc/zymbit/trinity_key.bin', 'wb') as f:
    f.write(locked)
print(f"Key locked to device: {zymkey.client.get_unique_device_id()}")
EOF

# 3. Create LUKS partition on USB drive
DEV="/dev/sda1"  # adjust to your USB device
sudo cryptsetup luksFormat --key-file=/tmp/luks.key "$DEV"
sudo cryptsetup luksOpen --key-file=/tmp/luks.key "$DEV" trinity_crypt

# 4. Format and mount
sudo mkfs.ext4 /dev/mapper/trinity_crypt
sudo mkdir -p /mnt/trinity
sudo mount /dev/mapper/trinity_crypt /mnt/trinity

# 5. Clean up plaintext key
sudo shred -u /tmp/luks.key

echo "USB drive encrypted and mounted at /mnt/trinity"
```

### 4.3 Auto-Unlock on Boot

Create an initramfs hook to unlock at boot:

```bash
# /etc/initramfs-tools/hooks/zymbit-unlock
cat << 'EOF' | sudo tee /etc/initramfs-tools/hooks/zymbit-unlock
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0;; esac

. /usr/share/initramfs-tools/hook-functions
copy_exec /usr/bin/python3 /usr/bin/
copy_exec /etc/zymbit/trinity_key.bin /etc/zymbit/
EOF

sudo chmod +x /etc/initramfs-tools/hooks/zymbit-unlock
sudo update-initramfs -u
```

---

## 5. Tamper Detection

### 5.1 Perimeter Detect

Wire a tamper loop through the enclosure. The SCM detects when the loop is broken (enclosure opened).

**Circuit:** Connect a wire between the two perimeter detect pins on the SCM carrier board. Any break triggers a tamper event.

```bash
# Check tamper status
python3 << 'EOF'
import zymkey
events = zymkey.client.get_tamper_events()
if events:
    for e in events:
        print(f"Tamper event: {e}")
else:
    print("No tamper events detected")
EOF
```

### 5.2 Accelerometer (Shock/Orientation)

The SCM has a built-in accelerometer that detects:
- Physical shock/vibration
- Orientation change (device moved)
- Acceleration anomalies

```bash
# Check accelerometer status
python3 -c "import zymkey; print(zymkey.client.get_accelerometer_data())"
```

### 5.3 Power Monitoring

| Monitor | Detection |
|---------|-----------|
| Main power | Voltage drop / power loss |
| Battery | Battery removal / low battery |
| Last Gasp | Capacitor drain → emergency key erase |

### 5.4 Configuring Tamper Responses

```bash
# Set tamper action policy
# 0 = log only (development)
# 1 = halt system (production)
# 2 = self-destruct keys (high security)
python3 << 'EOF'
import zymkey
# Set perimiter detect sensitivity
zymkey.client.set_perimeter_event_actions(
    action_notify=True,
    action_self_destruct=False  # Set True for production
)
print("Perimeter detect configured")
EOF
```

---

## 6. Hardware Wallet & Key Management

### 6.1 Generate Wallet Master Seed

```bash
python3 << 'EOF'
import zymkey

# Generate BIP32 master seed (stored in HSM, never leaves device)
seed = zymkey.client.gen_wallet_master_seed(
    "secp256k1",     # curve for blockchain keys
    "",              # optional passphrase
    "zknode-wallet"  # wallet name
)
print(f"Master seed slot: {seed}")

# Generate child key for Autonomi rewards
rewards_key = zymkey.client.gen_wallet_child_key(seed, 0, False)
print(f"Rewards key slot: {rewards_key}")

# Get public key (safe to share)
pubkey = zymkey.client.get_public_key(rewards_key)
print(f"Public key: {pubkey.hex()}")
EOF
```

### 6.2 SLIP39/Shamir's Secret Sharing Recovery

```bash
# Set up recovery (3-of-5 threshold)
python3 << 'EOF'
import zymkey

# Generate recovery mnemonic (split into 5 shares, need 3 to recover)
master_seed = zymkey.client.gen_wallet_master_seed("secp256k1", "", "recoverable-wallet")
mnemonics = zymkey.client.create_slip39_mnemonic(3, 5, master_seed)

print("=== STORE THESE SECURELY ===")
for i, m in enumerate(mnemonics):
    print(f"Share {i+1}: {m}")
print("Any 3 of 5 shares can recover the wallet.")
EOF
```

### 6.3 Key Operations (Encrypt, Sign, Verify)

```bash
# Encrypt data with zymkey
python3 << 'EOF'
import zymkey

data = b"zknode-autonomi secret data"
locked = zymkey.client.lock(data)
print(f"Encrypted: {locked.hex()[:64]}...")

# Unlock (only succeeds on original device)
unlocked = zymkey.client.unlock(locked)
print(f"Decrypted: {unlocked.decode()}")

# Sign data
key_slot = 0  # use generated key slot
signature = zymkey.client.sign(key_slot, data)
print(f"Signature: {signature.hex()[:64]}...")

# Verify
verified = zymkey.client.verify(key_slot, data, signature)
print(f"Verified: {verified}")
EOF
```

---

## 7. Production Mode Locking

**WARNING: Production mode is IRREVERSIBLE. All security policies become permanent.**

### 7.1 Pre-Production Checklist

- [ ] All keys generated and backed up (SLIP39 mnemonics stored securely)
- [ ] Bootware policies tested
- [ ] Tamper responses verified
- [ ] LUKS encryption tested (reboot verified to unlock)
- [ ] Application software deployed
- [ ] Wallet addresses recorded
- [ ] System boots unattended (no console interaction needed)

### 7.2 Lock to Production Mode

```bash
sudo python3 << 'EOF'
import zymkey

# Verify operational status
status = zymkey.client.get_operational_status()
if status != "secure":
    print(f"ERROR: Device not secure (status: {status})")
    exit(1)

print("=== PRODUCTION MODE LOCK ===")
print("This action is IRREVERSIBLE.")
print("All security policies will become permanent.")
print("Keys will be permanently bound to this device.")
response = input("Type 'LOCK FOREVER' to proceed: ")

if response == "LOCK FOREVER":
    zymkey.client.lock_binding()
    print("Production mode enabled. Device is now locked.")
    print("Firmware version will change to production variant.")
else:
    print("Aborted.")
EOF
```

### 7.3 Verify Production Lock

```bash
python3 -c "import zymkey; print(zymkey.client.get_operational_status())"
# Expected: "production"
```

---

## 8. Zymbit-zknode Integration

### Wallet Type Selection

zknode-autonomi supports two wallet modes, configured via `.env`:

| Setting | Description | Use Case |
|---------|-------------|----------|
| `WALLET_TYPE=standard` | Plain EVM private key in `.env` | Any machine, development, testing |
| `WALLET_TYPE=zymkey` | Keys generated and stored in HSM | SCM4 production, high security |

**Standard wallet** (any machine):
```bash
./scripts/gen-wallet.sh --apply      # Generate EVM wallet, auto-apply to config
```

**Zymkey wallet** (SCM4 only):
```bash
sudo ./scripts/setup-zymbit.sh --wallet  # Generate keys in HSM, auto-apply to config
```

Both commands set `ANT_REWARDS_ADDRESS` automatically. The difference is where the private key lives: `.env` (standard) vs HSM (zymkey).

### 8.1 What Works Today (PoC)

| Feature | Status | How |
|---------|--------|-----|
| **Key generation** | ✅ | Wallet keys generated in HSM via `setup-zymbit.sh --wallet` |
| **EVM address** | ✅ | Public key → keccak256 → EVM address, set as `ANT_REWARDS_ADDRESS` |
| **Receive rewards** | ✅ | Autonomi sends rewards to the EVM address (standard ERC-20 transfer) |
| **USB encryption** | ✅ | LUKS key locked in zymkey, auto-unlocked on boot |
| **Device authentication** | ✅ | zymkey binding ensures only this SCM4 can unlock storage |
| **Tamper detection** | ✅ | Perimeter breach, shock, power loss monitoring active |

### 8.2 What Requires Code Changes (Future)

| Feature | Status | What's Needed |
|---------|--------|---------------|
| **HSM transaction signing** | ❌ | ant-node needs zymkey signing support for reward claims |
| **HSM key custody** | ❌ | ant-node's EVM key management would need zymkey API integration |
| **Attestation** | ❌ | Prove to Autonomi network that keys are HSM-backed |

**Current architecture**: The zymkey wallet generates keys and stores them in the HSM. The EVM address is passed to ant-node via `ANT_REWARDS_ADDRESS`. Rewards arrive at that address. To spend rewards, use the zymkey wallet separately (outside ant-node).

**Future architecture**: ant-node calls zymkey API directly to sign EVM transactions for reward claims, payment verification, and stake operations — all private keys never leave the HSM.

### 8.3 Docker Access to zymkey

```bash
# Add zymkey device to Docker compose (see docker-compose.zymkey.yml)
# The container needs:
#   - Device: /dev/zymkey:/dev/zymkey
#   - Volume: /etc/zymbit:/etc/zymbit:ro (for locked keys)
#   - Volume: /var/lib/zymbit:/var/lib/zymbit (for runtime state)

# Test container access
docker run --rm --device /dev/zymkey \
    --platform linux/arm64 \
    zeros/mixnet-node:arm64 \
    sh -c "ls /dev/zymkey && echo 'zymkey accessible'"
```

### 8.4 Encrypt USB Pool with zymkey

The `./scripts/setup-zymbit.sh` script automates USB pool encryption:

```bash
sudo ./scripts/setup-zymbit.sh --encrypt-usb /dev/sda
```

This:
1. Detects USB drive
2. Generates LUKS key
3. Locks key in zymkey HSM
4. Creates LUKS partition
5. Formats as ext4
6. Mounts at /mnt/trinity
7. Configures auto-unlock on boot

### 8.5 Detect zymkey in ant-node

```bash
# Check if ant-node can see zymkey (requires docker-compose.zymkey.yml)
docker exec ant-node ls /dev/zymkey 2>/dev/null && echo "accessible" || echo "not accessible (use docker-compose.zymkey.yml)"
```

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| No `/dev/zymkey` | I2C bus not enabled | `sudo raspi-config` → Interface Options → I2C → Enable |
| `zkifc` not blinking | zkifc service not running | `sudo systemctl restart zkifc` |
| Boot hangs on rainbow | Corrupted boot partition | Contact Zymbit support (eMMC not field-recoverable) |
| LUKS won't unlock | zymkey not "secure" state | Check tamper events; verify binding |
| Key slots 16+ vanish on reboot | SCM FW 01.02.02release bug | Use BIP32 wallet instead of `gen_key_pair()` |
| `gen_key_pair` not available | Python API missing | `sudo apt install python3-zymkey` |
| Perimeter detect false triggers | Floating GPIO | Add pull-up resistor to tamper circuit |

### Quick Health Check Script

```bash
python3 << 'EOF'
import zymkey
print(f"Firmware:    {zymkey.client.get_firmware_version()}")
print(f"Status:      {zymkey.client.get_operational_status()}")
print(f"Device ID:   {zymkey.client.get_unique_device_id()}")
events = zymkey.client.get_tamper_events()
print(f"Tamper:      {len(events)} events")
EOF
```

---

## 10. References

- [Zymbit SCM Documentation](https://docs.zymbit.com/hardware/components/scm/)
- [Bootware Getting Started](https://docs.zymbit.com/bootware/1.3.2/getting-started/)
- [Encrypt Root File System](https://docs.zymbit.com/tutorials/encrypt-rfs/)
- [Perimeter Detect for SCM](https://docs.zymbit.com/tutorials/perimeter-detect/scm/)
- [Production Mode](https://docs.zymbit.com/tutorials/production-mode/)
- [Hardware Wallet Tutorial](https://docs.zymbit.com/tutorials/digital-wallet/wallet-example/)
- [API Documentation (Python/C/C++)](https://docs.zymbit.com/api/)

---

## 11. Docker Compose vs Systemd (zkifc)

The `docker-compose.yml` originally defined a `zkifc` container that was **broken on the SCM4**:

- Used `alpine:3.21` which lacks the `zkifc` binary
- Mapped `/dev/zymkey` (I2C) but the SCM4 exposes the zymkey as USB serial (`/dev/ttyACM7`)
- The host already runs `zkifc.service` via systemd, making the Docker container redundant

**Correct approach:** The zymkey is managed by the host-level `zkifc.service` (systemd), running as user `zymbit`. Containers that need HSM access should bind-mount `/dev/ttyACM7` and `/var/lib/zymbit/`.

```bash
# Check HSM is running
systemctl status zkifc

# Verify device
ls -la /dev/ttyACM7 /dev/zscm_7

# Docker containers needing HSM should mount:
# - /dev/ttyACM7:/dev/ttyACM7
# - /var/lib/zymbit:/var/lib/zymbit:ro
```

The broken Docker `zkifc` container has been removed from the compose.
- [SCM Troubleshooting](https://docs.zymbit.com/troubleshooting/scm/)
