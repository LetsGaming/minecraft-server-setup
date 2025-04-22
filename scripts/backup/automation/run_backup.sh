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
  ARGS=(--archive monthly)
# Vater: Jeden Sonntag
elif [ "$DAY_OF_WEEK" -eq 7 ]; then
  MODE="weekly"
  ARGS=(--archive weekly)
# Enkel: Jeden Tag um 00:00 Uhr
elif [ "$HOUR" -eq 0 ]; then
  MODE="daily"
  ARGS=(--archive daily)
fi

echo "[$(date +'%F %T')] Starting $MODE backup..."
bash "$BACKUP_SCRIPT" "${ARGS[@]}"
