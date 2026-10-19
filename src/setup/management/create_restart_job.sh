#!/bin/bash
set -e

# Replaces create_restart_job.js: installs the scheduled-restart cron entry if
# restarts are enabled. The schedule fields (RESTART_ENABLED,
# RESTART_INTERVAL_HOURS) are read from the variables.txt that
# set_common_variables.js generated and copy_scripts.sh deployed, so no JSON
# parsing is needed here. Uses `crontab -` (stdin), idempotently.

: "${MAIN_DIR:?MAIN_DIR not set}"
: "${TARGET_DIR_NAME:?TARGET_DIR_NAME not set}"
: "${INSTANCE_NAME:?INSTANCE_NAME not set}"

source "$(dirname "${BASH_SOURCE[0]}")/cron_lib.sh"

SCRIPTS_DIR="$MAIN_DIR/$TARGET_DIR_NAME/scripts/$INSTANCE_NAME"
VARS_FILE="$SCRIPTS_DIR/common/variables.txt"

if [ ! -f "$VARS_FILE" ]; then
  echo "Variables file not found ($VARS_FILE); cannot determine restart schedule." >&2
  echo "Skipping scheduled-restart cronjob." >&2
  exit 0
fi

# Defaults mirror set_common_variables.js
RESTART_ENABLED="false"
RESTART_INTERVAL_HOURS="12"
# shellcheck disable=SC1090
source "$VARS_FILE"

if [ "${RESTART_ENABLED:-false}" != "true" ]; then
  echo "Scheduled restarts not enabled. Skipping."
  exit 0
fi

RESTART_SCRIPT="$SCRIPTS_DIR/backup/automation/scheduled_restart.sh"
LOGS_DIR="$SCRIPTS_DIR/backup/logs"
mkdir -p "$LOGS_DIR"

INTERVAL_HOURS="${RESTART_INTERVAL_HOURS:-12}"
case "$INTERVAL_HOURS" in
  '' | *[!0-9]*)
    echo "RESTART_INTERVAL_HOURS must be a whole number of hours, got '$INTERVAL_HOURS'." >&2
    exit 1
    ;;
esac
INTERVAL_HOURS=$((10#$INTERVAL_HOURS))

# cron's */N restarts the count at midnight, so only a divisor of 24 is an even
# interval; a multiple of 24 becomes every N/24 days at midnight.
if [ "$INTERVAL_HOURS" -ge 1 ] && [ "$INTERVAL_HOURS" -le 24 ] && [ $((24 % INTERVAL_HOURS)) -eq 0 ]; then
  SCHEDULE="0 */$INTERVAL_HOURS * * *"
elif [ "$INTERVAL_HOURS" -gt 24 ] && [ $((INTERVAL_HOURS % 24)) -eq 0 ]; then
  SCHEDULE="0 0 */$((INTERVAL_HOURS / 24)) * *"
else
  echo "RESTART_INTERVAL_HOURS must divide 24 (1, 2, 3, 4, 6, 8, 12, 24) or be a multiple of 24, got $INTERVAL_HOURS." >&2
  exit 1
fi

QUOTED_RESTART_SCRIPT="$(cron_quote "$RESTART_SCRIPT")"
CRON_CMD="$SCHEDULE bash $QUOTED_RESTART_SCRIPT >> $(cron_quote "$LOGS_DIR/restart.log") 2>&1"

read_crontab

if printf '%s\n' "$EXISTING_CRONTAB" | grep -qF -- "$QUOTED_RESTART_SCRIPT"; then
  echo "Scheduled restart cronjob already exists. Skipping."
else
  {
    [ -n "$EXISTING_CRONTAB" ] && printf '%s\n' "$EXISTING_CRONTAB"
    printf '%s\n' "$CRON_CMD"
  } | crontab -
  echo "Added scheduled restart cronjob (every ${INTERVAL_HOURS}h)."
fi
