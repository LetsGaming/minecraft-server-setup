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
    if screen -list | grep -q "$INSTANCE_NAME"; then
        return 0  # Session is running
    else
        return 1  # Session is not running
    fi
}

read_log() {
    if [ -f "$LOG_FILE" ]; then
        # Use tail to get the last 10 lines of the log file
        tail -n 10 "$LOG_FILE"
    else
        echo "Log file not found: $LOG_FILE"
        return 1
    fi
}

send_command() {
    # Check if the screen session is running
    if ! session_running; then
        echo "Screen session '$INSTANCE_NAME' is not running. Cannot send command."
        return 1
    fi

    # Check if command has / prefix is provided if not add it
    if [[ "$1" != /* ]]; then
        echo "Command must start with a /, adding it automatically."
        command="/$1"
    else
        command="$1"
    fi


    command=$1
    if [ "$(id -u)" -eq 0 ]; then
        # If running as root (sudo), use sudo -u to run the command as the specified user
        sudo -u $USER screen -S $INSTANCE_NAME -p 0 -X stuff "$command$(printf \\r)"
    else
        # If not running as root, just run the command normally
        screen -S $INSTANCE_NAME -p 0 -X stuff "$command$(printf \\r)"
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

# Strip the typical Minecraft log prefix from a line
strip_log_prefix() {
    local line="$1"
    # Match the last "]: " and take everything after it
    if [[ "$line" == *"]: "* ]]; then
        echo "${line##*]: }"
    elif [[ "$line" == *"]: "* ]]; then
        echo "${line##*]:}" | sed 's/^[: ]*//'
    elif [[ "$line" == *": "* ]]; then
        echo "${line##*: }"
    else
        echo "$line"
    fi
}

get_player_list() {
    if ! session_running; then
        echo "Screen session '$INSTANCE_NAME' is not running. Cannot get player list."
        return 1
    fi

    if ! send_command "/list"; then
        echo "Failed to get player list."
        return 1
    fi

    # grab the last "There are ... players online" line (matches both new and old formats)
    local log_line
    log_line=$(read_log | grep -E "There are [0-9]+(/[0-9]+| of a max of [0-9]+) players online" | tail -n 1)

    if [[ -z "$log_line" ]]; then
        return 0
    fi

    # Try inline player list (newer versions)
    local player_list
    player_list=$(echo "$log_line" | sed -n 's/.*players online:\s*\(.*\)/\1/p')

    if [[ -z "$player_list" ]]; then
        # Older versions → get the *next line* after the match
        local next_line
        next_line=$(read_log | grep -A1 -F "$log_line" | tail -n 1)
        player_list=$(strip_log_prefix "$next_line")
    fi

    # Normalize spacing and echo as comma-separated string
    if [[ -n "$player_list" ]]; then
        echo "$player_list" | sed 's/, */, /g' | sed 's/^ *//;s/ *$//'
    fi
}

# Get the number of players currently online
get_player_count() {
    player_list=$(get_player_list)
    echo "$player_list" | grep -o '\S' | wc -l
}

# Function to check if the server has completed the save-all process by monitoring the log file
wait_for_save_completion() {
    if ! session_running; then
        echo "Screen session '$INSTANCE_NAME' is not running. Cannot wait for save completion."
        return 1
    fi

    echo "Waiting for save to complete..."
    # Tail log and stop once a save completion line appears
    tail -n 0 -f "$LOG_FILE" | while read -r line; do
        if echo "$line" | grep -Eq "Saved the (game|world)|Saved"; then
            echo "Save completed."
            break
        fi
    done
}

# Function to countdown before shutdown or restart
countdown() {
    local base_message="$1" # e.g., "Restarting"
    local start="${2:-5}"
    local end="${3:-1}"

    for ((i=start; i>=end; i--)); do
        # We construct the message fresh every time to avoid appending
        local current_announcement="$base_message in §4$i§r seconds!"
        
        send_message "$current_announcement"
        
        # Only sleep if we aren't at the last second to keep the 
        # execution timing tight
        if [ $i -gt $end ]; then
            sleep 1
        fi
    done
}

# Function to perform server save and wait for completion
save_and_wait() {
    send_message "Saving the server now to ensure no data is lost..."
    send_command "/save-all"
    wait_for_save_completion
}
