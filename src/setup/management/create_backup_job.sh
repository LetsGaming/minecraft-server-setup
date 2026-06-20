#!/bin/bash
set -e

# Replaces create_backup_job.js — installs the hourly backup cron entry,
# idempotently. Uses `crontab -` (read from stdin) so no temp file is needed.

: "${MAIN_DIR:?MAIN_DIR not set}"
: "${TARGET_DIR_NAME:?TARGET_DIR_NAME not set}"
: "${INSTANCE_NAME:?INSTANCE_NAME not set}"

SCRIPTS_DIR="$MAIN_DIR/$TARGET_DIR_NAME/scripts/$INSTANCE_NAME"
RUN_BACKUP="$SCRIPTS_DIR/backup/automation/run_backup.sh"
LOGS_DIR="$SCRIPTS_DIR/backup/logs"

if [ ! -f "$RUN_BACKUP" ]; then
  echo "Backup wrapper script not found: $RUN_BACKUP" >&2
  exit 1
fi

mkdir -p "$LOGS_DIR"

HOURLY_CMD="0 * * * * bash $RUN_BACKUP >> $LOGS_DIR/backup.log 2>&1"

# Existing crontab (empty if the user has none — crontab -l exits 1 then)
existing="$(crontab -l 2>/dev/null || true)"

if printf '%s\n' "$existing" | grep -qF "$RUN_BACKUP"; then
  echo "Hourly backup cronjob already exists. Skipping."
else
  {
    [ -n "$existing" ] && printf '%s\n' "$existing"
    printf '%s\n' "$HOURLY_CMD"
  } | crontab -
  echo "Added hourly backup cronjob."
fi
