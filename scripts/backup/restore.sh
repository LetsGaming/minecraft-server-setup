#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/load_variables.sh"

BASE_BACKUP_DIR="$SERVER_PATH/backups"
BACKUP_DIR="$BASE_BACKUP_DIR"

SKIP_CONFIRMATION=false
SPECIFIC_BACKUP=""
RELATIVE_TIME=""
FROM_ARCHIVE=false

print_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --y                   Skip confirmation prompt"
    echo "  --file <filename>     Restore a specific backup file"
    echo "  --ago <duration>      Restore backup closest to specified time ago (e.g. '3h', '15m', '2d')"
    echo "  --archive             Restore from the archive folder instead of normal backups"
    echo "  --help                Show this help message and exit"
    echo ""
    echo "Examples:"
    echo "  $0 --y"
    echo "  $0 --file backup-2024-12-01_01-00.tar.gz"
    echo "  $0 --ago 5h --archive"
}

normalize_relative_time() {
    local input="$1"
    if [[ "$input" =~ ^([0-9]+)([smhdw])$ ]]; then
        local value="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        case "$unit" in
            s) echo "$value seconds ago" ;;
            m) echo "$value minutes ago" ;;
            h) echo "$value hours ago" ;;
            d) echo "$value days ago" ;;
            w) echo "$value weeks ago" ;;
            *) return 1 ;;
        esac
    else
        return 1
    fi
}

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

sudo systemctl stop "$MODPACK_NAME" || true

if [ "$FROM_ARCHIVE" = true ]; then
    BACKUP_DIR="$BASE_BACKUP_DIR/archives"
    echo "$(date +'%F %T') [INFO] Restoring from archive backups: $BACKUP_DIR"
else
    BACKUP_DIR="$BASE_BACKUP_DIR/hourly"
fi

if $FROM_ARCHIVE; then
    FIND_DEPTH=""
else
    FIND_DEPTH="-maxdepth 1"
fi

find_latest_backup_file() {
    find "$BACKUP_DIR" $FIND_DEPTH -type f \( -name '*.tar.gz' -o -name '*.tar.zst' \) -printf '%T@ %p\n' \
        | sort -nr | head -n1 | cut -d' ' -f2-
}

find_closest_backup_by_time() {
    local target_ts="$1"
    find "$BACKUP_DIR" $FIND_DEPTH -type f \( -name '*.tar.gz' -o -name '*.tar.zst' \) -printf '%T@ %p\n' \
        | awk -v tgt="$target_ts" '
            {
                diff = ($1 - tgt); if (diff < 0) diff = -diff;
                print diff, $0;
            }' \
        | sort -n | head -n1 | cut -d' ' -f2-
}

if [[ -n "$SPECIFIC_BACKUP" ]]; then
    BACKUP_TO_RESTORE=$(find "$BACKUP_DIR" -type f -name "$SPECIFIC_BACKUP" | head -n1)
    if [[ -z "$BACKUP_TO_RESTORE" || ! -f "$BACKUP_TO_RESTORE" ]]; then
        echo "$(date +'%F %T') [ERROR] Specified backup file does not exist: $SPECIFIC_BACKUP" >&2
        exit 1
    fi
elif [[ -n "$RELATIVE_TIME" ]]; then
    HUMAN_TIME=$(normalize_relative_time "$RELATIVE_TIME")
    if [[ -z "$HUMAN_TIME" ]]; then
        echo "$(date +'%F %T') [ERROR] Invalid time format for --ago: $RELATIVE_TIME" >&2
        exit 1
    fi
    TARGET_TIMESTAMP=$(date -d "$HUMAN_TIME" +%s 2>/dev/null || true)
    if [[ -z "$TARGET_TIMESTAMP" ]]; then
        echo "$(date +'%F %T') [ERROR] Could not parse relative time: $RELATIVE_TIME" >&2
        exit 1
    fi
    BACKUP_TO_RESTORE=$(find_closest_backup_by_time "$TARGET_TIMESTAMP")
else
    BACKUP_TO_RESTORE=$(find_latest_backup_file)
fi

if [[ -z "$BACKUP_TO_RESTORE" || ! -f "$BACKUP_TO_RESTORE" ]]; then
    echo "$(date +'%F %T') [ERROR] No suitable backup found in $BACKUP_DIR." >&2
    exit 1
fi

if [[ ! -r "$BACKUP_TO_RESTORE" ]]; then
    echo "$(date +'%F %T') [ERROR] Cannot read backup file: $BACKUP_TO_RESTORE" >&2
    exit 1
fi

echo "$(date +'%F %T') [INFO] Selected backup: $BACKUP_TO_RESTORE"

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

echo "$(date +'%F %T') [INFO] Restoring backup..."

case "$BACKUP_TO_RESTORE" in
    *.tar.gz)
        tar -xvzf "$BACKUP_TO_RESTORE" -C "$SERVER_PATH"
        ;;
    *.tar.zst)
        zstd -d "$BACKUP_TO_RESTORE" -o "$BACKUP_TO_RESTORE.tar"
        tar -xvf "$BACKUP_TO_RESTORE.tar" -C "$SERVER_PATH"
        rm -f "$BACKUP_TO_RESTORE.tar"
        ;;
    *)
        echo "$(date +'%F %T') [ERROR] Unsupported backup file format: $BACKUP_TO_RESTORE" >&2
        exit 1
        ;;
esac

echo "$(date +'%F %T') [INFO] Restore completed successfully from $BACKUP_TO_RESTORE"
bash "$SCRIPT_DIR/../start.sh"
