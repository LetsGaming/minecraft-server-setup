#!/bin/bash
# The cron entry point: decides which tiers this run owes, runs backup.sh under
# a watchdog, retries a failed archive slot with an hourly backup, keeps the
# per-day flags and counters, rotates its own log and runs the cleanup.
set -e

AUTOMATION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="$AUTOMATION_SCRIPT_DIR/../logs"
mkdir -p "$LOGS_DIR"
BACKUP_SCRIPT="$AUTOMATION_SCRIPT_DIR/../backup.sh"
CLEANUP_SCRIPT="$AUTOMATION_SCRIPT_DIR/cleanup_backups.sh"

# cron starts with a minimal PATH; node (RCON), zstd and rsync may live outside it.
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

source "$AUTOMATION_SCRIPT_DIR/../../common/load_variables.sh"
source "$AUTOMATION_SCRIPT_DIR/../../common/webhook.sh"
source "$AUTOMATION_SCRIPT_DIR/../../common/server_control.sh"
BK_COMPONENT=run_backup
source "$AUTOMATION_SCRIPT_DIR/../lib/bk_common.sh"
source "$AUTOMATION_SCRIPT_DIR/../lib/bk_state.sh"
source "$AUTOMATION_SCRIPT_DIR/../lib/bk_schedule.sh"

bk_load_config || exit 1
BACKUP_BASE="$BACKUPS_PATH"

# Per-instance, non-world-shared state dir: owned by the instance user and
# unique per instance, so no other local user can pre-create a flag and no
# other instance can claim this one's daily slot.
STATE_DIR="$(bk_state_flags_dir)"
mkdir -p "$STATE_DIR"

# Clean up stale flag files older than 7 days to prevent accumulation
find "$STATE_DIR" -type f -mtime +7 -delete 2>/dev/null || true

# ── log rotation ──
# Copy-truncate: cron appends with >> (O_APPEND), so truncating in place is
# safe and the open descriptor keeps writing at the new end.
rotate_log() {
  local log="$LOGS_DIR/backup.log" max_bytes=$(( BACKUP_LOG_MAX_MB * 1024 * 1024 )) size i
  [[ -f "$log" ]] || return 0
  size="$(stat -c %s -- "$log" 2>/dev/null || echo 0)"
  [[ "$size" =~ ^[0-9]+$ ]] && (( size > max_bytes )) || return 0
  for i in 2 1; do
    [[ -f "$log.$i" ]] && mv -f -- "$log.$i" "$log.$((i + 1))"
  done
  cp -- "$log" "$log.1" && : > "$log"
  bk_log INFO "Rotated backup.log ($(bk_human_bytes "$size"))"
}
rotate_log

# ── update snapshot helper ──
# update-server.js creates a pre-update archive in archives/update/ before every
# mod or server update. These are the target for rollback.sh. On weekly and
# monthly archive runs we write a symlink alongside the archive so PABS and
# manual inspection can find the latest update snapshot without grepping the
# full archives/ tree. The symlink is best-effort.
_capture_update_snapshot() {
  local update_dir="$BACKUP_BASE/archives/update"
  local latest_link="$BACKUP_BASE/archives/latest-update-snapshot.tar.zst"

  [[ -d "$update_dir" ]] || return 0

  local latest
  latest=$(find "$update_dir" -maxdepth 1 -type f \( -name 'minecraft_backup_*.tar.zst' -o -name 'minecraft_backup_*.tar.gz' \) \
    -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -n1 | cut -d' ' -f2-)

  if [[ -n "$latest" ]]; then
    ln -sf "$latest" "$latest_link" 2>/dev/null && \
      bk_log INFO "Update snapshot symlink -> $(basename "$latest")" || true
  fi
}

# ── watchdog ──
# GNU timeout sends TERM; backup.sh's TERM trap runs its EXIT handler (save-on
# first). A run that ignores TERM is killed after another two minutes.
run_backup_script() {
  local rc=0
  if command -v timeout &>/dev/null; then
    timeout --signal=TERM --kill-after=120 "${BACKUP_TIMEOUT_MINUTES}m" bash "$BACKUP_SCRIPT" "$@" || rc=$?
  else
    bash "$BACKUP_SCRIPT" "$@" || rc=$?
  fi
  return $rc
}

