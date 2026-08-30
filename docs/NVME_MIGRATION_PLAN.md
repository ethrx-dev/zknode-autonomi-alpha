# NVMe Migration Plan — SCM4 Fleet Storage Offload

## Objective
Eliminate the recurring "wedged / no SSH" failure on the SCM4. Root cause: all heavy I/O
(docker data-root + ant-node data) sits on a **USB-attached mechanical HDD** (`/dev/sda`).
Docker operations saturate the USB SATA bridge + spinning disk, causing iowait 60-75%,
`jbd2/sda2`+`usb-storage`+`flush-8:0` in `D` state, and a wedged/frozen SSH.

The durable fix: **move the I/O-heavy paths onto a fast NVMe drive** and keep the USB HDD
only for cold bulk storage.

## Current Storage Map (captured pre-install)
```
/dev/sda 232.5G  USB HDD
|- sda2  63G ext4  /mnt/autonomi          -> docker data-root /mnt/autonomi/docker (19G; 21G free)
`- sda3 169G exfat /mnt/usb_sda3          -> antd node data  /mnt/usb_sda3/antd-data (128G used)

/mmcblk0 29.1G  root SD-crypto
|- mmcblk0p1  256M vfat  /boot          <- DO NOT TOUCH (supervised-boot signing required)
`- mmcblk0p2  cryptrfs ext4 /           <- 14G, 3G free (78%)
```

## Data paths and their I/O weight
| Path | Size | I/O load | Move to NVMe? |
|------|------|----------|---------------|
| `/mnt/autonomi/docker` (docker data-root) | 19G | HIGH (metadata, sandbox, network store) | **YES** |
| `/mnt/usb_sda3/antd-data/node-1` (ant-node data) | 128G | **VERY HIGH (storm generator)** | **YES** |
| `/var/lib/ant-node` (ant-node binary/var, root) | small | low | optional |
| `/home/zero-tech/.local/share/ant`, ant binds | small | low | no |
| `/home/zero-tech/zknode-autonomi/{config,data}` | small | low | no (configs stay) |
| `/var/lib/llm-wiki`, `.llm-wiki` | small | low | no |
| docker named volume (12K) | tiny | n/a | moves with data-root |

> ant-node (`antd`) is the confirmed I/O storm generator and writes to BOTH
> `/mnt/usb_sda3/antd-data` (node blocks) and `/var/lib/ant-node`. Moving `antd-data`
> to NVMe is the single biggest win; docker data-root on NVMe removes the slow
> metadata grind that previously made dockerd 50-90 min to activate.

## Recommended NVMe layout (proposed after hardware is installed)
```
/dev/nvme0n1  (size TBD, target >= 256G)
`- /dev/nvme0n1p1  ext4  /mnt/nvme
   |- /mnt/nvme/docker        <- docker data-root  (replaces /mnt/autonomi/docker)
   `- /mnt/nvme/antd-data     <- antd node data    (replaces /mnt/usb_sda3/antd-data)
```

## Migration Procedure (run AFTER NVMe is installed & partitioned)

### 0. Pre-flight safety
- Back up `/etc/docker/daemon.json` and this compose file to the repo (already versioned).
- Confirm SSH access to SCM4 and that load is LOW (< 5) before starting.
- Do NOT modify `/boot` (vfat, supervised-boot signing) — NVMe mount lives on `/mnt/nvme` (fstab, root fs, not boot).

### 1. Partition + format NVMe
```bash
# replace N with the real NVMe device/node
sudo swapon -a  # ensure swap available before big copy
sudo parted /dev/nvme0n1 --script mklabel gpt mkpart primary ext4 0% 100%
sudo mkfs.ext4 -F -L zknode-nvme /dev/nvme0n1p1
```

### 2. Mount + persist in fstab (append a line)
```bash
sudo mkdir -p /mnt/nvme
sudo mount /dev/nvme0n1p1 /mnt/nvme
# get UUID once mounted:  blkid /dev/nvme0n1p1
# add to /etc/fstab:
#   UUID=<nvme-uuid> /mnt/nvme ext4 defaults,nofail,x-systemd.device-timeout=30,noatime 0 2
sudo systemctl daemon-reload
```

### 3. Copy docker data-root and antd-data to NVMe
```bash
# Docker data-root (STOP docker first so store is quiescent)
sudo systemctl stop docker
sudo du -sh /mnt/autonomi/docker          # confirm 19G
sudo rsync -aHAXx /mnt/autonomi/docker/ /mnt/nvme/docker/

# antd node data
sudo du -sh /mnt/usb_sda3/antd-data
sudo rsync -aHAXx /mnt/usb_sda3/antd-data/ /mnt/nvme/antd-data/
```

### 4. Repoint docker data-root
```bash
# /etc/docker/daemon.json  -> "data-root": "/mnt/nvme/docker"
sudo mkdir -p /mnt/nvme/docker
sudo systemctl start docker   # verify: docker info | grep 'Docker Root Dir'
```

### 5. Repoint antd's node-data bind in compose
- In `docker-compose.yml` change antd's bind:
  `/mnt/usb_sda3/antd-data/node-1:/var/lib/antd/node-1:rw`
  → `/mnt/nvme/antd-data/node-1:/var/lib/antd/node-1:rw`

### 6. Keep old HDD paths as cold bulk only (optional)
- `/mnt/usb_sda3` (exfat) can stay mounted for `/mnt/usb_sda3/antd-data` archive/cold
  backups; the LATEST node data lives on NVMe.

### 7. Preserve the boot-time I/O controller unit (already active)
- `zknode-io-controller.service` must remain enabled — it enables `+io` on
  `system.slice` BEFORE docker starts so docker can apply `blkio_config` (antd
  throttle) to running containers. Verify after reboot:
  `cat /sys/fs/cgroup/system.slice/cgroup.subtree_control` → contains `io`.

### 8. Post-migration verification
- `docker info | grep 'Docker Root Dir'` → `/mnt/nvme/docker`
- `docker compose up -d` brings whole fleet up; confirm all 18-19 containers `Up`
- Reboot test: confirm docker activates in seconds (not minutes), SSH never wedges,
  load stays low during fleet start, antd `io.max` present on its cgroup.

## Rollback
- If NVMe mount fails to persist (nofail protects boot), docker/antd data stays on the
  HDD unless the copy destroyed it. Copy is rsync (non-destructive); only delete HDD
  copies after confirming the NVMe copy is healthy for a full reboot cycle.
- Safest order: mount NVMe -> rsync -> repoint -> verify -> REBOOT and verify again ->
  only then `rm -rf /mnt/autonomi/docker.old` / old antd-data if space reclaim needed.

## Persistence units / timers already in place (keep)
- `zknode-io-controller.service`  : `+io` on system.slice before docker  (enabled)
- `zknode-dirauth-realign.{service,timer}` : restarts 3 dirauths every 4h (enabled)
