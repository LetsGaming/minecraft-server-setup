#!/bin/bash
set -e

# ——— basics ———
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/server_control.sh"

# Track auto-save state so we can always re-enable on exit
_AUTO_SAVE_DISABLED=false

_backup_cleanup() {
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

# ——— args ———
ARCHIVE_MODE=false
ARCHIVE_TYPE=""
DRY_RUN=false
VERBOSE=false

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --archive)
      ARCHIVE_MODE=true
      if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
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
  send_message "Starting archive backup" || log WARN "Failed to send message to server"
  log INFO "Archive mode ON"
else
  send_message "Starting hourly backup" || log WARN "Failed to send message to server"
  log INFO "Hourly backup mode"
fi

$DRY_RUN && log INFO "Dry run mode enabled — no data will be written"
$VERBOSE && log INFO "Verbose mode enabled"

# ——— setup ———
BACKUP_BASE="$BACKUPS_PATH"
JAR_STORAGE="$BACKUP_BASE/jars"
DATE=$(date +'%Y-%m-%d_%H-%M-%S')
START_TIME=$(date +%s)

if $ARCHIVE_MODE; then
  BACKUP_DIR="$BACKUP_BASE/archives/$ARCHIVE_TYPE"
else
  BACKUP_DIR="$BACKUP_BASE/hourly"
fi

mkdir -p "$BACKUP_DIR" "$JAR_STORAGE"

log INFO "Backup directory: $BACKUP_DIR"

# ——— disable auto‑save ———
log INFO "Disabling auto-save..."
if ! $DRY_RUN; then
  disable_auto_save && _AUTO_SAVE_DISABLED=true || log WARN "disable_auto_save failed"
fi

# ——— force a save ———
log INFO "Saving world to disk..."
$DRY_RUN || save_and_wait || log WARN "save_and_wait failed"
sleep 2

# ——— build include list ———
cd "$SERVER_PATH"
INCLUDE_PATHS=()
for item in * .*; do
  [[ "$item" == "." || "$item" == ".." || "$item" == "backups" ]] && continue
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
mkdir -p "$TMP_DIR"

# ——— rsync to the temporary directory ———
log INFO "Syncing server data to temporary backup directory..."
$DRY_RUN && log INFO "Dry run mode — no rsync performed"
$DRY_RUN || rsync -a --inplace --numeric-ids "${EXCLUDES[@]}" "${INCLUDE_PATHS[@]}" "$TMP_DIR" || {
    log ERROR "rsync failed"
    exit 1
}

# ——— handle jar files separately in archive mode ———
if $ARCHIVE_MODE && ! $DRY_RUN; then
  log INFO "Handling .jar files for archive mode..."
  while IFS= read -r -d '' jar; do
    jarname="$(basename "$jar")"
    if [[ ! -e "$JAR_STORAGE/$jarname" ]]; then
      log INFO "Storing jar: $jarname"
      cp "$jar" "$JAR_STORAGE/$jarname"
    fi
    ln -sf "../../../jars/$jarname" "$TMP_DIR/$jarname"
  done < <(find "$SERVER_PATH" -type f -name '*.jar' -print0)
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
    ZSTD_OPTS+=(-$archive_level -o "$ARCHIVE_PATH")
  else
    ZSTD_OPTS+=(-$COMPRESSION_LEVEL -o "$ARCHIVE_PATH")
  fi

  tar "${TAR_OPTS[@]}" | zstd "${ZSTD_OPTS[@]}"
  FINAL_ARCHIVE="$ARCHIVE_PATH"
fi

# ——— validate archive ———
if ! $DRY_RUN; then
  log INFO "Validating archive..."
  if ! zstd -t "$FINAL_ARCHIVE" &>/dev/null; then
    send_message "Backup archive appears corrupted. Removing"
    log ERROR "Validation failed — corrupted archive removed"
    notify_error "backup_failed" "Backup archive was corrupted and removed."
    rm -f "$FINAL_ARCHIVE"
    rm -rf "$TMP_DIR"
    exit 1
  fi
fi

# ——— cleanup ———
$DRY_RUN || rm -rf "$TMP_DIR"

# ——— re‑enable auto‑save (explicit + trap handles edge cases) ———
if $_AUTO_SAVE_DISABLED && ! $DRY_RUN; then
  log INFO "Re-enabling auto-save..."
  enable_auto_save && _AUTO_SAVE_DISABLED=false || log WARN "enable_auto_save failed — run /save-on manually"
fi

# ——— success message ———
TIME_TAKEN=$(( $(date +%s) - START_TIME ))
TIME_TAKEN_STMP=$(printf '%02d:%02d:%02d' $((TIME_TAKEN/3600)) $((TIME_TAKEN%3600/60)) $((TIME_TAKEN%60)))

log SUCCESS "Backup complete: $FINAL_ARCHIVE"

BACKUP_SIZE=""
if [[ -n "$FINAL_ARCHIVE" && ! $DRY_RUN ]]; then
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
