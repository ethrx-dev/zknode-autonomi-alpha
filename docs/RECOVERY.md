# zknode-autonomi — Recovery Procedure

## When to Use

- SD card corruption or failure
- Fresh OS install after hardware replacement
- Accidental config deletion

## Prerequisites

- Fresh Debian/Ubuntu install on SCM4
- USB backup drive with recent backup
- Network connectivity (for docker pull)

## Recovery Steps

### 1. Mount backup drive

```bash
sudo mkdir -p /mnt/backup
sudo mount /dev/sda3 /mnt/backup
```

List available backups:

```bash
ls -lt /mnt/backup/zknode/daily/
```

### 2. Run restore script

```bash
sudo ./scripts/recovery/zmnt-restore.sh /dev/sda3 20260717_050058
```

Replace `20260717_050058` with the timestamp of the backup to restore.

### 3. Start services

```bash
cd /home/<node-user>/zknode-autonomi
docker compose up -d
```

### 4. Verify

```bash
curl http://127.0.0.1:8080/api/health
```

Expected response: `{"status": "healthy", ...}`

## Manual Recovery (if restore script unavailable)

### Clone repo

```bash
git clone https://github.com/ethrx-dev/zknode-autonomi-alpha.git
cd zknode-autonomi-alpha
```

### Restore configs from backup

```bash
sudo rsync -a /mnt/backup/zknode/daily/<timestamp>/config/ ./config/
sudo chown -R <node-user>:<node-user> .
```

### Restore Docker images

```bash
while IFS= read -r img; do docker pull "$img"; done < /mnt/backup/zknode/daily/<timestamp>/docker-images.txt
```

### Start

```bash
sudo ./deploy.sh
```

## Backup Files

| Path | Contents |
|------|----------|
| `/mnt/backup/zknode/daily/` | Daily backups (7 day retention) |
| `/mnt/backup/zknode/weekly/` | Weekly backups (4 week retention) |
| `/mnt/backup/zknode/monthly/` | Monthly backups (3 month retention) |
| `docker-images.txt` | Snapshot of pulled Docker images |
| `docker-ps-all.txt` | Snapshot of container states |

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `docker compose up` fails | Missing .env file | `cp .env.example .env` and edit |
| PKI consensus doesn't form | Stale authority state | `docker compose down -v` then up again |
| Walletshield returns 502 | Mixnet not ready | Wait 2-3 min for PKI epoch |
| Dashboard 404 | Wrong branch | Check `git branch`, switch to `p4p-wiki-merge` |
