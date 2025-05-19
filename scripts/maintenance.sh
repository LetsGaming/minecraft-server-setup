#!/usr/bin/env bash
set -e

MAINTENANCE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MAINTENANCE_SCRIPT_DIR/common/server_control.sh"

# Lock file to prevent concurrent runs
LOCK_FILE="/tmp/minecraft_maintenance.lock"

if [ -e "$LOCK_FILE" ]; then
    echo "Maintenance script already running (lock file $LOCK_FILE exists). Exiting."
    exit 1
fi

trap 'rm -f "$LOCK_FILE"' EXIT
touch "$LOCK_FILE"

# Ensure log directory exists
mkdir -p "$MAINTENANCE_SCRIPT_DIR/logs"
log_file_path="$MAINTENANCE_SCRIPT_DIR/logs/maintenance.log"

log() {
    local level="$1"
    shift
    local msg
    msg="$(date +'%F %T') [$level] $*"
    echo "$msg"
    echo "$msg" >> "$log_file_path"
}

log_raw() {
    echo "$@"
}

# Defaults
ADMIN_USERNAME=""
SERVER_PROPERTIES_FILE="$SERVER_PATH/server.properties"
MOTD_BACKUP_FILE="$MAINTENANCE_SCRIPT_DIR/.motd_backup"
# Removed redundant LOG_FILE assignment here (it's in server_control.sh)
KICK_PID=""

# Args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --admin)
            ADMIN_USERNAME="$2"
            shift 2
            ;;
        *)
            log "ERROR" "Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$ADMIN_USERNAME" ]]; then
    log "ERROR" "--admin <username> is required."
    exit 1
fi

# Handle Ctrl+C gracefully
trap 'log "INFO" "Interrupted by user"; exit 0' INT

# MOTD Control
change_motd() {
    local new_motd="$1"
    local current_motd

    if [[ ! -f "$SERVER_PROPERTIES_FILE" ]]; then
        log "ERROR" "server.properties not found at $SERVER_PROPERTIES_FILE"
        exit 1
    fi

    current_motd=$(grep '^motd=' "$SERVER_PROPERTIES_FILE" || echo "motd=")
    echo "$current_motd" > "$MOTD_BACKUP_FILE"

    # Escape & | \ for sed and use | delimiter
    local escaped_motd
    escaped_motd=$(printf '%s' "$new_motd" | sed -e 's/[&|\\]/\\&/g')
    sed -i "s|^motd=.*|motd=$escaped_motd|" "$SERVER_PROPERTIES_FILE"

    log "INFO" "MOTD changed to: $new_motd"
}

restore_motd() {
    log "INFO" "Restoring original MOTD..."
    if [[ -f "$MOTD_BACKUP_FILE" ]]; then
        grep -v '^motd=' "$SERVER_PROPERTIES_FILE" > "${SERVER_PROPERTIES_FILE}.tmp"
        cat "$MOTD_BACKUP_FILE" >> "${SERVER_PROPERTIES_FILE}.tmp"
        mv "${SERVER_PROPERTIES_FILE}.tmp" "$SERVER_PROPERTIES_FILE"
        rm -f "$MOTD_BACKUP_FILE"
        log "INFO" "Original MOTD restored."
    else
        log "WARN" "No MOTD backup found. Could not restore."
    fi
}

restart_server() {
    log "INFO" "Restarting server..."
    bash "$MAINTENANCE_SCRIPT_DIR/restart.sh" --force
}

cleanup() {
    log "INFO" "Exiting maintenance mode. Cleaning up..."
    restore_motd
    if [[ -n "$KICK_PID" ]]; then
        kill "$KICK_PID" 2>/dev/null || true
        wait "$KICK_PID" 2>/dev/null || true
    fi
    log "INFO" "Maintenance script exited cleanly."
    restart_server
}

trap cleanup EXIT

# Player Monitor
kick_unauthorized_players() {
    log "INFO" "Monitoring player joins to kick unauthorized users..."

    tail -n0 -F "$LOG_FILE" 2>/dev/null | while read -r line; do
        if [[ "$line" =~ \]:\ ([a-zA-Z0-9_]+)\ joined\ the\ game ]]; then
            local player="${BASH_REMATCH[1]}"
            # Case-insensitive comparison
            if [[ "${player,,}" != "${ADMIN_USERNAME,,}" ]]; then
                log "INFO" "Kicking unauthorized player: $player"
                send_command "kick $player Server is under maintenance"
            else
                log "INFO" "Admin $player joined, not kicking."
            fi
        fi
    done
}

# Main
log "INFO" "Starting maintenance mode (admin: $ADMIN_USERNAME)"
change_motd "§4§l! Maintenance Mode !§r\n§6Please come back later"
send_command "say Server is restarting for maintenance. Please reconnect later."
restart_server

kick_unauthorized_players &
KICK_PID=$!

log_raw "[INFO] Maintenance mode active. Press Ctrl+C to exit."
while true; do sleep 1; done
