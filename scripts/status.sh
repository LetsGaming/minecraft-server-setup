#!/bin/bash

set -e

# Get the absolute path of the directory where *this script* resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the server_control.sh script from the common directory
source "$SCRIPT_DIR/common/server_control.sh"

# Get the server running status and player list
if ! session_running; then
    SERVER_RUNNING="Not Running"
    PLAYER_LIST="Server is not running, no player list available."
else
    SERVER_RUNNING="Running"
    PLAYER_LIST=$(get_player_list)
fi

# Create status message
MESSAGE="Server Status: $SERVER_RUNNING\n"
if [ "$SERVER_RUNNING" == "Running" ]; then
    MESSAGE+="| Player List: "
    if [ -z "$PLAYER_LIST" ]; then
        MESSAGE+="No players online.\n"
    else
        MESSAGE+="$PLAYER_LIST\n"
    fi
fi

# Display status
echo -e "$MESSAGE"
