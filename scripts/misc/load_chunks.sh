#!/bin/bash

set -e

# Get the absolute path of the directory where *this script* resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load server control functions
source "$SCRIPT_DIR/../common/server_control.sh"

# Default world is "overworld"
WORLD="overworld"
RADIUS=200000
QUIET_INTERVAL=500

# Path to latest log
LOG_FILE="$SERVER_PATH/logs/latest.log"

# Internal set of online players
declare -A ONLINE_PLAYERS

# Check if any players are already online
initial_player_count=$(get_player_count)
if [[ "$initial_player_count" -gt 0 ]]; then
    echo "[INFO] Detected $initial_player_count player(s) online at startup. Chunk loading will be paused."
    INITIAL_PAUSE=true
else
    INITIAL_PAUSE=false
fi

# Check if Chunky mod is installed
check_chunky_mod() {
    if ! find "$SERVER_PATH/mods" -maxdepth 1 -type f | grep -iE '/[^/]*c[\-_]*h[\-_]*u[\-_]*n[\-_]*k[\-_]*y[^/]*' >/dev/null; then
        echo "[ERROR] Chunky mod is not installed."
        return 1
    fi
    return 0
}

# Check if the world is valid by checking the output of /chunky world <world>
check_world_exists() {
    world_name=$1
    send_command "/chunky world $world_name"
    log_output=$(read_log)
    if echo "$log_output" | grep -q "chunky world $world_name - Set the world target"; then
        echo "[ERROR] World '$world_name' is not valid or does not exist."
        return 1
    fi
    return 0
}

# Start chunk loading process
start_chunk_loading() {
    echo "[INFO] Starting chunk loading for $WORLD with a $RADIUS block radius."
    send_command "/chunky spawn"
    send_command "/chunky radius $RADIUS"
    send_command "/chunky start"
    send_command "/chunky quiet $QUIET_INTERVAL"
}

pause_chunk_loading() {
    echo "[INFO] Pausing chunk loading due to players online."
    send_command "/chunky pause"
}

resume_chunk_loading() {
    echo "[INFO] Resuming chunk loading as no players are online."
    send_command "/chunky continue"
}

handle_player_event() {
    local player="$1"
    local action="$2"

    if [[ "$action" == "join" ]]; then
        if [[ -z "${ONLINE_PLAYERS[$player]}" ]]; then
            ONLINE_PLAYERS["$player"]=1
            echo "[EVENT] $player joined"
            if [[ ${#ONLINE_PLAYERS[@]} -eq 1 ]]; then
                pause_chunk_loading
            fi
        fi
    elif [[ "$action" == "leave" ]]; then
        if [[ -n "${ONLINE_PLAYERS[$player]}" ]]; then
            unset ONLINE_PLAYERS["$player"]
            echo "[EVENT] $player left"
            if [[ ${#ONLINE_PLAYERS[@]} -eq 0 ]]; then
                resume_chunk_loading
            fi
        fi
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --world)
            WORLD="$2"
            shift 2
            ;;
        --radius)
            if [[ "$2" =~ ^[0-9]+$ ]]; then
                RADIUS="$2"
                shift 2
            else
                echo "[ERROR] Invalid radius: $2"
                exit 1
            fi
            ;;
        --quiet)
            if [[ "$2" =~ ^[0-9]+$ ]]; then
                QUIET_INTERVAL="$2"
                shift 2
            else
                echo "[ERROR] Invalid quiet interval: $2"
                exit 1
            fi
            ;;
        *)
            echo "[ERROR] Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Pre-run checks
check_chunky_mod || exit 1
check_world_exists "$WORLD" || exit 1

# Start chunk loading
start_chunk_loading

# Pause immediately if players are already online
if $INITIAL_PAUSE; then
    pause_chunk_loading
fi

# Ensure latest.log exists
if [[ ! -f "$LOG_FILE" ]]; then
    echo "[INFO] Waiting for latest.log to be created..."
    while [[ ! -f "$LOG_FILE" ]]; do sleep 1; done
fi

# Monitor the log for join/leave events
echo "[INFO] Monitoring player join/leave events..."

tail -n0 -F "$LOG_FILE" | while read -r line; do
    if [[ "$line" =~ \]:\ ([a-zA-Z0-9_]+)\ joined\ the\ game ]]; then
        player="${BASH_REMATCH[1]}"
        handle_player_event "$player" "join"
    elif [[ "$line" =~ \]:\ ([a-zA-Z0-9_]+)\ left\ the\ game ]]; then
        player="${BASH_REMATCH[1]}"
        handle_player_event "$player" "leave"
    fi
done
