# SCM4 Storage Analysis & Decision — Wedge Fix (was "NVMe Migration Plan")

## Decision (FINAL, 2026-08-30)
**Keep the USB HDD + the antd blkio throttle.** Do NOT pursue NVMe on this board.

Reason: the carrier is a **Waveshare CM4-DUAL-ETH-4G/5G-BASE**. Its M.2 slot is
**B-key, USB-only** (for 4G/5G cellular modules) — Waveshare states *"M.2 B KEY only
extends USB 3.0 interfaces, it doesn't support PCIe devices."* The CM4's **single PCIe
Gen2 x1 lane** is consumed by the onboard **VL805 USB3 hub**. This board has **no
PCIe/NVMe path**, so no NVMe can be added here. The existing antd I/O throttle already
resolved the wedge with zero hardware risk.

## Objective (original)
Eliminate the recurring "wedged / no SSH" failure on the SCM4. Root cause: all heavy I/O
(docker data-root + ant-node data) sits on a USB-attached mechanical HDD (`/dev/sda`).
Docker operations saturate the USB SATA bridge + spinning disk → iowait 60-75%,
`jbd2/sda2`+`usb-storage`+`flush-8:0` in `D` state, and a wedged/frozen SSH.

## The wedge fix that WORKS (do not regress)
- **antd (ant-node) is the I/O storm generator**, writing data + logs to
  `/mnt/usb_sda3/antd-data` (sda3) and `/mnt/autonomi/docker` (sda2) — same physical disk.
- Fix = **blkio throttle** on the antd container:
  - docker-compose.yml `antd.blkio_config`: `device_write_bps` 40 MB/s,
    `device_read_bps` 100 MB/s on `/dev/sda`.
  - Requires the **io cgroup controller** on `system.slice`; persists via the systemd
    oneshot **`zknode-io-controller.service`** (enables `+io` BEFORE docker starts).
  - With the io controller enabled, docker applies the limit at every container start —
    verified live: `8:0 rbps=104857600 wbps=41943040` on the new antd cgroup.
- Result: load no longer death-spirals to 40-70 and wedges the box.

## Carrier-board hardware constraints (verified)
- CM4/SCM4 exposes exactly **ONE PCIe Gen2 x1 lane**.
- Wavehsare CM4-DUAL-ETH-4G/5G-BASE uses that lane for the **VL805 USB3 hub**
  (live `lspci`: bare root → `01:00.0 VIA VL805`), and a USB **RTL8153** for ETH1.
- Its **M.2 B-key slot is USB-only** (cellular modems), NOT PCIe → NVMe impossible.
- No PCIe switch on the bus, so USB3 and any PCIe device could not coexist anyway.

### Future options if the bottleneck ever needs fixing again
1. **Fast USB 3.2 SSD** (same USB3 port, no board/carrier change, no re-bind risk) — best
   realistic upgrade; much faster random I/O than the spindle.
2. Move SCM/CM4 to an **NVMe-capable carrier** (e.g. Waveshare CM4-IO-BASE-B / PoE UPS
   Base with M.2 M-key) — large change, must re-bind Zymkey/eMMC/boot on new carrier:
   highest risk under Supervised Boot. Not recommended without Zymbit involvement.

## Current Storage Map (as-found)
```
/dev/sda 232.5G  USB HDD  (via VL805 USB3 hub)
|- sda2  63G ext4  /mnt/autonomi          docker data-root /mnt/autonomi/docker (19G)
`- sda3 169G exfat /mnt/usb_sda3          antd node data  /mnt/usb_sda3/antd-data (128G used)

/mmcblk0 29.1G  root SD-crypto
|- mmcblk0p1 vfat /boot            <-- DO NOT TOUCH (supervised-boot signing)
`- mmcblk0p2 crypto_LUKS -> cryptrfs /  (LUKS root, unlocked at preboot by zymkey)
```

## Security / Tamper Analysis (Zymbit SBS + Greenfield IFS)
This SCM4 runs **Zymbit Supervised Boot (SBS) with Greenfield IFS-encrypted LUKS root**.
- `/dev/mmcblk0p2` (crypto_LUKS) → `cryptrfs` (ext4 `/`), unlocked at preboot by
  `zk_get_key` keyscript bound to the **Zymkey M3** (`key.bin.lock`).
- `/boot/config.txt` ends: `initramfs initrd.img followkernel` +
  `kernel=u-boot.bin` (signed U-Boot) + `zb_config.enc` (signed config).
- The whole boot chain is **signature-verified** by the CM4 ROM.

### NO-GO (any of these can LOCK/BRICK the SCM4)
1. `/boot/config.txt`, `cmdline.txt` — incl. the `dtoverlay=dwc2,dr_mode=host` line.
2. `/boot/u-boot.bin`, `initrd.img`, `kernel8.img`, `overlays/*`, **`zb_config.enc`**.
3. LUKS key slots / `/etc/crypttab*` / Zymkey IFS slot binding.
4. `unattended-upgrades` (can repackage kernel/initramfs and break the chain).
5. `tamper_policy` self-destruct during development.

### Safe (normal post-boot OS config, NOT in the trust chain)
`/etc/fstab`, `/etc/docker/daemon.json`, `/home/zero-tech/zknode-autonomi/docker-compose.yml`
live on the **already-decrypted running rootfs**; editing them cannot trip Secure Boot or
the tamper latch (tamper is a dedicated hardware GPIO latch, not a software file check).
Adding a mount (if ever done) is safe.

### Physical-install caveat (if hardware is ever opened)
- Power OFF fully first; do NOT hot-swap the Zymkey module/USB (usb 3-1.1) or GPIO.
- Avoid contact with the Zymkey/tamper region; use a stable PSU.
- Let the 90s supervise-boot LED sequence complete before touching anything.

## Boot-time persistence units (keep — already enabled)
- `zknode-io-controller.service`  : enables `+io` on system.slice BEFORE docker (enabled)
- `zknode-dirauth-realign.{service,timer}` : restarts 3 dirauths every 4h (enabled)
