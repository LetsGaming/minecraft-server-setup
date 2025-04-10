#!/bin/bash

set -e

# Get the absolute path of the directory where *this script* resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load variables from the common folder
source "$SCRIPT_DIR/load_variables.sh"

# Reference log file based on loaded variable
LOG_FILE="$SERVER_PATH/logs/latest.log"

send_command() {
    command=$1
    screen -S $MODPACK_NAME -p 0 -X stuff "$command$(printf \\r)"
}

# Function to send a message to the server via /say command in the Minecraft server
send_message() {
    message=$1
    send_command "/say $message"
}

# Function to check if the server has completed the save-all process by monitoring the log file
wait_for_save_completion() {
    echo "Waiting for save to complete..."

    # Tail the log file and look for the "Saved the game" message
    tail -n 0 -f "$LOG_FILE" | while read line; do
        if echo "$line" | grep -q "Saved the game"; then
            echo "Save completed."
            break
        fi
    done
}

# Function to countdown before shutdown or restart
countdown() {
    for i in 5 4 3 2 1; do
        send_message "$1 in §4$i§r seconds!"
        sleep 1  # Pause for 1 second to display each countdown message
    done
}

# Function to perform server save and wait for completion
save_and_wait() {
    send_message "Saving the server now to ensure no data is lost..."
    screen -S $MODPACK_NAME -p 0 -X stuff "/save-all$(printf \\r)"
    wait_for_save_completion
}
