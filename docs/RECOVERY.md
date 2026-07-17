# zknode-autonomi — Recovery Procedure

## Scenario: SD card failure / OS reinstall

If the Raspberry Pi's SD card dies or needs a clean OS install,
follow this procedure to restore from USB backup.

### Prerequisites

- Fresh Raspberry Pi OS (Bookworm) installed on new SD card
- USB drive with backups attached
- Internet connection
- 30 minutes

### Step 1: Base System Setup

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install dependencies
sudo apt install -y docker.io docker-compose-v2 git rsync curl

# Enable Docker
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
# Log out and back in
```

### Step 2: Restore from USB Backup

```bash
# Mount USB backup drive
sudo mkdir -p /mnt/backup
sudo mount /dev/sdX3 /mnt/backup  # adjust device name

# Find latest backup
ls -lt /mnt/backup/zknode/daily/ | head -5

# Choose a backup timestamp
BACKUP="20260717_050058"  # replace with actual
sudo rsync -a /mnt/backup/zknode/daily/$BACKUP/ /home/$USER/zknode-autonomi/

# Fix ownership
sudo chown -R $USER:$USER /home/$USER/zknode-autonomi
```

### Step 3: Restore Docker Images

```bash
cd /home/$USER/zknode-autonomi

# Pull images from registry (if CI/CD is set up)
docker pull ghcr.io/ethrx-dev/zknode-autonomi-alpha/mixnet-node:arm64
docker pull ghcr.io/ethrx-dev/zknode-autonomi-alpha/walletshield:arm64
docker pull ghcr.io/ethrx-dev/zknode-autonomi-alpha/dashboard:arm64
docker pull ghcr.io/ethrx-dev/zknode-autonomi-alpha/mixnet-proxy:arm64

# Or rebuild locally
docker build -f Dockerfile.mixnet -t zeros/mixnet-node-fixed:v0.0.84 .
docker build -f Dockerfile.walletshield -t walletshield-fixed:arm64 .
docker build -f Dockerfile.mixnet-proxy -t zeros/mixnet-proxy:arm64 .
cd zknode-dashboard && docker build -t zknode-dashboard:latest .
```

### Step 4: Deploy

```bash
cd /home/$USER/zknode-autonomi

# Optional: setup .env
cp .env.example .env  # if exists

# Start stack
docker compose up -d

# Verify
docker ps
curl http://127.0.0.1:8080/api/system
```

### Step 5: Post-Recovery

```bash
# Restore backup timers
sudo cp scripts/backup/zknode-backup.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now zknode-backup.timer
sudo systemctl enable --now zknode-backup-weekly.timer

# Verify mixnet consensus (wait 2-5 min for PKI)
docker logs mix-dirauth-1 --tail 10
# Look for "SIGNED" in output

# Test walletshield
curl -X POST http://127.0.0.1:9200/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

### Recovery Script

```bash
# Automated recovery
sudo ./scripts/recovery/zmnt-restore.sh /dev/sdX3 20260717_050058
```

See `scripts/recovery/zmnt-restore.sh` for the automated version.
