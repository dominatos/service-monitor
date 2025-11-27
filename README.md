# 📡 Service Monitor — systemd services monitoring with Telegram alerts

`service-monitor` is a lightweight, self-contained monitor for systemd services (system and user).  
It tracks service state changes and sends alerts to a Telegram chat.

Supported:
- System services (`jellyfin.service`, `transmission-daemon.service`, …)
- User services via prefix `user:`
- Failure / recovery notifications
- Periodic reminders while a service remains in a bad state
- Grace period after boot
- Single-instance lock
- systemd sandboxing (ProtectSystem, ProtectHome, NoNewPrivileges, etc.)

---

## 🚀 Features

- Monitor any systemd service:
  - System: `jellyfin.service`, `transmission-daemon.service`, `vsftpd.service`, …
  - User: `user:tg-torrent-bot-php.service`
- Telegram alerts when:
  - a service goes down
  - a service recovers
  - a service stays problematic for a long time (reminders)
- Grace period after boot to ignore noise
- Locking to avoid parallel runs
- Logging to systemd-journal
- Hardening via systemd sandbox

---

## 📦 Layout

```
/etc/service-monitor/
    └── service-monitor.conf

/usr/local/bin/service-monitor.sh

/etc/systemd/system/
    ├── service-monitor.service
    └── service-monitor.timer

/var/lib/service-monitor/state/
```

---

# 🔧 Installation

## 1. Create directories

```bash
sudo mkdir -p /etc/service-monitor
sudo mkdir -p /var/lib/service-monitor/state
```

---

## 2. Install the script

```bash
sudo cp service-monitor.sh /usr/local/bin/service-monitor.sh
sudo chown root:root /usr/local/bin/service-monitor.sh
sudo chmod 755 /usr/local/bin/service-monitor.sh
```

⚠️ **Do not** use a symlink into `/home`.  
With `ProtectHome=yes` systemd will block execution and you will get `203/EXEC`.

---

## 3. Configuration `/etc/service-monitor/service-monitor.conf`

Example:

```bash
# Telegram bot token
TG_BOT_TOKEN="123456789:ABCDEF1234567890abcdef1234567890"

# Chat ID (user, group or channel)
TG_CHAT_ID="655142522"

# User whose *user services* we want to monitor
MONITOR_USER="sviatoslav"

# List of services to monitor (space-separated)
# Mix system and user services:
SERVICES="jellyfin.service transmission-daemon.service user:tg-torrent-bot-php.service"

# Minimum interval (seconds) between repeated alerts
COALESCE_SECONDS=300

# Grace period after boot (seconds)
STARTUP_GRACE_SECONDS=60
```

Validate syntax:

```bash
bash -n /etc/service-monitor/service-monitor.conf
```

---

## 4. systemd unit `/etc/systemd/system/service-monitor.service`

```ini
[Unit]
Description=Service Monitor - check systemd service states and send Telegram alerts
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/service-monitor.sh
EnvironmentFile=-/etc/service-monitor/service-monitor.conf

# Security hardening
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
LockPersonality=yes
CapabilityBoundingSet=
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# Writable paths
ReadWritePaths=/var/lib/service-monitor /run /etc/service-monitor

[Install]
WantedBy=multi-user.target
```

Reload systemd units:

```bash
sudo systemctl daemon-reload
```

---

## 5. systemd timer `/etc/systemd/system/service-monitor.timer`

```ini
[Unit]
Description=Run Service Monitor every 30 seconds

[Timer]
OnBootSec=1min
OnUnitActiveSec=30s
AccuracySec=5s
Persistent=true
Unit=service-monitor.service

[Install]
WantedBy=timers.target
```

Enable and start timer:

```bash
sudo systemctl enable --now service-monitor.timer
```

---

# 🧪 Verification

### Run service manually

```bash
sudo systemctl start service-monitor.service
sudo systemctl status service-monitor.service
```

### Check logs

```bash
journalctl -u service-monitor.service -e
```

### Check timer

```bash
systemctl list-timers service-monitor.timer
```

Expected output:

```text
NEXT                         LEFT      UNIT                   ACTIVATES
Thu 2025-11-27 16:02:30 CET  21s       service-monitor.timer  service-monitor.service
```

---

# 🔍 Monitoring user services

User services are referenced by prefix:

```text
user:<service-name>
```

Example:

```text
user:tg-torrent-bot-php.service
```

In config you **must** set:

```bash
MONITOR_USER="sviatoslav"
```

The script then queries user services via:

```bash
systemctl --user --machine=<user>@
```

---

# 📤 Example Telegram alerts

### Service went down

```text
❌ Service DOWN
Host: my-server
Service: jellyfin.service
Status: failed/dead/exit-code
Time: 2025-11-27 15:22:10 CET

Diagnostics:
systemctl status jellyfin.service
journalctl -u jellyfin.service -e
```

### Service recovered

```text
✅ Service RECOVERED
Host: my-server
Service: jellyfin.service
Status: active/running/success
Time: 2025-11-27 15:24:05 CET
```

### Service still problematic (reminder)

```text
⚠️ Service STILL PROBLEMATIC
Host: my-server
Service: transmission-daemon.service
Status: failed/dead/failed
Time: 2025-11-27 15:32:10 CET
```

---

# 🔐 systemd security hardening

Service runs in a sandbox:

- `ProtectSystem=strict` — root filesystem read-only
- `ProtectHome=yes` — `/home` is not accessible
- `NoNewPrivileges=yes`
- `PrivateTmp=yes`
- `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`
- `CapabilityBoundingSet=` — no Linux capabilities

Writable only:

- `/var/lib/service-monitor`
- `/etc/service-monitor`
- `/run`

---

# 🧹 Uninstall

```bash
sudo systemctl disable --now service-monitor.timer
sudo rm /etc/systemd/system/service-monitor.timer

sudo systemctl disable --now service-monitor.service
sudo rm /etc/systemd/system/service-monitor.service

sudo rm -r /etc/service-monitor
sudo rm -r /var/lib/service-monitor
sudo rm /usr/local/bin/service-monitor.sh

sudo systemctl daemon-reload
```

---

# ❓ FAQ

**How to change the check interval?**  
Edit `OnUnitActiveSec=` in `service-monitor.timer` and restart the timer.

**Can I customize diagnostics commands in alerts?**  
Yes, edit the message formatting section in the script.

**What happens if Telegram is unreachable?**  
The script logs an error to systemd-journal; the system continues running.
