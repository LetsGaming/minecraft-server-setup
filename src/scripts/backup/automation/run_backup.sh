#!/bin/bash
set -e

LOGS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../logs"
mkdir -p "$LOGS_DIR"

AUTOMATION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$AUTOMATION_SCRIPT_DIR/../backup.sh"

source "$AUTOMATION_SCRIPT_DIR/../../common/load_variables.sh"
BACKUP_BASE="$BACKUPS_PATH"

# Per-instance, non-world-shared state dir. The flags were previously in a
# single shared /tmp/backup_flags keyed only by date, which (a) let any local
# user pre-create a flag to suppress backups and (b) meant the first instance
# to run each day claimed the daily/weekly/monthly slot, so every OTHER
# instance silently fell through to "hourly only". Keying the dir under this
# instance's BACKUPS_PATH fixes both: it is owned by the instance user and is
# already unique per instance.
STATE_DIR="$BACKUP_BASE/.backup_flags"

mkdir -p "$STATE_DIR"

# Clean up stale flag files older than 7 days to prevent accumulation
find "$STATE_DIR" -type f -mtime +7 -delete 2>/dev/null || true

# ——— update snapshot helper ———
# update-server.js creates a pre-update archive in archives/update/ before every
# mod or server update. These are the target for rollback.sh. On weekly and
# monthly archive runs we write a symlink alongside the archive so PABS and
# manual inspection can find the latest update snapshot without grepping the
# full archives/ tree. The symlink is best-effort — a missing update archive
# (e.g. the server has never been updated) is not an error.
_capture_update_snapshot() {
  local update_dir="$BACKUP_BASE/archives/update"
  local latest_link="$BACKUP_BASE/archives/latest-update-snapshot.tar.zst"

  [[ -d "$update_dir" ]] || return 0

  local latest
  latest=$(find "$update_dir" -maxdepth 1 -type f \( -name '*.tar.zst' -o -name '*.tar.gz' \) \
    -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2-)

  if [[ -n "$latest" ]]; then
    ln -sf "$latest" "$latest_link" 2>/dev/null && \
      echo "[$(date +'%F %T')] Update snapshot symlink → $(basename "$latest")" || true
  fi
}

# backup.sh takes a per-instance lock and exits 75 when another run (cron or a
# wrapper-triggered one) holds it. That is a skip, not a failure: the flag is
# left unset so the next run retries the slot.
run_backup_script() {
  local rc=0
  bash "$BACKUP_SCRIPT" "$@" || rc=$?
  if [[ $rc -eq 75 ]]; then
    echo "[$(date +'%F %T')] Another backup is running; skipping this run."
    exit 0
  fi
  return $rc
}

HOUR=$(date +%H)
DAY_OF_WEEK=$(date +%u)  # 1 (Mo) – 7 (So)
DAY_OF_MONTH=$(date +%d)
TODAY=$(date +%F)         # YYYY-MM-DD

DAILY_FLAG="$STATE_DIR/daily_$TODAY"
WEEKLY_FLAG="$STATE_DIR/weekly_$TODAY"
MONTHLY_FLAG="$STATE_DIR/monthly_$TODAY"

# Which backup this run makes. Exactly one per run, highest priority first.
KIND="hourly"
FLAG=""
if [[ "$DO_GENERATION_BACKUPS" == "true" ]]; then
  if [ "$DAY_OF_WEEK" -eq 7 ] && [ "$DAY_OF_MONTH" -le 7 ] && [ ! -f "$MONTHLY_FLAG" ]; then
    KIND="monthly"; FLAG="$MONTHLY_FLAG"     # first Sunday of the month
  elif [ "$DAY_OF_WEEK" -eq 7 ] && [ ! -f "$WEEKLY_FLAG" ]; then
    KIND="weekly"; FLAG="$WEEKLY_FLAG"       # every Sunday
  elif [ "$HOUR" -eq 0 ] && [ ! -f "$DAILY_FLAG" ]; then
    KIND="daily"; FLAG="$DAILY_FLAG"         # every day at 00:00
  fi
fi

echo "[$(date +'%F %T')] Starting $KIND backup..."
rc=0
if [[ "$KIND" == "hourly" ]]; then
  run_backup_script || rc=$?
else
  run_backup_script --archive "$KIND" || rc=$?
fi

if [[ $rc -eq 0 && -n "$FLAG" ]]; then
  [[ "$KIND" == "monthly" || "$KIND" == "weekly" ]] && _capture_update_snapshot
  touch "$FLAG"
fi

# Retention runs after every backup, failed ones included (S-013). It used to
# be skipped whenever the backup failed (set -e) and after every archive run,
# so once the disk filled up every backup failed and nothing ever freed space.
bash "$AUTOMATION_SCRIPT_DIR/cleanup_backups.sh" || echo "[$(date +'%F %T')] [WARN] Backup cleanup failed."

exit "$rc"
