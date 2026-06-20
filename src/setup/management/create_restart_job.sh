#!/bin/bash
set -e

# Replaces create_restart_job.js — installs the scheduled-restart cron entry if
# restarts are enabled. The schedule fields (RESTART_ENABLED,
# RESTART_INTERVAL_HOURS) are read from the variables.txt that
# set_common_variables.js generated and copy_scripts.sh deployed, so no JSON
# parsing is needed here. Uses `crontab -` (stdin), idempotently.

: "${MAIN_DIR:?MAIN_DIR not set}"
: "${TARGET_DIR_NAME:?TARGET_DIR_NAME not set}"
: "${INSTANCE_NAME:?INSTANCE_NAME not set}"

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
CRON_CMD="0 */$INTERVAL_HOURS * * * bash $RESTART_SCRIPT >> $LOGS_DIR/restart.log 2>&1"

existing="$(crontab -l 2>/dev/null || true)"

if printf '%s\n' "$existing" | grep -qF "$RESTART_SCRIPT"; then
  echo "Scheduled restart cronjob already exists. Skipping."
else
  {
    [ -n "$existing" ] && printf '%s\n' "$existing"
    printf '%s\n' "$CRON_CMD"
  } | crontab -
  echo "Added scheduled restart cronjob (every ${INTERVAL_HOURS}h)."
fi
