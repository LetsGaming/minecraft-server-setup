#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/server_control.sh"
source "$SCRIPT_DIR/../common/archive_restore.sh"
source "$SCRIPT_DIR/../common/utils.sh"
source "$SCRIPT_DIR/lib/bk_common.sh"
source "$SCRIPT_DIR/lib/bk_state.sh"
source "$SCRIPT_DIR/lib/bk_stage.sh"
source "$SCRIPT_DIR/lib/bk_archive.sh"
source "$SCRIPT_DIR/lib/bk_space.sh"

# ── args ──
ARCHIVE_MODE=false
ARCHIVE_TYPE=""
DRY_RUN=false
VERBOSE=false

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --archive)
      ARCHIVE_MODE=true
      if [[ -n "${2:-}" && ! "$2" =~ ^-- ]]; then
        ARCHIVE_TYPE="$2"
        shift
      fi
      shift
      ;;
    --dry-run) DRY_RUN=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --help)
      cat <<EOF
Usage: $0 [--archive [TYPE]] [--dry-run] [--verbose]

Options:
  --archive [TYPE]   Store this backup in 'archives/<type>' instead of hourly
  --dry-run          Show what the run would do without making changes
  --verbose          Verbose rsync output (the files copied and transfer stats)

Environment:
  BK_EXTRA_TIERS     Further archive tiers (space separated) that receive the
                     same archive by hardlink, used by run_backup.sh when
                     several tiers are due on the same day.

Exit codes: 0 done, 1 failed, 65 archive holds no world, 73 not enough free
space, 75 another backup or operation holds the lock (skipped).
EOF
      exit 0
      ;;
    *) bk_log ERROR "Unknown argument: $1"; exit 1 ;;
  esac
done

if $ARCHIVE_MODE; then
  ARCHIVE_TYPE="${ARCHIVE_TYPE:-general}"
  # The type becomes a directory name under archives/, so it must not be able
  # to carry a path separator or "..".
  if [[ ! "$ARCHIVE_TYPE" =~ ^[a-z0-9_-]+$ ]]; then
    bk_log ERROR "Invalid archive type '$ARCHIVE_TYPE' (allowed: lowercase letters, digits, '_' and '-')"
    exit 1
  fi
  BK_COMPONENT="backup:$ARCHIVE_TYPE"
else
  BK_COMPONENT="backup:hourly"
fi

EXTRA_TIERS=()
for tier in ${BK_EXTRA_TIERS:-}; do
  if [[ ! "$tier" =~ ^[a-z0-9_-]+$ ]]; then
    bk_log ERROR "Invalid extra tier '$tier' in BK_EXTRA_TIERS"
    exit 1
  fi
  [[ "$tier" == "$ARCHIVE_TYPE" ]] || EXTRA_TIERS+=("$tier")
done

bk_load_config || exit 1
bk_probe_priority
BK_VERBOSE="$VERBOSE"

# ── state for the EXIT handler ──
_AUTO_SAVE_DISABLED=false
PART_FILE=""
NOTIFIED=false
START_TIME=$(date +%s)
BK_TIERS="${ARCHIVE_TYPE:-hourly} ${EXTRA_TIERS[*]}"
BK_SAVE_OFF_SECONDS=0
BK_STAGING=""
BK_LEVEL=0
BK_THREADS="$(bk_zstd_threads)"

# Order matters: the server must get save-on before anything slow, the
# partial archive must never be seen under a final name, and exactly one
# failure notification goes out for whatever ended the run.
_bk_exit() {
  local rc=$?
  trap - EXIT ERR
  set +e
  if $_AUTO_SAVE_DISABLED; then
    bk_log INFO "Re-enabling auto-save (cleanup trap)..."
    enable_auto_save 2>/dev/null || bk_log WARN "Failed to re-enable auto-save; run /save-on manually"
    _AUTO_SAVE_DISABLED=false
  fi
  if [[ -n "$PART_FILE" ]]; then
    rm -f -- "$PART_FILE"
    PART_FILE=""
  fi
  bk_stage_discard_run
  if (( rc != 0 && rc != BK_EX_SKIP )) && ! $NOTIFIED && ! $DRY_RUN; then
    local reason="${BK_FAIL_REASON:-command failed${BK_ERR_CMD:+: $BK_ERR_CMD}}"
    case "$rc" in
      130|143|129) reason="interrupted (signal, exit $rc)" ;;
    esac
    bk_log ERROR "Backup failed at stage '$BK_STAGE': $reason"
    send_message "Backup failed: $reason" 2>/dev/null || true
    notify_error "backup_failed" "Backup failed at stage '$BK_STAGE': $reason. No backup was made." || true
    NOTIFIED=true
    bk_state_write_last "$rc" "${ARCHIVE_TYPE:-hourly}" "" 0 "$(( $(date +%s) - START_TIME ))" "$BK_STAGE" 2>/dev/null || true
  fi
  wait_for_notifications
  release_operation_lock
  exit "$rc"
}
_bk_on_err() { BK_ERR_CMD="$BASH_COMMAND"; }
BK_ERR_CMD=""
set -o errtrace
trap _bk_on_err ERR
trap _bk_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ── setup ──
BACKUP_BASE="$BACKUPS_PATH"
DATE=$(date +'%Y-%m-%d_%H-%M-%S')
if $ARCHIVE_MODE; then
  BACKUP_DIR="$BACKUP_BASE/archives/$ARCHIVE_TYPE"
  LEVEL="$BACKUP_ARCHIVE_LEVEL"
  HOURLY=0
