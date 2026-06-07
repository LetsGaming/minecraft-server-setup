#!/bin/bash
set -e

LOGS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../logs"
mkdir -p "$LOGS_DIR"

AUTOMATION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$AUTOMATION_SCRIPT_DIR/../backup.sh"

source "$AUTOMATION_SCRIPT_DIR/../../common/load_variables.sh"
BACKUP_BASE="$BACKUPS_PATH"
STATE_DIR="/tmp/backup_flags"

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
    _capture_update_snapshot
    touch "$MONTHLY_FLAG"
    exit 0
  fi

  # Vater: Jeden Sonntag (Priority 2)
  if [ "$DAY_OF_WEEK" -eq 7 ] && [ ! -f "$WEEKLY_FLAG" ]; then
    echo "[$(date +'%F %T')] Starting weekly backup..."
    bash "$BACKUP_SCRIPT" --archive weekly
    _capture_update_snapshot
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