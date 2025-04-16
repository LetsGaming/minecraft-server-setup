#!/bin/bash

set -e

# Get the absolute path of the directory where *this script* resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the server_control.sh script from the common folder
source "$SCRIPT_DIR/../common/server_control.sh"

# Parse arguments
ARCHIVE_MODE=false
for arg in "$@"; do
    case "$arg" in
        --archive)
            ARCHIVE_MODE=true
            ;;
        --help)
            echo "Usage: $0 [--archive]"
            echo ""
            echo "Options:"
            echo "  --archive   Store the backup in an 'archives' folder to prevent it from being auto-deleted"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Try '$0 --help' for usage information."
            exit 1
            ;;
    esac
done

# Reference the backup directory and set up a timestamped backup archive
BACKUP_DIR="$SERVER_PATH/backups"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")

if [ "$ARCHIVE_MODE" = true ]; then
    BACKUP_DIR="$BACKUP_DIR/archives"
    echo "Archiving backup (will not be subject to auto-deletion)..."
fi

mkdir -p "$BACKUP_DIR"
BACKUP_ARCHIVE="$BACKUP_DIR/minecraft_backup_$DATE.tar.gz"

# Perform server save before backup
save_and_wait

# Start the backup process
echo "Starting backup of the Minecraft server world..."
tar -czf "$BACKUP_ARCHIVE" -C "$SERVER_PATH" world server.properties plugins configs

# Check if the backup was successful
if [ $? -eq 0 ]; then
    echo "Backup completed successfully: $BACKUP_ARCHIVE"
else
    echo "Backup failed!"
    exit 1
fi

# Cleanup only if not in archive mode
if [ "$ARCHIVE_MODE" = false ]; then
    if [ -n "${MAX_BACKUPS:-}" ]; then
        BACKUP_COUNT=$(ls -1 "$SERVER_PATH/backups"/minecraft_backup_*.tar.gz 2>/dev/null | wc -l)

        if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
            echo "Maximum number of backups exceeded ($MAX_BACKUPS). Cleaning up old backups..."
            ls -1t "$SERVER_PATH/backups"/minecraft_backup_*.tar.gz | tail -n +"$((MAX_BACKUPS + 1))" | while read -r old_backup; do
                echo "Deleting old backup: $old_backup"
                rm -f "$old_backup"
            done
        fi
    else
        echo "Warning: MAX_BACKUPS is not set. Skipping cleanup of old backups."
    fi
else
    echo "Archive mode active: skipping cleanup logic."
fi
