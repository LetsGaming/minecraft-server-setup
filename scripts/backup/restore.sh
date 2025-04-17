#!/bin/bash

set -euo pipefail

# Get the absolute path of the directory where *this script* resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the server_control.sh script from the common folder
source "$SCRIPT_DIR/../common/server_control.sh"

# Default backup directory (can change if --from-archive is passed)
BASE_BACKUP_DIR="$SERVER_PATH/backups"
BACKUP_DIR="$BASE_BACKUP_DIR"

# Defaults
SKIP_CONFIRMATION=false
SPECIFIC_BACKUP=""
RELATIVE_TIME=""
FROM_ARCHIVE=false

# Help function
print_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --y                   Skip confirmation prompt"
    echo "  --file <filename>     Restore a specific backup file"
    echo "  --ago <duration>      Restore backup closest to specified time ago (e.g. '3h', '2d')"
    echo "  --archive             Restore from the archive folder instead of normal backups"
    echo "  --help                Show this help message and exit"
    echo ""
    echo "Examples:"
    echo "  $0 --y"
    echo "  $0 --file backup-2024-12-01_01-00.tar.gz"
    echo "  $0 --ago 5h --archive"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --y)
            SKIP_CONFIRMATION=true
            shift
            ;;
        --file)
            SPECIFIC_BACKUP="$2"
            shift 2
            ;;
        --ago)
            RELATIVE_TIME="$2"
            shift 2
            ;;
        --archive)
            FROM_ARCHIVE=true
            shift
            ;;
        --help)
            print_help
            exit 0
            ;;
        *)
            echo "$(date +'%F %T') [ERROR] Unknown argument: $1" >&2
            echo "Try '$0 --help' for usage information."
            exit 1
            ;;
    esac
done

# Stop the server before restoring
send_message "Restoring backup for $MODPACK_NAME"
bash "$SCRIPT_DIR/../shutdown.sh"

# Use archive folder if requested
if [ "$FROM_ARCHIVE" = true ]; then
    BACKUP_DIR="$BASE_BACKUP_DIR/archives"
    echo "$(date +'%F %T') [INFO] Restoring from archive backups: $BACKUP_DIR"
fi

# Determine which backup to use
if [[ -n "$SPECIFIC_BACKUP" ]]; then
    if $FROM_ARCHIVE; then
        BACKUP_TO_RESTORE=$(find "$BACKUP_DIR" -type f -name "$SPECIFIC_BACKUP" | head -n1)
    else
        BACKUP_TO_RESTORE="$BACKUP_DIR/$SPECIFIC_BACKUP"
    fi
    if [[ -z "$BACKUP_TO_RESTORE" || ! -f "$BACKUP_TO_RESTORE" ]]; then
        echo "$(date +'%F %T') [ERROR] Specified backup file does not exist: $BACKUP_TO_RESTORE" >&2
        exit 1
    fi
elif [[ -n "$RELATIVE_TIME" ]]; then
    TARGET_TIMESTAMP=$(date -d "$RELATIVE_TIME ago" +%s 2>/dev/null || true)
    if [[ -z "$TARGET_TIMESTAMP" ]]; then
        echo "$(date +'%F %T') [ERROR] Invalid time format for --ago: $RELATIVE_TIME" >&2
        exit 1
    fi
    BACKUP_TO_RESTORE=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' \
        | awk -v tgt="$TARGET_TIMESTAMP" '
            {
                diff = ($1 - tgt); if (diff < 0) diff = -diff;
                print diff, $0;
            }' \
        | sort -n | head -n1 | cut -d' ' -f2-)
    if [[ -z "$BACKUP_TO_RESTORE" ]]; then
        echo "$(date +'%F %T') [ERROR] No suitable backup found for --ago $RELATIVE_TIME" >&2
        exit 1
    fi
else
    BACKUP_TO_RESTORE=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' \
        | sort -nr | head -n1 | cut -d' ' -f2-)
    if [[ -z "$BACKUP_TO_RESTORE" ]]; then
        echo "$(date +'%F %T') [ERROR] No backup found in $BACKUP_DIR." >&2
        exit 1
    fi
fi

# Double-check file is readable
if [[ ! -r "$BACKUP_TO_RESTORE" ]]; then
    echo "$(date +'%F %T') [ERROR] Cannot read backup file: $BACKUP_TO_RESTORE" >&2
    exit 1
fi

echo "$(date +'%F %T') [INFO] Selected backup: $BACKUP_TO_RESTORE"

# Warn if restoring into non-empty server dir
if [ "$(ls -A "$SERVER_PATH")" ]; then
    echo "$(date +'%F %T') [WARN] $SERVER_PATH is not empty and may be overwritten by the restore."
    if [ "$SKIP_CONFIRMATION" = false ]; then
        read -rp "Continue with restore? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "$(date +'%F %T') [INFO] Restore aborted."
            exit 0
        fi
    else
        echo "$(date +'%F %T') [INFO] Skipping confirmation due to --y flag."
    fi
fi

# Extract backup
echo "$(date +'%F %T') [INFO] Restoring backup..."
tar -xzf "$BACKUP_TO_RESTORE" -C "$SERVER_PATH"
echo "$(date +'%F %T') [INFO] Restore completed successfully from $BACKUP_TO_RESTORE"

# Restart server
bash "$SCRIPT_DIR/../start.sh"
