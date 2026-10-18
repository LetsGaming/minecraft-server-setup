#!/bin/bash
set -e

# ——— basics ———
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/server_control.sh"
source "$SCRIPT_DIR/../common/archive_restore.sh"
source "$SCRIPT_DIR/../common/utils.sh"

# Track auto-save state so we can always re-enable on exit
_AUTO_SAVE_DISABLED=false
# Set while a backup is being staged or compressed; removed by the EXIT trap
# so no failure path leaves a temp tree or a half-written archive behind.
TMP_DIR=""
PARTIAL_ARCHIVE=""

_backup_cleanup() {
  release_operation_lock
  if [[ -n "$PARTIAL_ARCHIVE" ]]; then
    rm -f -- "$PARTIAL_ARCHIVE"
    PARTIAL_ARCHIVE=""
  fi
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
  if $_AUTO_SAVE_DISABLED; then
    log INFO "Re-enabling auto-save (cleanup trap)..."
    enable_auto_save 2>/dev/null || log WARN "Failed to re-enable auto-save — run /save-on manually"
    _AUTO_SAVE_DISABLED=false
  fi
}
trap _backup_cleanup EXIT

# ——— helpers ———
log() {
    local level="$1"
    shift
    echo "$(date +'%F %T') [$level] $*"
}

# Runs the given command de-prioritized (CPU niceness and, where supported,
# I/O class) so the hourly backup does not compete on equal footing with the
# game server or the API wrapper for the same CPU/disk. Falls back to plain
# nice, then to running the command as-is, on a system missing either tool
# rather than failing the backup over it.
nice_run() {
  if command -v ionice &>/dev/null; then
    ionice -c2 -n7 nice -n 10 "$@"
  elif command -v nice &>/dev/null; then
    nice -n 10 "$@"
  else
    "$@"
  fi
}

# ——— args ———
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
  --dry-run          Simulate the backup process without making changes
  --verbose          Enable verbose output for rsync, tar, and zstd
EOF
      exit 0
      ;;
    *) log ERROR "Unknown argument: $1"; exit 1 ;;
  esac
done

# ——— backup message ———
if $ARCHIVE_MODE; then
  ARCHIVE_TYPE="${ARCHIVE_TYPE:-general}"
  # The type becomes a directory name under archives/, so it must not be able
  # to carry a path separator or "..".
  if [[ ! "$ARCHIVE_TYPE" =~ ^[a-z0-9_-]+$ ]]; then
    log ERROR "Invalid archive type '$ARCHIVE_TYPE' (allowed: lowercase letters, digits, '_' and '-')"
    exit 1
  fi
  send_message "Starting archive backup ($ARCHIVE_TYPE)" || log WARN "Failed to send message to server"
  log INFO "Archive mode ON — type: $ARCHIVE_TYPE"
else
  send_message "Starting hourly backup" || log WARN "Failed to send message to server"
  log INFO "Hourly backup mode"
fi

$DRY_RUN && log INFO "Dry run mode enabled — no data will be written"
$VERBOSE && log INFO "Verbose mode enabled"

# ——— setup ———
BACKUP_BASE="$BACKUPS_PATH"
DATE=$(date +'%Y-%m-%d_%H-%M-%S')
START_TIME=$(date +%s)

if $ARCHIVE_MODE; then
  BACKUP_DIR="$BACKUP_BASE/archives/$ARCHIVE_TYPE"
else
  BACKUP_DIR="$BACKUP_BASE/hourly"
fi

# Archives hold variables.txt (API key, RCON password, webhook URL) and
# api-server-config.json, so nothing this run creates is readable by other
# users. Set BACKUP_UMASK to widen it when another account must read backups.
umask "${BACKUP_UMASK:-077}"

mkdir -p "$BACKUP_DIR"

# ——— no backup while a restore, rollback or upgrade is rewriting the server ———
# The upgrade job runs this script itself and passes (MC_OPERATION_LOCK_HELD).
if ! $DRY_RUN; then
  acquire_operation_lock backup || { log WARN "Another operation is running for $INSTANCE_NAME; skipping."; exit 75; }
fi

# ——— one backup per instance at a time ———
# Cron and wrapper-triggered runs share the staging directory below, so they
# must not overlap. Exit 75 (EX_TEMPFAIL) tells callers the run was skipped.
if ! $DRY_RUN; then
  if command -v flock &>/dev/null; then
    exec 9>"$BACKUP_BASE/.backup.lock"
    if ! flock -n 9; then
      log WARN "Another backup is already running for $INSTANCE_NAME; skipping."
      exit 75
    fi
  else
    log WARN "flock not found; concurrent backups are not prevented"
  fi
fi

log INFO "Backup directory: $BACKUP_DIR"

# ——— disable auto‑save ———
abort_backup() {
  log ERROR "$1. Aborting, so that no half-written world is archived."
  send_message "Backup failed: $1" || true
  notify_error "backup_failed" "$1. No backup was made." || true
  wait_for_notifications
  exit 1
}

