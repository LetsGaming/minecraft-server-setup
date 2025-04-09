#!/bin/bash

# Source the common server control functions
source ./common/server_control.sh

echo "Starting server shutdown script..."

# Notify all users the server will shut down in 30 seconds
send_message "The server will §6shutdown§r in 30 seconds. Please finish what you're doing."

# Wait for 25 seconds
sleep 25

# Countdown from 5 to 1 seconds with red color for countdown
countdown "Shutdown"

# Send save command and wait for completion
save_and_wait

# Send shutdown message
send_message "Server §6is shutting down§r now!"

# Stop the server
sudo systemctl stop minecraft.service

echo "Server stopped."
