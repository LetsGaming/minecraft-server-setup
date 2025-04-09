#!/bin/bash

# Source the common server control functions
source ./common/server_control.sh

echo "Starting server restart script..."

# Notify all users the server will restart in 30 seconds
send_message "The server will §6restart§r in 30 seconds. Please finish what you're doing."

# Wait for 25 seconds
sleep 25

# Countdown from 5 to 1 seconds with red color for countdown
countdown "Restart"

# Send save command and wait for completion
save_and_wait

# Send restart message
send_message "Server §6is restarting§r now!"

# Restart the server
sudo systemctl restart minecraft.service

echo "Server restart initiated."
