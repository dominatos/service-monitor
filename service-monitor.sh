#!/usr/bin/env bash
# service-monitor.sh — monitor systemd services and send Telegram alerts
# License: MIT

set -Eeuo pipefail
IFS=$'\n\t'

STATE_DIR="/var/lib/service-monitor/state"
LOCK_FILE="/run/service-monitor.lock"
TAG="service-monitor"
CONFIG_FILE="/etc/service-monitor/service-monitor.conf"

# ===================== Error handling =====================
on_err() {
    local exit_code=$?
    logger --tag "$TAG" --priority err "Service monitor failed with exit code $exit_code"
    exit "$exit_code"
}
trap on_err ERR

# ===================== Load config =====================
if [[ ! -f "$CONFIG_FILE" ]]; then
    logger --tag "$TAG" --priority err "Config file $CONFIG_FILE not found"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${TG_BOT_TOKEN:?TG_BOT_TOKEN is not set}"
: "${TG_CHAT_ID:?TG_CHAT_ID is not set}"
: "${SERVICES:?SERVICES is not set}"
# MONITOR_USER is optional, only needed for user services

COALESCE_SECONDS="${COALESCE_SECONDS:-300}"
STARTUP_GRACE_SECONDS="${STARTUP_GRACE_SECONDS:-60}"

HOSTNAME="$(hostname)"
if [[ -n "${HOSTNAME_OVERRIDE:-}" ]]; then
    HOSTNAME="$HOSTNAME_OVERRIDE"
fi

# ===================== Prepare directories =====================
mkdir -p "$STATE_DIR"

# ===================== Telegram sending =====================
send_telegram() {
    local message="$1"
    local url="https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage"

    local response
    response=$(curl -s -X POST "$url" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=HTML" \
        -d "disable_web_page_preview=true")

    if ! echo "$response" | grep -q '"ok":true'; then
        logger --tag "$TAG" --priority err "Failed to send Telegram message: $response"
    fi
}

# ===================== Get systemd service status =====================
# Output: ActiveState:SubState:Result
# Supported:
#   - system services: "jellyfin.service"
#   - user services via prefix: "user:tg-torrent-bot-php.service"
get_status() {
    local svc="$1"
    local a s r

    # user service (systemd --user)
    if [[ "$svc" =~ ^user:(.+)$ ]]; then
        local svc_name="${BASHREMATCH[1]}"

        if [[ -z "${MONITOR_USER:-}" ]]; then
            logger --tag "$TAG" --priority err "MONITOR_USER is not set but user service requested: $svc"
            return 1
        fi

        if ! a=$(systemctl --user --machine="${MONITOR_USER}@" show "$svc_name" -p ActiveState --value --no-page 2>/dev/null); then
            logger --tag "$TAG" --priority err "Failed to get ActiveState for user service ${svc_name} (MONITOR_USER=${MONITOR_USER})"
            return 1
        fi
        if ! s=$(systemctl --user --machine="${MONITOR_USER}@" show "$svc_name" -p SubState --value --no-page 2>/dev/null); then
            logger --tag "$TAG" --priority err "Failed to get SubState for user service ${svc_name} (MONITOR_USER=${MONITOR_USER})"
            return 1
        fi
        if ! r=$(systemctl --user --machine="${MONITOR_USER}@" show "$svc_name" -p Result --value --no-page 2>/dev/null); then
            # Result is not always present
            r="unknown"
        fi
    else
        # system service
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

# ===================== Uptime / grace period =====================
uptime_seconds=$(cut -d' ' -f1 < /proc/uptime | cut -d'.' -f1)
if (( uptime_seconds < STARTUP_GRACE_SECONDS )); then
    logger --tag "$TAG" "In startup grace period (${uptime_seconds}s < ${STARTUP_GRACE_SECONDS}s), alerts will be suppressed"
fi

# ===================== Single instance lock =====================
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    logger --tag "$TAG" "Another instance is already running, exiting"
    exit 0
fi

now_utc="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
now_local="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# ===================== Parse services =====================
# In config:
#   SERVICES="jellyfin.service transmission-daemon.service user:tg-torrent-bot-php.service"
eval "services_array=($SERVICES)"

for svc in "${services_array[@]}"; do
    status_line="$(get_status "$svc")" || {
        logger --tag "$TAG" --priority err "Error getting status for ${svc}, skipping"
        continue
    }

    IFS=":" read -r active sub result <<<"$status_line"
    new_status="${active}/${sub}/${result}"

    # State file name: escape ':' in user: names
    safe_name="${svc//:/_}"
    state_file="${STATE_DIR}/${safe_name}.status"

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
                msg="✅ <b>Service RECOVERED</b>
<b>Host:</b> <code>${HOSTNAME}</code>
<b>Service:</b> <code>${svc}</code>
<b>Status:</b> <code>${new_status}</code>
<b>Time:</b> ${now_utc} (${now_local})"
            else
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