# A stopped server has nothing to flush. One that is up, or whose state cannot
# be told, must confirm both commands, or the copy below could catch region
# files mid-write.
SERVER_UP=false
if ! $DRY_RUN; then
  server_state=0
  server_is_running || server_state=$?
  [[ "$server_state" -ne 1 ]] && SERVER_UP=true
fi

if $SERVER_UP; then
  log INFO "Disabling auto-save..."
  # Marked before the call (S-011): save-off can take effect even when its
  # reply is lost, and then only the trap's save-on turns saving back on.
  _AUTO_SAVE_DISABLED=true
  disable_auto_save || abort_backup "Could not turn auto-save off"

  # Force a save.
  log INFO "Saving world to disk..."
  save_and_wait || abort_backup "The server did not confirm the save"
  sleep 2
elif ! $DRY_RUN; then
  log INFO "The server is not running; copying its files as they are."
fi

# ——— build include list ———
cd "$SERVER_PATH"
INCLUDE_PATHS=()
for item in * .*; do
  [[ "$item" == "." || "$item" == ".." || "$item" == "backups" || "$item" == ".mc-meta" ]] && continue
  INCLUDE_PATHS+=("$item")
done

# ——— define exclude rules ———
EXCLUDES=(
  --exclude='logs/*'
  --exclude='*.log'
  --exclude='*.tmp'
  --exclude='crash-reports/*'
  --exclude='*.gz'
  --exclude='ledger.sqlite'
)

if ! $ARCHIVE_MODE; then
  log INFO "Excluding .jar files in hourly mode"
  EXCLUDES+=('--exclude=*.jar')
fi

# ——— create temporary folder ———
TMP_DIR="$BACKUP_DIR/tmp_backup"
if ! $DRY_RUN; then
  # Anything here is residue of a run that was killed; the lock above makes
  # it safe to discard, and rsync into a stale tree would resurrect deleted files.
  rm -rf -- "$TMP_DIR"
  mkdir -p "$TMP_DIR"
else
  TMP_DIR=""
fi

# ——— rsync to the temporary directory ———
log INFO "Syncing server data to temporary backup directory..."
$DRY_RUN && log INFO "Dry run mode — no rsync performed"
$DRY_RUN || nice_run rsync -a --inplace --numeric-ids "${EXCLUDES[@]}" "${INCLUDE_PATHS[@]}" "$TMP_DIR" || {
    log ERROR "rsync failed"
    exit 1
}

# The snapshot is on disk; compressing and validating it can take minutes, and
# the server must not run without auto-save for that long.
if $_AUTO_SAVE_DISABLED && ! $DRY_RUN; then
  log INFO "Re-enabling auto-save..."
  enable_auto_save && _AUTO_SAVE_DISABLED=false || log WARN "enable_auto_save failed, run /save-on manually"
fi

# Jars in archive mode.
# An archive keeps the real jars rsync copied above (S-002). It used to swap
# them for links into a shared jars/ folder: the links only resolved inside the
# backups tree, so every restored archive had a dangling server.jar, and the
# server could not start after a restore, an upgrade rollback or rollback.sh.
# restore.sh repairs those links in archives made before this change.

# ——— stage instance metadata (archive mode only) ———
# Everything outside SERVER_PATH that is needed to fully rebuild the management
# infrastructure from scratch: all management scripts, systemd service files,
# and the api-server config. node_modules are excluded and reinstalled on restore.
if $ARCHIVE_MODE && ! $DRY_RUN; then
  log INFO "Staging instance metadata..."

  INSTANCE_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"   # <root>/scripts/<instance>
  # The install root holds scripts/, instances/ and services/. It is not the
  # server dir's parent: in the instances/ layout that is <root>/instances.
  BASE_DIR="$(dirname "$(dirname "$INSTANCE_SCRIPTS_DIR")")"
  TARGET_DIR_NAME="$(basename "$BASE_DIR")"       # e.g. minecraft-server
  META_DIR="$TMP_DIR/.mc-meta"

  mkdir -p "$META_DIR/scripts" "$META_DIR/systemd"

  # 1. Entire scripts/INSTANCE_NAME tree — skip node_modules and logs
  rsync -a \
    --exclude='node_modules/' \
    --exclude='logs/' \
    --exclude='*.log' \
    "$INSTANCE_SCRIPTS_DIR/" "$META_DIR/scripts/"
  log INFO "  ✓ scripts/ ($(du -sh "$META_DIR/scripts" | cut -f1))"

  # 2. Systemd service files
  # ${TARGET_DIR_NAME}-manager.service is deliberately absent: the bundled web
  # interface was retired, so a new backup should not carry a unit that restore
  # would then reinstall. Restore skips it in old backups for the same reason.
  for svc_file in \
    "/etc/systemd/system/${INSTANCE_NAME}.service" \
    "/etc/systemd/system/${TARGET_DIR_NAME}-api-server.service"; do
    if [[ -f "$svc_file" ]]; then
      cp "$svc_file" "$META_DIR/systemd/$(basename "$svc_file")"
      log INFO "  ✓ systemd/$(basename "$svc_file")"
    fi
  done

  # 3. api-server-config.json (at <root>/api-server/ before the services/ layout)
  API_CONFIG="$BASE_DIR/services/api-server/api-server-config.json"
  [[ -f "$API_CONFIG" ]] || API_CONFIG="$BASE_DIR/api-server/api-server-config.json"
  if [[ -f "$API_CONFIG" ]]; then
    cp "$API_CONFIG" "$META_DIR/api-server-config.json"
    log INFO "  ✓ api-server-config.json"
  else
    log WARN "  api-server-config.json not found — skipping"
  fi
