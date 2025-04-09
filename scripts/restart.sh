#!/bin/bash

# Set the name of the screen session (adjust if needed)
SCREEN_SESSION_NAME="minecraft"
SERVER_FOLDER="/home/minecraft/minecraft-server/dawncraft"  # Base folder for the server
LOG_FILE="$SERVER_FOLDER/logs/latest.log"    # Combine to get the full log file path

echo "Starting server restart script..."

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

# Notify all users the server will restart in 30 seconds
send_message "The server will §6restart§r in 30 seconds. Please finish what you're doing."

# Wait for 25 seconds
sleep 25

# Countdown from 5 to 1 seconds with red color for countdown
for i in 5 4 3 2 1; do
    send_message "§4Restart§r in §4$i§r seconds!"
    sleep 1  # Pause for 1 second to display each countdown message
done

# Send a save command to ensure the world is saved before restart
send_message "Saving the server now to ensure no data is lost..."
screen -S $SCREEN_SESSION_NAME -p 0 -X stuff "/save-all$(printf \\r)"

# Wait for the save to complete by monitoring the log file
wait_for_save_completion

# Finally, send the "Server Restarting" message with orange color for "restart"
send_message "Server §6is restarting§r now!"

# Restart the server
sudo systemctl restart minecraft.service

echo "Server restart initiated."
