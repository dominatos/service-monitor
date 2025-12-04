#!/usr/bin/env bash
# service-monitor.sh — monitor systemd services and send Telegram alerts
#
# This script checks the status of one or more systemd services and
# sends notifications via Telegram whenever their state changes or remains
# non‑active for too long. It can be run on a regular interval from a
# systemd timer or executed on demand when a service enters the
# <code>failed</code> state via systemd's <code>OnFailure</code> mechanism.
#
# Usage:
#   • As a timer: install the accompanying systemd service and timer
#     units. In this mode the list of services to monitor is read from
#     the SERVICES variable in the configuration file.
#   • As an OnFailure handler: systemd passes the name of the failed unit
#     as the first argument. The script will then monitor only that one
#     unit.
#
# See the README.md for installation and configuration instructions.

set -Eeuo pipefail
IFS=$'\n\t'

# Directory where per‑service state is stored. Files in this directory
# track each service's last reported state and the timestamp of the
# last notification. These files are automatically created.
STATE_DIR="/var/lib/service-monitor/state"
# Lock file used to ensure only one instance runs at a time.
LOCK_FILE="/run/service-monitor.lock"
# Tag used when logging to the system journal via logger(1).
TAG="service-monitor"
# Configuration file containing bot token, chat ID, and default services.
CONFIG_FILE="/etc/service-monitor/service-monitor.conf"

##
## Error handling
##
on_err() {
    # Capture the exit code of the failing command
    local exit_code=$?
    # Emit a message to the journal – if the script fails we want to know why
    logger --tag "$TAG" --priority err "Service monitor failed with exit code ${exit_code}"
    exit "$exit_code"
}
# Trap any error and call on_err
trap on_err ERR

##
## Load configuration
##
if [[ ! -f "$CONFIG_FILE" ]]; then
    logger --tag "$TAG" --priority err "Config file ${CONFIG_FILE} not found"
    exit 1
fi

# Load variables from the config. shellcheck complains about dynamic sourcing, disable warning.
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Telegram bot token and chat ID must always be defined in the configuration
: "${TG_BOT_TOKEN:?TG_BOT_TOKEN is not set}"
: "${TG_CHAT_ID:?TG_CHAT_ID is not set}"