fi

# ——— compress with tar + zstd ———
FINAL_ARCHIVE=""
if ! $DRY_RUN; then
  log INFO "Compressing backup..."

  TAR_OPTS=(-cf - -C "$TMP_DIR" .)
  ZSTD_OPTS=(-T0)

  ARCHIVE_PATH="$BACKUP_DIR/minecraft_backup_$DATE.tar.zst"

  if $ARCHIVE_MODE; then
    # Archives use the higher of configured level and 15 for long-term storage
    archive_level=$(( COMPRESSION_LEVEL > 15 ? COMPRESSION_LEVEL : 15 ))
    ZSTD_OPTS+=("-$archive_level" -o "$ARCHIVE_PATH")
  else
    ZSTD_OPTS+=("-$COMPRESSION_LEVEL" -o "$ARCHIVE_PATH")
  fi

  PARTIAL_ARCHIVE="$ARCHIVE_PATH"
  set +e
  set -o pipefail
  nice_run tar "${TAR_OPTS[@]}" | nice_run zstd "${ZSTD_OPTS[@]}"
  PIPE_STATUS=("${PIPESTATUS[@]}")
  set +o pipefail
  set -e
  if [[ "${PIPE_STATUS[0]}" -ne 0 || "${PIPE_STATUS[1]}" -ne 0 ]]; then
    log ERROR "Compression failed (tar exit ${PIPE_STATUS[0]}, zstd exit ${PIPE_STATUS[1]}); removing partial archive"
    send_message "Backup failed while compressing" || true
    notify_error "backup_failed" "Backup compression failed (tar ${PIPE_STATUS[0]}, zstd ${PIPE_STATUS[1]})." || true
    exit 1
  fi
  FINAL_ARCHIVE="$ARCHIVE_PATH"
fi

# ——— validate archive ———
# zstd -t proves the compressed stream is intact; listing it with tar proves
# the tar inside is complete (a tar that died midway still yields a valid zstd
# stream).
if ! $DRY_RUN; then
  log INFO "Validating archive..."
  if ! nice_run zstd -t "$FINAL_ARCHIVE" &>/dev/null      || ! ( set -o pipefail; nice_run zstd -d -c "$FINAL_ARCHIVE" | nice_run tar -tf - >/dev/null ) 2>/dev/null; then
    log ERROR "Validation failed, corrupted archive removed"
    send_message "Backup archive appears corrupted. Removing" || true
    notify_error "backup_failed" "Backup archive was corrupted and removed." || true
    exit 1
  fi
  PARTIAL_ARCHIVE=""
fi

# ——— cleanup ———
$DRY_RUN || { rm -rf -- "$TMP_DIR"; TMP_DIR=""; }

# ——— success message ———
TIME_TAKEN=$(( $(date +%s) - START_TIME ))
TIME_TAKEN_STMP=$(printf '%02d:%02d:%02d' $((TIME_TAKEN/3600)) $((TIME_TAKEN%3600/60)) $((TIME_TAKEN%60)))

log SUCCESS "Backup complete: $FINAL_ARCHIVE"

BACKUP_SIZE=""
if [[ -n "$FINAL_ARCHIVE" ]] && ! $DRY_RUN; then
  BACKUP_SIZE=$(du -sh "$FINAL_ARCHIVE" | cut -f1)
  log INFO "Backup size: $BACKUP_SIZE"
fi

if $ARCHIVE_MODE; then
  send_message "Archive backup ($ARCHIVE_TYPE) completed | In $TIME_TAKEN_STMP" || log WARN "Failed to notify server"
  notify_success "backup_complete" "Archive backup ($ARCHIVE_TYPE) completed in $TIME_TAKEN_STMP. Size: $BACKUP_SIZE"
else
  send_message "Hourly backup completed | In $TIME_TAKEN_STMP" || log WARN "Failed to notify server"
  notify_success "backup_complete" "Hourly backup completed in $TIME_TAKEN_STMP. Size: $BACKUP_SIZE"
fi

log INFO "Backup took: $TIME_TAKEN_STMP"

if ! $DRY_RUN; then
  log INFO "Backups storage usage: $(du -sh "$BACKUP_BASE" | cut -f1)"
else
  log INFO "(dry-run) No backup written."
fi

wait_for_notifications
