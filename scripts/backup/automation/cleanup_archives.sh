#!/bin/bash
set -e

# Load the environment variables from the JavaScript setup
source "$(dirname "${BASH_SOURCE[0]}")/../../common/load_variables.sh"

echo "[$(date +'%F %T')] Starting cleanup..."

# ——— hourly backups ———
if [[ -z "$MAX_HOURLY_BACKUPS" || "$MAX_HOURLY_BACKUPS" -lt 1 ]]; then
  echo "ERROR: MAX_HOURLY_BACKUPS is not set or invalid (value: '$MAX_HOURLY_BACKUPS')" >&2
  exit 1
fi

# Count the number of hourly backups
HOURLY_BACKUPS_COUNT=$(ls -1 "$SERVER_PATH/backups/archives/hourly/minecraft_backup_*.tar.gz" 2>/dev/null | wc -l)
if [[ "$HOURLY_BACKUPS_COUNT" -gt "$MAX_HOURLY_BACKUPS" ]]; then
  BACKUPS_TO_DELETE=$(ls -1t "$SERVER_PATH/backups/archives/hourly/minecraft_backup_*.tar.gz" 2>/dev/null | tail -n +$((MAX_HOURLY_BACKUPS + 1)))
  if [[ -n "$BACKUPS_TO_DELETE" ]]; then
    echo "Deleting old hourly backups..."
    echo "$BACKUPS_TO_DELETE" | xargs -r rm -v
  else
    echo "No old hourly backups to delete."
  fi
else
  echo "No old hourly backups to delete."
fi

# ——— daily backups ———
if [[ -z "$MAX_DAILY_BACKUPS" || "$MAX_DAILY_BACKUPS" -lt 1 ]]; then
  echo "ERROR: MAX_DAILY_BACKUPS is not set or invalid (value: '$MAX_DAILY_BACKUPS')" >&2
  exit 1
fi

# Count the number of daily backups
DAILY_BACKUPS_COUNT=$(ls -1 "$SERVER_PATH/backups/archives/daily/minecraft_backup_*.tar.gz" 2>/dev/null | wc -l)
if [[ "$DAILY_BACKUPS_COUNT" -gt "$MAX_DAILY_BACKUPS" ]]; then
  BACKUPS_TO_DELETE=$(ls -1t "$SERVER_PATH/backups/archives/daily/minecraft_backup_*.tar.gz" 2>/dev/null | tail -n +$((MAX_DAILY_BACKUPS + 1)))
  if [[ -n "$BACKUPS_TO_DELETE" ]]; then
    echo "Deleting old daily backups..."
    echo "$BACKUPS_TO_DELETE" | xargs -r rm -v
  else
    echo "No old daily backups to delete."
  fi
else
  echo "No old daily backups to delete."
fi

# ——— weekly backups ———
if [[ -z "$MAX_WEEKLY_BACKUPS" || "$MAX_WEEKLY_BACKUPS" -lt 1 ]]; then
  echo "ERROR: MAX_WEEKLY_BACKUPS is not set or invalid (value: '$MAX_WEEKLY_BACKUPS')" >&2
  exit 1
fi

# Count the number of weekly backups
WEEKLY_BACKUPS_COUNT=$(ls -1 "$SERVER_PATH/backups/archives/weekly/minecraft_backup_*.tar.gz" 2>/dev/null | wc -l)
if [[ "$WEEKLY_BACKUPS_COUNT" -gt "$MAX_WEEKLY_BACKUPS" ]]; then
  BACKUPS_TO_DELETE=$(ls -1t "$SERVER_PATH/backups/archives/weekly/minecraft_backup_*.tar.gz" 2>/dev/null | tail -n +$((MAX_WEEKLY_BACKUPS + 1)))
  if [[ -n "$BACKUPS_TO_DELETE" ]]; then
    echo "Deleting old weekly backups..."
    echo "$BACKUPS_TO_DELETE" | xargs -r rm -v
  else
    echo "No old weekly backups to delete."
  fi
else
  echo "No old weekly backups to delete."
fi

# ——— monthly backups ———
if [[ -z "$MAX_MONTHLY_BACKUPS" || "$MAX_MONTHLY_BACKUPS" -lt 1 ]]; then
  echo "ERROR: MAX_MONTHLY_BACKUPS is not set or invalid (value: '$MAX_MONTHLY_BACKUPS')" >&2
  exit 1
fi

# Count the number of monthly backups
MONTHLY_BACKUPS_COUNT=$(ls -1 "$SERVER_PATH/backups/archives/monthly/minecraft_backup_*.tar.gz" 2>/dev/null | wc -l)
if [[ "$MONTHLY_BACKUPS_COUNT" -gt "$MAX_MONTHLY_BACKUPS" ]]; then
  BACKUPS_TO_DELETE=$(ls -1t "$SERVER_PATH/backups/archives/monthly/minecraft_backup_*.tar.gz" 2>/dev/null | tail -n +$((MAX_MONTHLY_BACKUPS + 1)))
  if [[ -n "$BACKUPS_TO_DELETE" ]]; then
    echo "Deleting old monthly backups..."
    echo "$BACKUPS_TO_DELETE" | xargs -r rm -v
  else
    echo "No old monthly backups to delete."
  fi
else
  echo "No old monthly backups to delete."
fi

echo "Cleanup complete."
