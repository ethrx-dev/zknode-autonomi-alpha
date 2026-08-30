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

## PCIe lane conflict — CRITICAL hardware constraint (verified live)

The SCM4 (CM4) exposes exactly **ONE PCIe Gen2 x1 lane** (Zymbit spec: "1 x PCIe
1-lane Host, Gen 2 (5Gbps)"). The Secure Base Board's M.2 slot (J12) connects to that
single lane.

Live probe (post-reboot, NVMe installed but NOT detected) shows the lane is held by the
USB3 controller with **no PCIe switch**:
```
lspci -tv
[0000:00]---00.0-[01]----00.0  VIA Technologies, Inc. VL805 USB 3.0 Host Controller
```
- Only one device on the lane: the **VL805 USB3 controller** (which the current USB HDD
  `sda` depends on). No NVMe, no PCIe switch, no second root port.
- Therefore NVMe and the USB3 (VL805) **cannot both be active on the same lane at once**
  on this board. This is why the M.2 NVMe does not enumerate (`/dev/nvme*` absent).

### Physical verification needed before assuming the lane conflict is the cause
1. Power OFF fully, then re-seat/confirm the NVMe in **J12** (M.2 slot). It must be
   **fully seated, latched, and powered** (dedicated 15W/3.3V-5A supply; position 1 of
   SW1 stays open on CM4/SCM4 — that pin is Reserved, do not close).
2. Confirm the card is a compatible **M.2 B-key / B+M-key** NVMe, form factor
   **2242 / 2260 / 2280** (Zymbit community-verified sizes). An M-key-only card will not
   fit B-key keying.
3. Confirm the carrier model. If it uses a **PCIe switch** (e.g. ASMedia 1806 /
   PI7C9X2G404SL), BOTH USB3 and M.2 can coexist — then the NVMe simply needs driver/
   enable and the "no switch" finding above would be wrong for this specific board. If it
   has NO switch (as lspci indicates), the lane must be given to the M.2 by **disabling /
   depopulating the VL805 USB3** — losing the current HDD path (acceptable IF the data is
   moved to NVMe first, but it must be planned so the boot/OS is not left without storage).
4. Do NOT change `BOOT_ORDER`/EEPROM or any `/boot` config to force NVMe boot — this unit
   is under Zymbit Supervised Boot (see Security section) and `rpiboot` is disabled; a bad
   boot change can brick it. If NVMe boot is never required (we only need NVMe as data
   storage), no EEPROM/BOOT_ORDER change is needed — the kernel merely needs to see the
   NVMe at runtime on the freed lane.

### Outcome decision
- If the board has a **PCIe switch**: proceed — USB3 + M.2 coexist; just enable the NVMe
  driver/mount and run the migration below.
- If the board has **no switch** (current evidence): choose either
  (A) give the lane to the **M.2 NVMe** (disable VL805/USB3) and migrate docker data-root
      + antd-data there — the current HDD becomes unavailable (back it up first), or
  (B) keep the **USB HDD + antd blkio throttle** (already active and working — this alone
      fixed the wedge) and drop the NVMe idea.

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

## Security / Tamper Analysis (Zymbit SBS + Greenfield IFS on SCM4)

This SCM4 runs **Zymbit Supervised Boot (SBS) with Greenfield IFS-encrypted root**.
Understanding the trust chain is REQUIRED before any hardware or boot work. A mistake in
this area can **lock/brick the unit.**

### Verified boot/security architecture (as-configured)
- ROOT is LUKS-encrypted: `/dev/mmcblk0p2` (crypto_LUKS) → `cryptrfs` (ext4 `/`).
- Unlock happens at **preboot** via `zk_get_key` keyscript; the LUKS key blob is stored
  internally in the Zymkey M3 (`/var/lib/zymbit/key.bin.lock`) and released ONLY after
  the signed boot chain passes (`/boot/zboot/scripts/create-initramfs.sh` lines 60/66/
  104-128/161-162).
- `/boot/config.txt` ends with (Signed-chain markers):
  ```
  [all]         initramfs initrd.img followkernel
  # Zymbit      kernel=u-boot.bin   arm_64bit=1   enable_uart=1
  ```
- `/boot/zb_config.enc` (912B) is the signed Zymbit boot config; `u-boot.bin` is the
  **signed U-Boot** verified by the CM4 ROM.

### NO-GO — touching ANY of these can LOCK/BRICK the SCM4 (halt at preboot, no LUKS unlock)
1. `/boot/config.txt` — do NOT remove/alter the `dtoverlay=dwc2,dr_mode=host` line or
   the `kernel=u-boot.bin` / `initramfs` markers.
2. `/boot/cmdline.txt`, `/boot/u-boot.bin`, `/boot/initrd.img`, `/boot/kernel8.img`,
   `/boot/overlays/*`, `/boot/zb_config.enc` — all signature-verified. Any change breaks
   verification -> U-Boot halts -> IFS never unlocks -> no boot until re-enrolled/signed
   via `zbcli imager` + the Zymkey private key.
3. LUKS key slots / `/etc/crypttab*` / the Zymkey IFS slot binding.
4. `unattended-upgrades` (AGENTS.md): can repackage kernel/initramfs and break the chain.
5. Setting `tamper_policy` to self-destruct during development.
- **This migration plan NEVER touches any of the above.**

### Why the NVMe plan is SAFE (no lock / no brick)
- `/etc/fstab`, `/etc/docker/daemon.json`, and `docker-compose.yml` all live on the
  **already-decrypted, running rootfs** (`cryptrfs`, mounted rw). They are NOT part of the
  U-Boot / Zymkey trust chain and are NOT measured at preboot. Editing them after boot is
  normal OS configuration and cannot trip Secure Boot verification or the tamper latch.
- The new NVMe is separate storage: partitioning/formatting/mounting it (new `/mnt/nvme`
  fstab entry) does not modify the boot chain, the LUKS root, or the Zymkey key material.
- Tamper is a **dedicated hardware GPIO latch on the Zymkey**, not a software check of OS
  files. Adding a PCIe NVMe + fstab entry cannot set that latch.

### Physical-install caveat (the ONLY real risk — avoid at all cost)
The Zymkey tamper latch is ARMED on this unit (enroll present under
`/var/lib/zymbit/<m3id>/`). To avoid tripping it during the NVMe install:
- **Power off fully** (unplug or clean OS shutdown + PSU off) before inserting the NVMe.
- Do NOT hot-swap, unplug, or lose power on the Zymkey module / its USB (usb 3-1.1) or GPIO.
- Do NOT short or touch the tamper/GPIO region; insert the NVMe card cleanly and carefully
  into the PCIe M.2 slot with no contact to the Zymkey area.
- Use a stable PSU; avoid shocks/movement while powered (`boot handling` per AGENTS.md:
  let the 90s supervise-boot sequence complete; watch the LED: 1 blink/sec = initializing,
  1->2->3->4 = SBS verifying, rapid = passed).
- Avoid hot-plugging USB devices during operation.
- The LUKS USB pool currently present (`/mnt/autonomi`, sda2 ext4; `/mnt/usb_sda3`,
  sda3 exfat) is **NOT LUKS-encrypted** despite AGENTS.md describing a zymkey-bound
  `/mnt/trinity`. Do not assume HSM binding on these volumes; treat them as plain,
  non-tamper-protected storage and back them up before repointing.

### If a tamper event IS ever triggered (recovery background)
- Policy here is notify/halt (not self-destruct) per AGENTS.md setup. A tripped latch
  halts the unit at preboot; it does NOT destroy keys. You must clear tamper events and
  re-verify the Zymkey is in `secure` state BEFORE expecting the next boot to unlock LUKS:
  `python3 -c "import zymkey; print(zymkey.client.get_operational_status())"`.
  (Contact Zymbit support before attempting field recovery of the eMMC/boot chain.)

## Persistence units / timers already in place (keep)
- `zknode-io-controller.service`  : `+io` on system.slice before docker  (enabled)
- `zknode-dirauth-realign.{service,timer}` : restarts 3 dirauths every 4h (enabled)
