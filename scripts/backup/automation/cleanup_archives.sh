#!/bin/bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/../common/load_variables.sh"

echo "[$(date +'%F %T')] Starting cleanup..."

# ——— hourly backups ———
HOURLY_DIR="$SERVER_PATH/backups/hourly"
if [[ -z "$MAX_BACKUPS" || "$MAX_BACKUPS" -lt 1 ]]; then
  echo "ERROR: MAX_BACKUPS is not set or invalid (value: '$MAX_BACKUPS')" >&2
  exit 1
fi

BACKUPS_TO_DELETE=$(ls -1t "$HOURLY_DIR"/minecraft_backup_*.tar.gz 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)))
if [[ -n "$BACKUPS_TO_DELETE" ]]; then
  echo "$BACKUPS_TO_DELETE" | xargs -r rm -v
else
  echo "No old hourly backups to delete."
fi

# ——— daily ———
find "$SERVER_PATH/backups/archives/daily" -type f -name '*.tar.gz' -mtime +7 -delete

# ——— weekly ———
find "$SERVER_PATH/backups/archives/weekly" -type f -name '*.tar.gz' -mtime +28 -delete

# ——— monthly ———
find "$SERVER_PATH/backups/archives/monthly" -type f -name '*.tar.gz' -mtime +180 -delete

echo "Cleanup complete."
