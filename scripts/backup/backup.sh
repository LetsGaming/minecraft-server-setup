#!/bin/bash

set -e

# Get the absolute path of the directory where *this script* resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the server_control.sh script from the common folder
source "$SCRIPT_DIR/../common/server_control.sh"

# Reference the backup directory and set up a timestamped backup archive
BACKUP_DIR="$SERVER_PATH/backups"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_ARCHIVE="$BACKUP_DIR/minecraft_backup_$DATE.tar.gz"

# Ensure the backup directory exists
mkdir -p "$BACKUP_DIR"

# Perform server save before backup
save_and_wait

# Start the backup process
echo "Starting backup of the Minecraft server world..."

# Backup the world folder, server properties, plugins, and configs
tar -czf "$BACKUP_ARCHIVE" -C "$SERVER_PATH" world server.properties plugins configs

# Check if the backup was successful
if [ $? -eq 0 ]; then
    echo "Backup completed successfully: $BACKUP_ARCHIVE"
else
    echo "Backup failed!"
    exit 1
fi

# Cleanup: Delete oldest backups if there are more than MAX_BACKUPS
if [ -n "$MAX_BACKUPS" ]; then
    # Count current backups
    BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/minecraft_backup_*.tar.gz 2>/dev/null | wc -l)

    if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
        echo "Maximum number of backups exceeded ($MAX_BACKUPS). Cleaning up old backups..."

        # List backups sorted by modification time, oldest first, and delete excess
        ls -1t "$BACKUP_DIR"/minecraft_backup_*.tar.gz | tail -n +"$((MAX_BACKUPS + 1))" | while read -r old_backup; do
            echo "Deleting old backup: $old_backup"
            rm -f "$old_backup"
        done
    fi
else
    echo "Warning: MAX_BACKUPS is not set. Skipping cleanup of old backups."
fi
