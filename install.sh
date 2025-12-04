#!/usr/bin/env bash
# install.sh — install the service-monitor script, configuration and systemd units
#
# This installer copies the monitoring script to /usr/local/bin, installs
# a default configuration file if one does not already exist, and installs
# the provided systemd service, timer and template units. It then reloads
# systemd, enables the timer and starts it immediately. The installer must
# be run with sufficient privileges (via sudo).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Paths
INSTALL_BIN="/usr/local/bin/service-monitor.sh"
CONFIG_DIR="/etc/service-monitor"
CONFIG_FILE="${CONFIG_DIR}/service-monitor.conf"
UNIT_DIR="/etc/systemd/system"

echo "Installing service-monitor…"

# Create configuration directory and state directory
sudo mkdir -p "$CONFIG_DIR" || true
sudo mkdir -p /var/lib/service-monitor/state || true

# Install the monitoring script
echo "Copying script to ${INSTALL_BIN}"
sudo install -m 755 "${SCRIPT_DIR}/service-monitor.sh" "$INSTALL_BIN"

# Install the default configuration if missing
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Installing default configuration to ${CONFIG_FILE}"
    sudo install -m 644 "${SCRIPT_DIR}/config/service-monitor.conf.example" "$CONFIG_FILE"
    echo "Created ${CONFIG_FILE}. Please edit this file to configure Telegram credentials and services."
else
    echo "Existing configuration found at ${CONFIG_FILE}. Not overwriting."
fi

# Install systemd units
echo "Installing systemd units to ${UNIT_DIR}"
sudo install -m 644 "${SCRIPT_DIR}/systemd/service-monitor.service" "$UNIT_DIR/"
sudo install -m 644 "${SCRIPT_DIR}/systemd/service-monitor.timer" "$UNIT_DIR/"
sudo install -m 644 "${SCRIPT_DIR}/systemd/service-monitor@.service" "$UNIT_DIR/"

# Reload systemd to pick up new units
echo "Reloading systemd daemon"
sudo systemctl daemon-reload

# Enable and start the timer
echo "Enabling and starting service-monitor.timer"
sudo systemctl enable --now service-monitor.timer

echo "Installation complete."
echo
echo "The timer runs service-monitor.sh at regular intervals. To receive immediate notifications"
echo "when a service enters the 'failed' state, create a drop-in for each unit you wish to monitor"
echo "with a line like:"
echo "    [Unit]"
echo "    OnFailure=service-monitor@%n.service"
echo "This can be done by running 'sudo systemctl edit <unit>' and adding the lines above."
echo "For more information see the README.md in this repository."