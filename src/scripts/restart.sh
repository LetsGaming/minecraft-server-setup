#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/server_control.sh"
source "$SCRIPT_DIR/common/validate.sh"
source "$SCRIPT_DIR/common/utils.sh"
# Not while a backup, restore, rollback or upgrade runs (S-030): a scheduled
# restart used to stop the server in the middle of a backup. Exit 75 = busy.
acquire_operation_lock restart || exit 75

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
# A save that is not confirmed must not stop the shutdown (S-012): players
# were already warned, and systemd's stop saves the world on its way down.
save_and_wait || echo "[WARN] The save was not confirmed; continuing, the server saves again as it stops."

# Send restart message
send_message "Server §6is restarting§r now!"

# Restart the server
systemctl_cmd restart

echo "Server restart initiated."