else
  BACKUP_DIR="$BACKUP_BASE/hourly"
  LEVEL="$BACKUP_HOURLY_LEVEL"
  HOURLY=1
fi
BK_LEVEL="$LEVEL"

# Archives hold variables.txt (API key, RCON password, webhook URL) and
# api-server-config.json, so nothing this run creates is readable by other
# users. Set BACKUP_UMASK to widen it when another account must read backups.
umask "${BACKUP_UMASK:-077}"

if $DRY_RUN; then
  bk_log INFO "Dry run: nothing is written"
  bk_log INFO "Would make a${ARCHIVE_MODE:+n archive ($ARCHIVE_TYPE)} backup${EXTRA_TIERS:+ linked into ${EXTRA_TIERS[*]}} in $BACKUP_DIR"
  bk_log INFO "zstd level $LEVEL, threads $BK_THREADS, staging mode ${BACKUP_STAGING_MODE}, priority wrapper: ${BK_NICE[*]:-none}"
  bk_log INFO "(dry-run) No backup written."
  exit 0
fi

mkdir -p "$BACKUP_DIR"
bk_set_stage preflight

# ── no backup while a restore, rollback or upgrade is rewriting the server ──
# The upgrade job runs this script itself and passes (MC_OPERATION_LOCK_HELD).
acquire_operation_lock backup || { bk_log WARN "Another operation is running for $INSTANCE_NAME; skipping."; exit "$BK_EX_SKIP"; }

# ── one backup per instance at a time ──
# Cron and wrapper-triggered runs share the staging tree, so they must not
# overlap. Exit 75 (EX_TEMPFAIL) tells callers the run was skipped.
if command -v flock &>/dev/null; then
  exec 9>"$BACKUP_BASE/.backup.lock"
  if ! flock -n 9; then
    bk_log WARN "Another backup is already running for $INSTANCE_NAME; skipping."
    exit "$BK_EX_SKIP"
  fi
else
  bk_log WARN "flock not found; only the operation lock serializes backups"
fi

bk_log INFO "Backup directory: $BACKUP_DIR"
bk_archive_remove_stale_parts
bk_stage_remove_legacy_tmp
# The sidecars vouch for archives, so only this user may write them.
bk_private_dir "$(bk_state_meta_dir)" || bk_die 1 "The sidecar folder $(bk_state_meta_dir) is not private to this user"

STAGING_MODE="$(bk_stage_select)" || bk_die 1 "The staging folder is not private to this user"
BK_STAGING="$STAGING_MODE"
bk_log INFO "Staging mode: $STAGING_MODE; zstd level $LEVEL, threads $BK_THREADS; priority wrapper: ${BK_NICE[*]:-none}"

bk_space_preflight "$STAGING_MODE" "$SCRIPT_DIR/automation/cleanup_backups.sh" || exit $?

if $ARCHIVE_MODE; then
  send_message "Starting archive backup ($ARCHIVE_TYPE)" || bk_log WARN "Failed to send message to server"
  bk_log INFO "Archive mode, type: $ARCHIVE_TYPE${EXTRA_TIERS:+ (also ${EXTRA_TIERS[*]})}"
else
  send_message "Starting hourly backup" || bk_log WARN "Failed to send message to server"
  bk_log INFO "Hourly backup mode"
fi

# ── quiesce ──
bk_set_stage quiesce
abort_backup() { bk_die 1 "$1. Aborting, so that no half-written world is archived."; }

# A stopped server has nothing to flush. One that is up, or whose state cannot
# be told, must confirm both commands, or the copy below could catch region
# files mid-write.
SERVER_UP=false
server_state=0
server_is_running || server_state=$?
[[ "$server_state" -ne 1 ]] && SERVER_UP=true

SAVE_OFF_START=0
if $SERVER_UP; then
  bk_log INFO "Disabling auto-save..."
  SAVE_OFF_START="$(bk_now_ms)"
  # Marked before the call (S-011): save-off can take effect even when its
  # reply is lost, and then only the trap's save-on turns saving back on.
  _AUTO_SAVE_DISABLED=true
  disable_auto_save || abort_backup "Could not turn auto-save off"
  bk_log INFO "Saving world to disk..."
  save_and_wait || abort_backup "The server did not confirm the save"
else
  bk_log INFO "The server is not running; copying its files as they are."
fi

# ── stage ──
bk_set_stage stage
STAGE_START="$(bk_now_ms)"
bk_stage_refresh "$STAGING_MODE" "$SERVER_PATH" "$(( HOURLY == 1 ? 0 : 1 ))" || bk_die 1 "Staging the server files failed"
STAGE_ROOT="$BK_STAGE_ROOT"
STAGE_MS=$(( $(bk_now_ms) - STAGE_START ))

