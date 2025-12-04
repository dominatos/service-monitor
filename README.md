# Service Monitor

`service-monitor` is a small, hardened Bash-based monitoring tool that watches selected **systemd** services and sends **Telegram notifications** when:

- a service crashes (`failed`),
- a service recovers,
- a service stays in a problematic state for a long time.

It supports:

- **Periodic monitoring** (via a systemd timer)
- **Instant crash monitoring via `OnFailure=`** (triggered immediately when systemd detects a failure)

Both modes can be used **simultaneously** for optimal results.

---

## Features

- **Real-time crash detection** using `OnFailure=service-monitor@%n.service`
- **Periodic checks** using a systemd timer (configurable interval)
- **RECOVERED notifications** when a service becomes healthy again
- **STILL DOWN reminders** when a service remains unhealthy
- Supports **system** and **user** services
- Uses hardened systemd units
- Stores state in `/var/lib/service-monitor/state`
- Sends notifications via **Telegram Bot API**

---

## Requirements

- `bash` 4+
- `curl`
- `systemd` 240+

---

# Installation

```bash
sudo ./install.sh
```

Installer actions:

- Installs script → `/usr/local/bin/service-monitor.sh`
- Installs config → `/etc/service-monitor/service-monitor.conf`
- Creates state directory → `/var/lib/service-monitor/state/`
- Installs systemd units:
  - `service-monitor.service`
  - `service-monitor.timer`
  - `service-monitor@.service`
- Enables + starts timer
- Reloads systemd

---

# Configuration

Edit:

```bash
sudo vim /etc/service-monitor/service-monitor.conf
```

Example:

```bash
TG_BOT_TOKEN="123456789:abcdef"
TG_CHAT_ID="-1001234567890"

SERVICES="ssh.service anydesk.service docker.service"

# Monitor user services
# MONITOR_USER="alice"

COALESCE_SECONDS=300
STARTUP_GRACE_SECONDS=60

# Optional hostname override
# HOSTNAME_OVERRIDE="my-server"
```

Validate syntax:

```bash
sudo bash -n /etc/service-monitor/service-monitor.conf
```

---

# How It Works

### Timer-based mode

A systemd timer runs `service-monitor.service` every N seconds.  
The script checks all services listed in `SERVICES=`.

### OnFailure mode (instant crash alerts)

Add to a unit:

```ini
[Unit]
OnFailure=service-monitor@%n.service
```

Systemd runs `service-monitor.sh <unit>` **immediately** when that service enters `failed`.

---

# Enabling Real-Time Crash Alerts

```bash
sudo systemctl edit jellyfin.service
```

Insert:

```ini
[Unit]
OnFailure=service-monitor@%n.service
```

Reload:

```bash
sudo systemctl daemon-reload
```

Now DOWN notifications are instant.

RECOVERED notifications will be sent on the next timer tick.

---

# Customizing Timer

Modify:

```
systemd/service-monitor.timer
```

Or:

```bash
sudo systemctl edit service-monitor.timer
```

Parameters:

- `OnBootSec=60s`
- `OnUnitActiveSec=90s`

Reload + restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart service-monitor.timer
```

---

# Monitoring User Services

```ini
SERVICES="user:plasma-ksmserver.service"
MONITOR_USER="sviatoslav"
```

User units are only monitored in timer mode  
(systemd does not support `OnFailure` for user units).

---

# Logs & State Files

Logs:

```
journalctl -u service-monitor.service
journalctl -u service-monitor@anydesk.service
```

State:

```
/var/lib/service-monitor/state/<service>.status
```

---

# Hardened systemd unit (service-monitor@.service)

```ini
[Unit]
Description=Service Monitor (OnFailure handler) for %i
After=network-online.target
Wants=network-online.target
ConditionPathExists=/usr/local/bin/service-monitor.sh

[Service]
Type=oneshot
EnvironmentFile=/etc/service-monitor/service-monitor.conf
ExecStart=/usr/local/bin/service-monitor.sh %i
User=root
Group=root

# Security hardening
NoNewPrivileges=yes
#ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
LockPersonality=yes
CapabilityBoundingSet=
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=/var/lib/service-monitor /run /etc/service-monitor
```

---

# Testing

## 1. Manual Test

```bash
sudo /usr/local/bin/service-monitor.sh anydesk.service
```

Should send:
- DOWN (if service is not running)
- RECOVERED (if running)

---

## 2. Timer Test

```bash
systemctl list-timers | grep service-monitor
journalctl -u service-monitor.service -e
```

---

## 3. OnFailure Crash Test

1. Validate drop-in:

```bash
systemctl cat anydesk.service
```

2. Restart service:

```bash
sudo systemctl restart anydesk.service
```

3. Simulate crash:

```bash
sudo systemctl kill --kill-who=main --signal=KILL anydesk.service
```

4. Check:

```bash
journalctl -u service-monitor@anydesk.service -e
```

Telegram should show ❌ DOWN immediately.

---

# ⚠️ Important: OnFailure Limitations (Why RECOVERED Requires Timer)

Systemd’s `OnFailure=` triggers **only when a unit enters `failed`**.  
There is NO hook for:

- “OnSuccess”
- “OnRecovered”
- “OnActive”
- “After restart”

Therefore:

- DOWN notifications → event-driven (OnFailure)
- RECOVERED notifications → timer-driven
- STILL DOWN reminders → timer-driven

This is the correct hybrid design for systemd:
- **OnFailure = fast crash detection**
- **Timer = recovery detection + reminders**

### Why not ExecStartPost?

`ExecStartPost=` runs during the activation phase and breaks many services:

- leaves units in `activating (start-post)`
- fails on units with `PIDFile=`
- causes instability in 3rd-party unit files (e.g. AnyDesk)

This project intentionally **does not use `ExecStartPost` or `OnSuccess`**.

---

# Future Option: Full Event-Based Monitoring (v3)

Pure event-driven RECOVERED detection requires a **long-running daemon** that listens to systemd’s D-Bus:

```
org.freedesktop.systemd1
 → PropertiesChanged
```

This is planned as a possible **service-monitor v3**, but current version
remains lightweight and dependency-free.

---

# Uninstallation

```bash
sudo systemctl disable --now service-monitor.timer
sudo rm -f /usr/local/bin/service-monitor.sh
sudo rm -rf /etc/service-monitor
sudo rm -f /etc/systemd/system/service-monitor.service
sudo rm -f /etc/systemd/system/service-monitor@.service
sudo systemctl daemon-reload
```

---

# License

MIT License.
