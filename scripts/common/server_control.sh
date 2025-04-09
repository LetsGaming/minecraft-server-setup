#!/bin/bash

# Load variables from variables.txt
source "$(dirname "$0")/variables.txt"

# Check if MODPACK_NAME is set
if [ -z "$MODPACK_NAME" ]; then
    echo "Error: MODPACK_NAME is not set in variables.txt"
    exit 1
fi

# Set the name of the screen session (adjust if needed)
SCREEN_SESSION_NAME="$MODPACK_NAME"
SERVER_FOLDER="/home/minecraft/minecraft-server/$MODPACK_NAME"  # Base folder for the server
LOG_FILE="$SERVER_FOLDER/logs/latest.log"    # Combine to get the full log file path

# Function to send a message to the server via /say command in the Minecraft server
send_message() {
    message=$1
    screen -S $SCREEN_SESSION_NAME -p 0 -X stuff "/say $message$(printf \\r)"
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
    screen -S $SCREEN_SESSION_NAME -p 0 -X stuff "/save-all$(printf \\r)"
    wait_for_save_completion
}