# The snapshot is on disk; compressing and verifying it can take minutes, and
# the server must not run without auto-save for that long.
if $_AUTO_SAVE_DISABLED; then
  bk_log INFO "Re-enabling auto-save..."
  enable_auto_save && _AUTO_SAVE_DISABLED=false || bk_log WARN "enable_auto_save failed, run /save-on manually"
  BK_SAVE_OFF_SECONDS="$(bk_ms_to_s $(( $(bk_now_ms) - SAVE_OFF_START )))"
  bk_log INFO "Staging ($STAGING_MODE) took $(bk_ms_to_s "$STAGE_MS") s; auto-save was off for $BK_SAVE_OFF_SECONDS s"
else
  bk_log INFO "Staging ($STAGING_MODE) took $(bk_ms_to_s "$STAGE_MS") s"
  # A server that started during the copy may have rewritten files under it.
  state_now=0
  server_is_running || state_now=$?
  if [[ "$state_now" -eq 0 ]]; then
    bk_die 1 "The server started while its files were being copied; discarding this run"
  fi
fi

[[ "$STAGING_MODE" == mirror ]] && { bk_stage_check_mirror "$STAGE_ROOT" || bk_die 1 "Staging mirror incomplete"; }

META_ROOT=""
if $ARCHIVE_MODE; then
  bk_log INFO "Staging instance metadata..."
  META_ROOT="$(bk_stage_dir)/meta"
  bk_stage_metadata "$META_ROOT" "$(cd "$SCRIPT_DIR/.." && pwd)" || bk_die 1 "Staging the instance metadata failed"
fi

# ── compress ──
bk_set_stage compress
bk_log INFO "Compressing backup (level $LEVEL, T$BK_THREADS)..."
PART_FILE="$(bk_archive_part_path "$BACKUP_DIR" "$DATE")"
bk_archive_create "$STAGE_ROOT" "$META_ROOT" "$BACKUP_DIR" "$DATE" "$LEVEL" "$HOURLY" >/dev/null || bk_die 1 "Compression failed"

# ── verify ──
bk_set_stage verify
bk_log INFO "Verifying archive..."
verify_rc=0
bk_archive_verify "$PART_FILE" || verify_rc=$?
if (( verify_rc != 0 )); then
  bk_die "$verify_rc" "Archive verification failed; the partial archive is removed"
fi

# ── publish ──
bk_set_stage publish
FINAL_ARCHIVE="$BACKUP_DIR/minecraft_backup_$DATE.tar.zst"
bk_archive_publish "$PART_FILE" "$FINAL_ARCHIVE" || bk_die 1 "Could not publish the archive"
PART_FILE=""
if (( ${#EXTRA_TIERS[@]} > 0 )); then
  bk_archive_link_tiers "$FINAL_ARCHIVE" "${EXTRA_TIERS[@]}" || bk_die 1 "Could not link the archive into every due tier"
fi
bk_stage_discard_run

# ── done ──
bk_set_stage "done"
TIME_TAKEN=$(( $(date +%s) - START_TIME ))
TIME_TAKEN_STMP=$(printf '%02d:%02d:%02d' $((TIME_TAKEN/3600)) $((TIME_TAKEN%3600/60)) $((TIME_TAKEN%60)))
BACKUP_BYTES="$(bk_file_size "$FINAL_ARCHIVE")"
BACKUP_SIZE="$(bk_human_bytes "$BACKUP_BYTES")"

bk_log SUCCESS "Backup complete: $FINAL_ARCHIVE"
bk_log SUCCESS "Published ${FINAL_ARCHIVE##*/} ($BACKUP_SIZE, level $LEVEL, T$BK_THREADS, ${BK_VERIFY_ENTRIES:-?} entries)"
bk_state_write_last 0 "${ARCHIVE_TYPE:-hourly}" "${FINAL_ARCHIVE#"$BACKUP_BASE"/}" "$BACKUP_BYTES" "$TIME_TAKEN" "done" || true

if $ARCHIVE_MODE; then
  send_message "Archive backup ($ARCHIVE_TYPE) completed | In $TIME_TAKEN_STMP" || bk_log WARN "Failed to notify server"
  notify_success "backup_complete" "Archive backup ($ARCHIVE_TYPE) completed in $TIME_TAKEN_STMP. Size: $BACKUP_SIZE"
else
  send_message "Hourly backup completed | In $TIME_TAKEN_STMP" || bk_log WARN "Failed to notify server"
  notify_success "backup_complete" "Hourly backup completed in $TIME_TAKEN_STMP. Size: $BACKUP_SIZE"
fi
NOTIFIED=true

bk_log INFO "Backup took: $TIME_TAKEN_STMP"
bk_log INFO "Backups storage usage: $(bk_nice du -sh --exclude=.stage --exclude=.meta "$BACKUP_BASE" 2>/dev/null | cut -f1)"
wait_for_notifications
