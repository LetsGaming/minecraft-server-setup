#!/bin/bash
set -e

AUTOMATION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$AUTOMATION_SCRIPT_DIR/../backup.sh"

source "$AUTOMATION_SCRIPT_DIR/../../common/load_variables.sh"
STATE_DIR="/tmp/backup_flags"

mkdir -p "$STATE_DIR"

HOUR=$(date +%H)
DAY_OF_WEEK=$(date +%u)  # 1 (Mo) – 7 (So)
DAY_OF_MONTH=$(date +%d)
TODAY=$(date +%F)         # YYYY-MM-DD

DAILY_FLAG="$STATE_DIR/daily_$TODAY"
WEEKLY_FLAG="$STATE_DIR/weekly_$TODAY"
MONTHLY_FLAG="$STATE_DIR/monthly_$TODAY"

if $DO_GENERATION_BACKUPS; then
  # Großvater: Erster Sonntag im Monat (Priority 1)
  if [ "$DAY_OF_WEEK" -eq 7 ] && [ "$DAY_OF_MONTH" -le 7 ] && [ ! -f "$MONTHLY_FLAG" ]; then
    echo "[$(date +'%F %T')] Starting monthly backup..."
    bash "$BACKUP_SCRIPT" --archive monthly
    touch "$MONTHLY_FLAG"
    exit 0
  fi

  # Vater: Jeden Sonntag (Priority 2)
  if [ "$DAY_OF_WEEK" -eq 7 ] && [ ! -f "$WEEKLY_FLAG" ]; then
    echo "[$(date +'%F %T')] Starting weekly backup..."
    bash "$BACKUP_SCRIPT" --archive weekly
    touch "$WEEKLY_FLAG"
    exit 0
  fi

  # Enkel: Jeden Tag um 00:00 Uhr (Priority 3)
  if [ "$HOUR" -eq 0 ] && [ ! -f "$DAILY_FLAG" ]; then
    echo "[$(date +'%F %T')] Starting daily backup..."
    bash "$BACKUP_SCRIPT" --archive daily
    touch "$DAILY_FLAG"
    exit 0
  fi
fi

# Immer: Stündlich (Lowest priority - fallback)
echo "[$(date +'%F %T')] Starting hourly backup..."
bash "$BACKUP_SCRIPT"

# Cleanup step
bash "$AUTOMATION_SCRIPT_DIR/cleanup_backups.sh"