# When invoked with arguments (e.g. via OnFailure handler), treat them as the list
# of services to monitor. Otherwise use the SERVICES variable from the config. If
# neither is defined, abort.
if (( $# > 0 )); then
    SERVICES="$*"
else
    : "${SERVICES:?SERVICES is not set and no services were provided on command line}"
fi

# MONITOR_USER is optional – only needed if you monitor user services (prefixed with "user:")

# Coalesce interval: minimum number of seconds between repeated reminders for the
# same service state. If set to zero or negative, reminders are disabled.
COALESCE_SECONDS="${COALESCE_SECONDS:-300}"
# Grace period after boot: avoid sending alerts during early boot when services
# may be starting or restarting.
STARTUP_GRACE_SECONDS="${STARTUP_GRACE_SECONDS:-60}"

# Hostname used in messages. Can be overridden via HOSTNAME_OVERRIDE in the config.
HOSTNAME="$(hostname)"
if [[ -n "${HOSTNAME_OVERRIDE:-}" ]]; then
    HOSTNAME="$HOSTNAME_OVERRIDE"
fi

##
## Prepare runtime directories
##
mkdir -p "$STATE_DIR"

##
## Telegram sending helper
##
send_telegram() {
    local message="$1"
    local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"
    # Send message. parse_mode=HTML allows bold, code blocks, etc.
    local response
    response=$(curl -s -X POST "$url" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=HTML" \
        -d "disable_web_page_preview=true")

    # Check Telegram API response: it should contain "\"ok\":true"
    if ! echo "$response" | grep -q '"ok":true'; then
        logger --tag "$TAG" --priority err "Failed to send Telegram message: ${response}"
    fi
}

##
## Query systemd for the status of a service
##
# Prints a triple ActiveState:SubState:Result on success. Returns non-zero on error.
# Supports system services (e.g. "sshd.service") and user services prefixed with "user:".
get_status() {
    local svc="$1"
    local a s r

    # Detect user services by prefix. The regex captures the unit name after "user:".
    if [[ "$svc" =~ ^user:(.+)$ ]]; then
        local svc_name="${BASH_REMATCH[1]}"
        # MONITOR_USER must be set for user services; it determines which user's systemd to talk to
        if [[ -z "${MONITOR_USER:-}" ]]; then
            logger --tag "$TAG" --priority err "MONITOR_USER is not set but user service requested: ${svc}"
            return 1
        fi
        # Query the user bus for ActiveState, SubState and Result
        if ! a=$(systemctl --user --machine="${MONITOR_USER}@" show "$svc_name" -p ActiveState --value --no-page 2>/dev/null); then
            logger --tag "$TAG" --priority err "Failed to get ActiveState for user service ${svc_name} (MONITOR_USER=${MONITOR_USER})"
            return 1
        fi
        if ! s=$(systemctl --user --machine="${MONITOR_USER}@" show "$svc_name" -p SubState --value --no-page 2>/dev/null); then
            logger --tag "$TAG" --priority err "Failed to get SubState for user service ${svc_name} (MONITOR_USER=${MONITOR_USER})"
            return 1
        fi
        # Result is optional – if not present, default to "unknown"
        if ! r=$(systemctl --user --machine="${MONITOR_USER}@" show "$svc_name" -p Result --value --no-page 2>/dev/null); then
            r="unknown"
        fi
    else
        # Query a system service
        if ! a=$(systemctl show "$svc" -p ActiveState --value --no-page 2>/dev/null); then
            logger --tag "$TAG" --priority err "Failed to get ActiveState for service ${svc}"
            return 1
        fi
        if ! s=$(systemctl show "$svc" -p SubState --value --no-page 2>/dev/null); then
            logger --tag "$TAG" --priority err "Failed to get SubState for service ${svc}"
            return 1
        fi
        if ! r=$(systemctl show "$svc" -p Result --value --no-page 2>/dev/null); then
            r="unknown"
        fi
    fi

    echo "${a}:${s}:${r}"
}

##
## Calculate boot uptime and decide if we are within the grace period
##
uptime_seconds=$(cut -d' ' -f1 < /proc/uptime | cut -d'.' -f1)
if (( uptime_seconds < STARTUP_GRACE_SECONDS )); then
    logger --tag "$TAG" "In startup grace period (${uptime_seconds}s < ${STARTUP_GRACE_SECONDS}s), alerts will be suppressed"
fi

##
## Ensure only one instance runs at a time
##
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    logger --tag "$TAG" "Another instance is already running, exiting"
    exit 0
fi

now_utc="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
now_local="$(date '+%Y-%m-%d %H:%M:%S %Z')"

##
## Iterate over services and send notifications
##
# The SERVICES variable may contain whitespace. Use eval to split into an array.
eval "services_array=($SERVICES)"

for svc in "${services_array[@]}"; do
    status_line="$(get_status "$svc")" || {
        logger --tag "$TAG" --priority err "Error getting status for ${svc}, skipping"
        continue
    }

    IFS=":" read -r active sub result <<<"$status_line"
    new_status="${active}/${sub}/${result}"

    # Derive a safe filename by replacing ':' in user service names
    safe_name="${svc//:/_}"
    state_file="${STATE_DIR}/${safe_name}.status"

    # Load previous status and timestamp if they exist
    last_status=""
    last_time=0
    if [[ -f "$state_file" ]]; then
        read -r last_status <"$state_file" || true
        read -r last_time <"${state_file}.time" 2>/dev/null || true
    fi

    # -------- State changed --------
    if [[ "$new_status" != "$last_status" ]]; then
        if (( uptime_seconds >= STARTUP_GRACE_SECONDS )); then
            if [[ "$active" == "active" ]]; then
                # Service recovered
                msg="✅ <b>Service RECOVERED</b>
<b>Host:</b> <code>${HOSTNAME}</code>
<b>Service:</b> <code>${svc}</code>
<b>Status:</b> <code>${new_status}</code>
<b>Time:</b> ${now_utc} (${now_local})"
            else
                # Service failed or entered a problematic state
                msg="❌ <b>Service DOWN</b>
<b>Host:</b> <code>${HOSTNAME}</code>
<b>Service:</b> <code>${svc}</code>
<b>Status:</b> <code>${new_status}</code>
<b>Time:</b> ${now_utc} (${now_local})

<b>Diagnostics:</b>
<code>systemctl status ${svc##user:}</code>
<code>journalctl -u ${svc##user:} -e</code>"
            fi

            send_telegram "$msg"
            logger --tag "$TAG" "Service ${svc} status changed: '${last_status}' → '${new_status}'"
        else
            logger --tag "$TAG" "Service ${svc} status changed but still in grace period (${uptime_seconds}s < ${STARTUP_GRACE_SECONDS}s), alert suppressed"
        fi

        echo "$new_status" >"$state_file"
        date +%s >"${state_file}.time"
        continue
    fi

    # -------- State unchanged, reminders --------
    # Only remind if service is not active and coalesce interval has passed
    if (( COALESCE_SECONDS > 0 )) && [[ "$active" != "active" ]]; then
        now_epoch=$(date +%s)
        if (( now_epoch - last_time >= COALESCE_SECONDS )); then
            if (( uptime_seconds >= STARTUP_GRACE_SECONDS )); then
                msg="⚠️ <b>Service STILL PROBLEMATIC</b>
<b>Host:</b> <code>${HOSTNAME}</code>
<b>Service:</b> <code>${svc}</code>
<b>Status:</b> <code>${new_status}</code>
<b>Time:</b> ${now_utc} (${now_local})"

                send_telegram "$msg"
                logger --tag "$TAG" "Reminder: service ${svc} is still in state ${new_status}"
                date +%s >"${state_file}.time"
            else
                logger --tag "$TAG" "Service ${svc} problematic but in grace period, reminder suppressed"
            fi
        fi
    fi
done

exit 0
