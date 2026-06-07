#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/server_control.sh"
source "$SCRIPT_DIR/common/validate.sh"

# --validate: check prerequisites without performing any action
[[ "${1:-}" == "--validate" ]] && { run_validate; exit $?; }

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
systemctl_cmd restart

echo "Server restart initiated."
