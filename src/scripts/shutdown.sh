#!/bin/bash

set -e

# Source the common server control functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/server_control.sh"
source "$SCRIPT_DIR/common/validate.sh"

# --validate: check prerequisites without performing any action
[[ "${1:-}" == "--validate" ]] && { run_validate; exit $?; }

echo "Starting server shutdown script..."

# Notify all users the server will shut down in 30 seconds
send_message "The server will §6shutdown§r in 30 seconds. Please finish what you're doing."

# Wait for 25 seconds
sleep 25

# Countdown from 5 to 1 seconds with red color for countdown
countdown "Shutdown"

# Send save command and wait for completion
# A save that is not confirmed must not stop the shutdown (S-012): players
# were already warned, and systemd's stop saves the world on its way down.
save_and_wait || echo "[WARN] The save was not confirmed; continuing, the server saves again as it stops."

# Send shutdown message
send_message "Server §6is shutting down§r now!"

# Stop the server
systemctl_cmd stop

echo "Server stopped."
