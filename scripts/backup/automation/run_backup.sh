#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/../backup.sh"

HOUR=$(date +%H)
DAY_OF_WEEK=$(date +%u)  # 1 (Mo) – 7 (So)
DAY_OF_MONTH=$(date +%d)

MODE="hourly"
ARGS=()

# Großvater: Erster Sonntag im Monat
if [ "$DAY_OF_WEEK" -eq 7 ] && [ "$DAY_OF_MONTH" -le 7 ]; then
  MODE="monthly"
  ARCHIVE_TYPE=monthly
  ARGS=(--archive)
# Vater: Jeden Sonntag
elif [ "$DAY_OF_WEEK" -eq 7 ]; then
  MODE="weekly"
  ARCHIVE_TYPE=weekly
  ARGS=(--archive)
# Enkel: Jeden Tag um 00:00 Uhr
elif [ "$HOUR" -eq 0 ]; then
  MODE="daily"
  ARCHIVE_TYPE=daily
  ARGS=(--archive)
fi

echo "[$(date +'%F %T')] Starting $MODE backup..."

if [[ "$MODE" != "hourly" ]]; then
  ARCHIVE_TYPE="$ARCHIVE_TYPE" "$BACKUP_SCRIPT" "${ARGS[@]}"
else
  "$BACKUP_SCRIPT"
fi
