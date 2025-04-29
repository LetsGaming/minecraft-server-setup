#!/bin/bash

set -e

# Get the absolute path of the directory where *this script* resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load server control functions
source "$SCRIPT_DIR/../common/server_control.sh"

# Default world is "overworld"
WORLD="overworld"
RADIUS=200000

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

    # Check if the log contains the expected response indicating the world is valid
    if echo "$log_output" | grep -q "chunky world $world_name - Set the world target"; then
        echo "[ERROR] World '$world_name' is not valid or does not exist."
        return 1
    fi
    return 0
}

# Start chunk loading process
start_chunk_loading() {
    echo "[INFO] Starting chunk loading for $WORLD with a $RADIUS block radius."
    send_command "/chunky world $WORLD"
    send_command "/chunky radius $RADIUS"
    send_command "/chunky start"
    send_command "/chunky quiet 500"
}

# Pause chunk loading if players are online
pause_chunk_loading() {
    echo "[INFO] Pausing chunk loading due to players online."
    send_command "/chunky pause"
}

# Resume chunk loading when no players are online
resume_chunk_loading() {
    echo "[INFO] Resuming chunk loading as no players are online."
    send_command "/chunky resume"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --world)
            WORLD="$2"
            shift 2
            ;;
        *)
            echo "[ERROR] Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Check if Chunky mod is installed
if ! check_chunky_mod; then
    exit 1
fi

# Check if the world exists by using /chunky world <world> command
if ! check_world_exists "$WORLD"; then
    exit 1
fi

# Start chunk loading
start_chunk_loading

# Monitor player activity and control chunk loading
while true; do
    player_count=$(get_player_count)
    if [ "$player_count" -gt 0 ]; then
        pause_chunk_loading
        # Wait until no players are online before resuming chunk loading
        while [ "$player_count" -gt 0 ]; do
            sleep 10
            player_count=$(get_player_count)
        done
        resume_chunk_loading
    fi
    sleep 10  # Regularly check for players
done