# After a kill the backup's own trap may not have run: turn saving back on
# ourselves (idempotent; "already on" is harmless) and say what happened.
recover_from_timeout() {
  local kind="$1"
  bk_log ERROR "The $kind backup exceeded ${BACKUP_TIMEOUT_MINUTES} minutes and was stopped."
  local state=0
  server_is_running || state=$?
  if [[ "$state" -ne 1 ]]; then
    enable_auto_save 2>/dev/null && bk_log INFO "Sent save-on after the timeout" || bk_log WARN "Could not send save-on after the timeout; run /save-on manually"
  fi
  notify_error "backup_failed" "The $kind backup timed out after ${BACKUP_TIMEOUT_MINUTES} minutes and was stopped. Auto-save was turned back on." || true
}

# ── which tiers are due ──
DAY_OF_WEEK=$(date +%u)  # 1 (Mon) to 7 (Sun)
DAY_OF_MONTH=$(date +%d)
TODAY=$(date +%F)         # YYYY-MM-DD

mapfile -t DUE < <(bk_due_tiers "$TODAY" "$DAY_OF_WEEK" "$DAY_OF_MONTH" "$STATE_DIR" "$DO_GENERATION_BACKUPS" "$BACKUP_ARCHIVE_MAX_ATTEMPTS")
KIND="hourly"
EXTRA=()
if (( ${#DUE[@]} > 0 )); then
  KIND="${DUE[0]}"
  EXTRA=("${DUE[@]:1}")
fi

if [[ "$KIND" == hourly ]]; then
  bk_log INFO "Starting hourly backup..."
else
  bk_log INFO "Starting $KIND backup${EXTRA:+ (also due: ${EXTRA[*]})}..."
fi

rc=0
if [[ "$KIND" == "hourly" ]]; then
  run_backup_script || rc=$?
else
  BK_EXTRA_TIERS="${EXTRA[*]}" run_backup_script --archive "$KIND" || rc=$?
fi

case "$rc" in
  0)
    bk_state_skip_streak reset >/dev/null
    if [[ "$KIND" != hourly ]]; then
      for tier in "$KIND" "${EXTRA[@]}"; do
        [[ -n "$tier" ]] || continue
        touch "$STATE_DIR/${tier}_$TODAY"
        [[ "$tier" == monthly || "$tier" == weekly ]] && _capture_update_snapshot
      done
    fi
    ;;
  75)
    # A skip, not a failure: the flag stays unset so the next run retries the
    # slot. A long streak of skips means something holds the lock for good.
    streak="$(bk_state_skip_streak inc)"
    bk_log WARN "This backup was SKIPPED: another backup or operation holds the lock. The next run tries again. (${streak} in a row)"
    if (( streak == BACKUP_SKIP_ALERT_AFTER )); then
      notify_warning "backup_skipped" "$streak backups in a row were skipped because another backup or operation holds the lock. Check for a stuck run." || true
    fi
    rc=0
    ;;
  124|137)
    recover_from_timeout "$KIND"
    rc=124
    ;&
  *)
    if [[ "$KIND" != hourly ]]; then
      for tier in "$KIND" "${EXTRA[@]}"; do
        [[ -n "$tier" ]] || continue
        attempts="$(bk_state_attempts "$tier" "$TODAY" inc)"
        if (( attempts >= BACKUP_ARCHIVE_MAX_ATTEMPTS )); then
          bk_log ERROR "The $tier backup failed $attempts times today; giving up on it until tomorrow."
          notify_error "backup_failed" "The $tier backup failed $attempts times today (exit $rc); giving up for today. Hourly backups continue." || true
        else
          bk_log WARN "The $tier backup failed (exit $rc, attempt $attempts of $BACKUP_ARCHIVE_MAX_ATTEMPTS); it is retried next hour."
        fi
      done
      # Coverage must not have a gap because the archive slot failed.
      bk_log INFO "Making an hourly backup instead..."
      hourly_rc=0
      run_backup_script || hourly_rc=$?
      case "$hourly_rc" in
        0) bk_log INFO "The hourly fallback backup succeeded." ;;
        75) bk_log WARN "The hourly fallback backup was skipped (lock held)." ;;
        124|137) recover_from_timeout hourly ;;
        *) bk_log ERROR "The hourly fallback backup failed too (exit $hourly_rc)." ;;
      esac
    fi
    ;;
esac

# Retention runs after every backup, failed ones included (S-013): once the
# disk fills up every backup fails and nothing else would ever free space.
bash "$CLEANUP_SCRIPT" || bk_log WARN "Backup cleanup failed."

wait_for_notifications
exit "$rc"
