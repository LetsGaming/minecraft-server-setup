#!/bin/bash
set -e

# Installs the hourly backup job, idempotently: a systemd timer where systemd
# is running (timer_lib.sh), otherwise a cron entry through `crontab -` (read
# from stdin, no temp file).

: "${MAIN_DIR:?MAIN_DIR not set}"
: "${TARGET_DIR_NAME:?TARGET_DIR_NAME not set}"
: "${INSTANCE_NAME:?INSTANCE_NAME not set}"

source "$(dirname "${BASH_SOURCE[0]}")/cron_lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/timer_lib.sh"

SCRIPTS_DIR="$MAIN_DIR/$TARGET_DIR_NAME/scripts/$INSTANCE_NAME"
RUN_BACKUP="$SCRIPTS_DIR/backup/automation/run_backup.sh"
LOGS_DIR="$SCRIPTS_DIR/backup/logs"

if [ ! -f "$RUN_BACKUP" ]; then
  echo "Backup wrapper script not found: $RUN_BACKUP" >&2
  exit 1
fi

mkdir -p "$LOGS_DIR"

# Off :00 deliberately: the bot's hourly leaderboard snapshot and several
# of its other hourly timers land on the hour boundary, and stacking this
# backup's save-off/save-all RCON stall plus a CPU-saturating zstd -T0 on
# top of that traffic is one of the causes behind the wrapper's periodic
# unavailability. A mid-hour minute keeps it isolated from that boundary.
QUOTED_RUN_BACKUP="$(cron_quote "$RUN_BACKUP")"

if systemd_usable; then
  timer_install backup "Hourly backup of $INSTANCE_NAME" "$RUN_BACKUP" "*-*-* *:20:00" "$LOGS_DIR/backup.log" false "$SCRIPTS_DIR"
  # A cron line from an earlier install would run the backup a second time.
  if crontab -l 2> /dev/null | grep -qF -- "$QUOTED_RUN_BACKUP"; then
    echo "Note: the crontab still has an hourly backup line from an earlier install; run migrate.sh to move it to the timer." >&2
  fi
  exit 0
fi

HOURLY_CMD="20 * * * * bash $QUOTED_RUN_BACKUP >> $(cron_quote "$LOGS_DIR/backup.log") 2>&1"

read_crontab

if printf '%s\n' "$EXISTING_CRONTAB" | grep -qF -- "$QUOTED_RUN_BACKUP"; then
  echo "Hourly backup cronjob already exists. Skipping."
else
  {
    [ -n "$EXISTING_CRONTAB" ] && printf '%s\n' "$EXISTING_CRONTAB"
    printf '%s\n' "$HOURLY_CMD"
  } | crontab -
  echo "Added hourly backup cronjob."
fi
