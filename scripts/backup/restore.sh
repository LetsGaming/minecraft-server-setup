#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/load_variables.sh"

BASE_BACKUP_DIR="$BACKUPS_PATH"
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
    echo "  --archive             Restore from the archive folder instead of hourly snapshots"
    echo "  --help                Show this help message and exit"
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
        --y) SKIP_CONFIRMATION=true; shift ;;
        --file) SPECIFIC_BACKUP="$2"; shift 2 ;;
        --ago) RELATIVE_TIME="$2"; shift 2 ;;
        --archive) FROM_ARCHIVE=true; shift ;;
        --help) print_help; exit 0 ;;
        *) echo "$(date +'%F %T') [ERROR] Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if $FROM_ARCHIVE; then
    BACKUP_DIR="$BASE_BACKUP_DIR/archives"
else
    BACKUP_DIR="$BASE_BACKUP_DIR/hourly"
fi

find_latest_backup() {
    find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.tar.*' \) -printf '%T@ %p\n' |
        sort -nr | head -n1 | cut -d' ' -f2-
}

find_closest_backup_by_time() {
    local target_ts="$1"
    find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.tar.*' \) -printf '%T@ %p\n' |
        awk -v tgt="$target_ts" '{ diff = ($1 - tgt); if (diff < 0) diff = -diff; print diff, $0; }' |
        sort -n | head -n1 | cut -d' ' -f2-
}

if [[ -n "$SPECIFIC_BACKUP" ]]; then
    BACKUP_TO_RESTORE="$BACKUP_DIR/$SPECIFIC_BACKUP"
    [[ -e "$BACKUP_TO_RESTORE" ]] || { echo "[ERROR] Specified backup does not exist: $SPECIFIC_BACKUP"; exit 1; }
elif [[ -n "$RELATIVE_TIME" ]]; then
    HUMAN_TIME=$(normalize_relative_time "$RELATIVE_TIME") || {
        echo "[ERROR] Invalid time format for --ago: $RELATIVE_TIME"; exit 1;
    }
    TARGET_TIMESTAMP=$(date -d "$HUMAN_TIME" +%s) || {
        echo "[ERROR] Failed to parse relative time: $RELATIVE_TIME"; exit 1;
    }
    BACKUP_TO_RESTORE=$(find_closest_backup_by_time "$TARGET_TIMESTAMP")
else
    BACKUP_TO_RESTORE=$(find_latest_backup)
fi

[[ -e "$BACKUP_TO_RESTORE" ]] || { echo "[ERROR] No suitable backup found."; exit 1; }

echo "[INFO] Selected backup: $BACKUP_TO_RESTORE"

if [ "$(ls -A "$SERVER_PATH")" ]; then
    echo "[WARN] $SERVER_PATH is not empty and will be overwritten."
    if [ "$SKIP_CONFIRMATION" = false ]; then
        read -rp "Continue with restore? (y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { echo "[INFO] Restore aborted."; exit 0; }
    fi
fi

rm -rf "$SERVER_PATH"/*
echo "[INFO] Restoring backup..."

if [[ "$BACKUP_TO_RESTORE" == *.tar.gz ]]; then
    tar -xvzf "$BACKUP_TO_RESTORE" -C "$SERVER_PATH"
elif [[ "$BACKUP_TO_RESTORE" == *.tar.zst ]]; then
    zstd -d "$BACKUP_TO_RESTORE" -c | tar -xvf - -C "$SERVER_PATH"
else
    echo "[ERROR] Unsupported backup file format: $BACKUP_TO_RESTORE"
    exit 1
fi

echo "[INFO] Restore complete."
