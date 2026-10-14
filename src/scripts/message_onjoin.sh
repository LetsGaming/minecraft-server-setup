#!/usr/bin/env bash
set -e

ONJOIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ONJOIN_DIR/common/server_control.sh"
source "$ONJOIN_DIR/common/utils.sh"

acquire_instance_lock "onjoin" || exit 1

init_log_file "$ONJOIN_DIR/logs" "onjoin_message.log"

# Defaults
MESSAGE_FILE="$ONJOIN_DIR/.messaged_players"
DEFAULT_TITLE="§lWelcome!"
TITLE="$DEFAULT_TITLE"
MESSAGE="§6Please read the server rules."
ADMIN_USERS=()

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --title=TEXT           Title text to display (default: $DEFAULT_TITLE)
  --message=TEXT         Subtitle/message text (default: $MESSAGE)
  --messageFile=PATH     Read TITLE and MESSAGE from a file containing lines:
                           title="…" and message="…"
  --admin=USER1,USER2    Comma‑separated admins to skip messaging
  --help                 Show this help and exit
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            print_usage; exit 0
            ;;
        --title=*)
            TITLE="${1#*=}"; shift
            ;;
        --message=*)
            MESSAGE="${1#*=}"; shift
            ;;
        --messageFile=*)
            mf="${1#*=}"
            if [[ ! -f "$mf" ]]; then
                log "ERROR" "Message file not found: $mf"; exit 1
            fi
            # Only a file this user owns (S-026): the option must not read
            # any file the server user can see into a title players get.
            if [[ "$(stat -c %u -- "$mf")" != "$(id -u)" ]]; then
                log "ERROR" "Message file is not owned by $(id -un): $mf"; exit 1
            fi
            while IFS= read -r line; do
                if [[ "$line" =~ ^title=\"(.*)\" ]]; then
                    TITLE="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^message=\"(.*)\" ]]; then
                    MESSAGE="${BASH_REMATCH[1]}"
                fi
            done < "$mf"
            shift
            ;;
        --admin=*)
            IFS=',' read -ra ADMIN_USERS <<< "${1#*=}"; shift
            ;;
        *)
            log "ERROR" "Unknown argument: $1"
            print_usage; exit 1
            ;;
    esac
done

# JSON string contents: \ and " escaped, control characters refused (S-026).
json_text() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}
for text in "$TITLE" "$MESSAGE"; do
    if [[ "$text" =~ [[:cntrl:]] ]]; then
        log "ERROR" "Title and message must be one line without control characters."; exit 1
    fi
done

touch "$MESSAGE_FILE"

handle_player_welcome() {
    local player="$1"
    local pl_lower="${player,,}"

    for adm in "${ADMIN_USERS[@]}"; do
        if [[ "$pl_lower" == "${adm,,}" ]]; then
            log "DEBUG" "Skipping admin $player"; return
        fi
    done

    if grep -ixqF "$pl_lower" "$MESSAGE_FILE"; then
        log "DEBUG" "Already welcomed $player"; return
    fi

    log "INFO" "Sending title to $player"
    # Build JSON components
    local title_json subtitle_json
    title_json="{\"text\":\"$(json_text "$TITLE")\"}"
    subtitle_json="{\"text\":\"$(json_text "$MESSAGE")\"}"

    # Java Edition JSON /title
    send_command "/title $player title $title_json"
    send_command "/title $player subtitle $subtitle_json"

    echo "$pl_lower" >> "$MESSAGE_FILE"
}

log "INFO" "Watching for joins to send /title"
on_player_join "$LOG_FILE" handle_player_welcome
