#!/bin/bash

set -e

# Get the absolute path of the directory where *this script* resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load variables from the common folder
source "$SCRIPT_DIR/load_variables.sh"

# Reference log file based on loaded variable
LOG_FILE="$SERVER_PATH/logs/latest.log"

session_running() {
    # Check if the screen session is running
    if screen -list | grep -q "$MODPACK_NAME"; then
        return 0  # Session is running
    else
        return 1  # Session is not running
    fi
}

read_log() {
    # Read the last line of the log file
    tail -n 1 "$LOG_FILE"
}

send_command() {
    # Check if the screen session is running
    if ! session_running; then
        echo "Screen session '$MODPACK_NAME' is not running. Cannot send command."
        return 1
    fi

    command=$1
    if [ "$(id -u)" -eq 0 ]; then
        # If running as root (sudo), use sudo -u to run the command as the specified user
        sudo -u $USER screen -S $MODPACK_NAME -p 0 -X stuff "$command$(printf \\r)"
    else
        # If not running as root, just run the command normally
        screen -S $MODPACK_NAME -p 0 -X stuff "$command$(printf \\r)"
    fi
}

# Function to send a message to the server via /say command in the Minecraft server
send_message() {
    message=$1
    send_command "/say $message"
}

# Function to disable auto saving
disable_auto_save() {
    send_command "/save-off"
}

# Function to re-enable auto saving
enable_auto_save() {
    send_command "/save-on"
}

get_player_list() { 
    # Check if the screen session is running
    if ! session_running; then
        echo "Screen session '$MODPACK_NAME' is not running. Cannot get player list."
        return 1
    fi

    # Send the /list command to the Minecraft server
    if send_command "/list"; then
        # Capture the last line from the log
        LOG_LINE=$(read_log)

        # Extract player names from the log line
        PLAYER_LIST=$(echo "$LOG_LINE" | sed -n 's/There are [0-9]* of a max of [0-9]* players online: \(.*\)/\1/p')

        if [ "$PLAYER_LIST" ]; then
            # Clean up the player list (replace commas with newlines and remove extra spaces)
            PLAYER_LIST=$(echo "$PLAYER_LIST" | tr ',' '\n' | tr -s ' ' '\n')
            echo "$PLAYER_LIST"
        fi
        
    else
        echo "Failed to get player list."
    fi
}

# Function to check if the server has completed the save-all process by monitoring the log file
wait_for_save_completion() {
    if ! session_running; then
        echo "Screen session '$MODPACK_NAME' is not running. Cannot wait for save completion."
        return 1
    fi
    
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
    send_command "/save-all"
    wait_for_save_completion
}
