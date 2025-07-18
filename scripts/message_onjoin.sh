#!/usr/bin/env bash
set -e

ONJOIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ONJOIN_DIR/common/server_control.sh"
source "$ONJOIN_DIR/common/utils.sh"

LOCK_FILE="/tmp/minecraft_onjoin_message.lock"
if [ -e "$LOCK_FILE" ]; then
    echo "Script already running (lock file $LOCK_FILE exists). Exiting."
    exit 1
fi
trap 'rm -f "$LOCK_FILE"' EXIT
touch "$LOCK_FILE"

init_log_file "$ONJOIN_DIR/logs" "onjoin_message.log"

LOG_FILE="$SERVER_PATH/logs/latest.log"
MESSAGE_FILE="$ONJOIN_DIR/.welcomed_players"
JOIN_MESSAGE="§6Welcome! §fPlease make sure to read the server rules."

touch "$MESSAGE_FILE"

handle_player_welcome() {
    local player="$1"
    local player_lower="${player,,}"

    if grep -iq "^$player_lower\$" "$MESSAGE_FILE"; then
        log "DEBUG" "Player $player already welcomed."
    else
        log "INFO" "Welcoming new player: $player"
        send_command "tellraw $player {\"text\":\"$JOIN_MESSAGE\",\"color\":\"gold\"}"
        echo "$player_lower" >> "$MESSAGE_FILE"
    fi
}

log "INFO" "Monitoring player joins to send welcome messages..."
on_player_join "$LOG_FILE" handle_player_welcome
