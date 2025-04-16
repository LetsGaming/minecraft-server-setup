#!/bin/bash

set -euo pipefail

# Get the absolute path of the directory where *this script* resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the server_control.sh script from the common folder
source "$SCRIPT_DIR/../common/server_control.sh"

# Backup directory
BACKUP_DIR="$SERVER_PATH/backups"

# Function to restart the server
restart() {
    bash "$SCRIPT_DIR/../restart.sh"
}

# Parse flags
SKIP_CONFIRMATION=false
for arg in "$@"; do
    case "$arg" in
        --y)
            SKIP_CONFIRMATION=true
            ;;
    esac
done

# Find the latest backup file (safely, even with spaces in filenames)
LATEST_BACKUP=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)

# Check if a backup was found and is readable
if [ -z "$LATEST_BACKUP" ] || [ ! -r "$LATEST_BACKUP" ]; then
    echo "Error: No readable backup file found in $BACKUP_DIR."
    exit 1
fi

echo "Found backup: $LATEST_BACKUP"

# Check if the target directory is non-empty and warn the user
if [ "$(ls -A "$SERVER_PATH")" ]; then
    echo "Warning: $SERVER_PATH is not empty and may be overwritten by the restore."
    if [ "$SKIP_CONFIRMATION" = false ]; then
        read -rp "Continue with restore? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Restore aborted."
            exit 0
        fi
    else
        echo "Skipping confirmation due to --y flag."
    fi
fi

# Extract the backup
echo "Restoring backup..."
tar -xzf "$LATEST_BACKUP" -C "$SERVER_PATH"
echo "Restore completed successfully from $LATEST_BACKUP"

# Restart the server
restart
