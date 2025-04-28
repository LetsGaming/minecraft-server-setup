#!/bin/bash

set -e

# Get the absolute path of the directory where *this script* resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the server_control.sh script from the common directory
source "$SCRIPT_DIR/common/server_control.sh"

# Get the server running status and player list
SERVER_RUNNING=$(session_running)
PLAYER_LIST=$(get_player_list)

# Create status message
MESSAGE="Server Status: "
if [ "$SERVER_RUNNING" -eq 0 ]; then
    MESSAGE+="Running\n"
else
    MESSAGE+="Not Running\n"
fi
if [ "$SERVER_RUNNING" -eq 0 ]; then
    MESSAGE+="Player List:\n"
    if [ -z "$PLAYER_LIST" ]; then
        MESSAGE+="No players online.\n"
    else
        MESSAGE+="$PLAYER_LIST\n"
    fi
else
    MESSAGE+="Server is not running, no player list available.\n"
fi

# Display status
echo -e "$MESSAGE"
