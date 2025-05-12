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

WEEKLY_FLAG="$STATE_DIR/weekly_$TODAY"

if $DO_GENERATION_BACKUPS; then
  # Großvater: Erster Sonntag im Monat
  if [ "$DAY_OF_WEEK" -eq 7 ] && [ "$DAY_OF_MONTH" -le 7 ] && [ ! -f "$STATE_DIR/monthly_$TODAY" ]; then
    echo "[$(date +'%F %T')] Starting monthly backup..."
    bash "$BACKUP_SCRIPT" --archive monthly
    touch "$STATE_DIR/monthly_$TODAY"
  fi

  # Vater: Jeden Sonntag - aber nur einmal
  if [ "$DAY_OF_WEEK" -eq 7 ]; then
    if [ ! -f "$WEEKLY_FLAG" ]; then
      echo "[$(date +'%F %T')] Starting weekly backup..."
      bash "$BACKUP_SCRIPT" --archive weekly
      touch "$WEEKLY_FLAG"
    fi
  fi

  # Enkel: Jeden Tag um 00:00 Uhr
  if [ "$HOUR" -eq 0 ] && [ ! -f "$STATE_DIR/daily_$TODAY" ]; then
    echo "[$(date +'%F %T')] Starting daily backup..."
    bash "$BACKUP_SCRIPT" --archive daily
    touch "$STATE_DIR/daily_$TODAY"
  fi
fi

# Immer: Stündlich
echo "[$(date +'%F %T')] Starting hourly backup..."
bash "$BACKUP_SCRIPT"

bash "$AUTOMATION_SCRIPT_DIR/cleanup_backups.sh"