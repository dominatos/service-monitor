#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[*] Installing service-monitor..."

# 1. Create directories
echo "[*] Creating directories..."
sudo mkdir -p /etc/service-monitor
sudo mkdir -p /var/lib/service-monitor/state

# 2. Install script
echo "[*] Installing service-monitor.sh to /usr/local/bin..."
sudo cp "${REPO_DIR}/service-monitor.sh" /usr/local/bin/service-monitor.sh
sudo chown root:root /usr/local/bin/service-monitor.sh
sudo chmod 755 /usr/local/bin/service-monitor.sh

# 3. Install example config if none exists
if [[ ! -f /etc/service-monitor/service-monitor.conf ]]; then
  echo "[*] Installing example config to /etc/service-monitor/service-monitor.conf"
  sudo cp "${REPO_DIR}/config/service-monitor.conf.example" /etc/service-monitor/service-monitor.conf
  sudo chown root:root /etc/service-monitor/service-monitor.conf
  sudo chmod 640 /etc/service-monitor/service-monitor.conf
else
  echo "[*] /etc/service-monitor/service-monitor.conf already exists, skipping"
fi

# 4. Install systemd units
echo "[*] Installing systemd units..."
sudo cp "${REPO_DIR}/systemd/service-monitor.service" /etc/systemd/system/service-monitor.service
sudo cp "${REPO_DIR}/systemd/service-monitor.timer" /etc/systemd/system/service-monitor.timer

# 5. Reload systemd
echo "[*] Reloading systemd daemon..."
sudo systemctl daemon-reload

# 6. Enable and start timer
echo "[*] Enabling and starting service-monitor.timer..."
sudo systemctl enable --now service-monitor.timer

echo
echo "[✓] Installation complete."
echo "   - Edit /etc/service-monitor/service-monitor.conf to set TG_BOT_TOKEN, TG_CHAT_ID and SERVICES."
echo "   - To test immediately: sudo systemctl start service-monitor.service && sudo systemctl status service-monitor.service"
