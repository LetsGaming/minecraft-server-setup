#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/server_control.sh"
source "$SCRIPT_DIR/common/utils.sh"

LOCK_FILE="/tmp/minecraft_maintenance.lock"
if [ -e "$LOCK_FILE" ]; then
    echo "Maintenance script already running (lock file $LOCK_FILE exists). Exiting."
    exit 1
fi
trap 'rm -f "$LOCK_FILE"' EXIT
touch "$LOCK_FILE"

init_log_file "$SCRIPT_DIR/logs" "maintenance.log"

ADMIN_USERNAMES=()
SERVER_PROPERTIES_FILE="$SERVER_PATH/server.properties"
MOTD_BACKUP_FILE="$SCRIPT_DIR/.motd_backup"
KICK_PID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --admin)
            IFS=',' read -ra ADMIN_USERNAMES <<< "$2"
            shift 2
            ;;
        *)
            log "ERROR" "Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [[ ${#ADMIN_USERNAMES[@]} -eq 0 ]]; then
    log "ERROR" "--admin <username>[,<username2>,...] is required."
    exit 1
fi

trap 'log "INFO" "Interrupted by user"; exit 0' INT

change_motd() {
    local new_motd="$1"
    local current_motd

    if [[ ! -f "$SERVER_PROPERTIES_FILE" ]]; then
        log "ERROR" "server.properties not found at $SERVER_PROPERTIES_FILE"
        exit 1
    fi

    current_motd=$(grep '^motd=' "$SERVER_PROPERTIES_FILE" || echo "motd=")
    echo "$current_motd" > "$MOTD_BACKUP_FILE"

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
    bash "$SCRIPT_DIR/restart.sh" --force
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

handle_join_during_maintenance() {
    local player="$1"
    local player_lower="${player,,}"
    local is_admin=false

    for admin in "${ADMIN_USERNAMES[@]}"; do
        if [[ "$player_lower" == "${admin,,}" ]]; then
            is_admin=true
            break
        fi
    done

    if [[ "$is_admin" == false ]]; then
        log "INFO" "Kicking unauthorized player: $player"
        send_command "kick $player Server is under maintenance"
    else
        log "INFO" "Admin $player joined, not kicking."
    fi
}

start_kick_monitor() {
    log "INFO" "Monitoring player joins to kick unauthorized users..."
    on_player_join "$LOG_FILE" handle_join_during_maintenance
}

log "INFO" "Starting maintenance mode (admins: ${ADMIN_USERNAMES[*]})"
change_motd "§4§l! Maintenance Mode !§r\n§6Please come back later"
send_command "say Server is restarting for maintenance. Please reconnect later."
restart_server

start_kick_monitor &
KICK_PID=$!

log_raw "[INFO] Maintenance mode active. Press Ctrl+C to exit."
while true; do sleep 1; done
