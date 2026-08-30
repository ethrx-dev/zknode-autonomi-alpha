#!/bin/bash
# install-living-intelligence.sh: installs doctor+watchdog+tuning on SCM4
set -e
NODE_HOME="${NODE_HOME:-/home/zero-tech/zknode-autonomi}"

echo "[1/6] Installing scripts..."
install -m 755 /tmp/zknode-doctor.sh /usr/local/bin/zknode-doctor
install -m 755 /tmp/zknode-watchdog.sh /usr/local/bin/zknode-watchdog

echo "[2/6] Installing systemd units..."
install -m 644 /tmp/zknode-watchdog.service /etc/systemd/system/zknode-watchdog.service
install -m 644 /tmp/zknode-watchdog.timer /etc/systemd/system/zknode-watchdog.timer

echo "[3/6] fstab tuning (noatime,commit=60 on docker/ext4 mounts)..."
if ! grep -q "noatime" /etc/fstab; then
  sed -i 's|\(/mnt/autonomi[ \t]*ext4[ \t]*defaults\)|\1,noatime,commit=60|' /etc/fstab
  grep autonomi /etc/fstab || true
  echo "  fstab updated (applies at next mount/reboot)"
else
  echo "  already tuned"
fi

echo "[4/6] Docker log rotation for future containers..."
python3 - <<'EOF'
import json
p = "/etc/docker/daemon.json"
try:
    with open(p) as f: cfg = json.load(f)
except Exception:
    cfg = {}
if "log-opts" not in cfg or cfg.get("log-opts",{}).get("max-size") != "10m":
    cfg.setdefault("log-opts", {"max-size": "10m", "max-file": "3"})
    with open(p,"w") as f: json.dump(cfg, f, indent=2)
    print("  daemon.json updated:", json.dumps(cfg))
else:
    print("  already configured")
EOF

echo "[5/6] Enabling watchdog timer..."
systemctl daemon-reload
systemctl enable --now zknode-watchdog.timer 2>/dev/null || systemctl enable zknode-watchdog.timer

echo "[6/6] Doctor verification run..."
/usr/local/bin/zknode-doctor | tail -20

echo "INSTALL COMPLETE"
