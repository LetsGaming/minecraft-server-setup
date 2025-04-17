#!/bin/bash
set -e

# ——— basics ———
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/server_control.sh"

# ——— helpers ———
log() {
    local level="$1"
    shift
    echo "$(date +'%F %T') [$level] $*"
}

# ——— args ———
ARCHIVE_MODE=false
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --archive) ARCHIVE_MODE=true; shift ;;
    --help)
      cat <<EOF
Usage: $0 [--archive]

Options:
  --archive   Store this backup in 'archives/<type>' instead of hourly
EOF
      exit 0
      ;;
    *) 
      log ERROR "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# ——— backup message ———
if $ARCHIVE_MODE; then
    send_message "Starting archive backup"
    log INFO "Archive mode ON"
else
    send_message "Starting hourly backup"
    log INFO "Hourly backup mode"
fi

# ——— setup ———
BACKUP_BASE="$SERVER_PATH/backups"
DATE=$(date +'%Y-%m-%d_%H-%M-%S')

if $ARCHIVE_MODE; then
  ARCHIVE_TYPE="${ARCHIVE_TYPE:-general}"  # daily / weekly / monthly
  BACKUP_DIR="$BACKUP_BASE/archives/$ARCHIVE_TYPE"
  log INFO "Archive target: $BACKUP_DIR"
else
  BACKUP_DIR="$BACKUP_BASE/hourly"
  log INFO "Hourly target: $BACKUP_DIR"
fi

mkdir -p "$BACKUP_DIR"
TMP_ARCHIVE="$BACKUP_DIR/.minecraft_backup_${DATE}.tar.gz.tmp"
FINAL_ARCHIVE="$BACKUP_DIR/minecraft_backup_${DATE}.tar.gz"

# ——— disable auto‑save ———
log INFO "Disabling auto-save..."
if ! disable_auto_save; then
  log WARN "disable_auto_save failed (continuing anyway)"
fi

# ——— force a save ———
log INFO "Saving world to disk..."
save_and_wait
sleep 2  # Let world flush to disk

# ——— build include list ———
cd "$SERVER_PATH"
INCLUDE_PATHS=()
for item in * .*; do
  [[ "$item" == "." || "$item" == ".." || "$item" == "backups" ]] && continue
  INCLUDE_PATHS+=("$item")
done

log INFO "Creating backup archive: $FINAL_ARCHIVE"
log INFO "Including: ${INCLUDE_PATHS[*]}"

# ——— run tar ———
set +e
tar -czf "$TMP_ARCHIVE" \
    --ignore-failed-read \
    --warning=no-file-changed \
    "${INCLUDE_PATHS[@]}"
TAR_EXIT=$?
set -e

# ——— validate and move ———
if [ $TAR_EXIT -ne 0 ]; then
  log WARN "tar exited with code $TAR_EXIT (usually harmless)"
  rm -f "$TMP_ARCHIVE"
else
  if ! tar -tzf "$TMP_ARCHIVE" &>/dev/null; then
    log ERROR "Backup archive appears corrupted. Removing: $TMP_ARCHIVE"
    rm -f "$TMP_ARCHIVE"
    exit 1
  fi
  mv "$TMP_ARCHIVE" "$FINAL_ARCHIVE"
  log INFO "Archive created successfully"
fi

# ——— re‑enable auto‑save ———
log INFO "Re-enabling auto-save..."
if ! enable_auto_save; then
  log WARN "enable_auto_save failed — run /save-on manually!"
fi

# ——— success message ———
log SUCCESS "Backup complete: $FINAL_ARCHIVE"
if $ARCHIVE_MODE; then
    send_message "Archive backup ($ARCHIVE_TYPE) completed at $(date +'%H:%M:%S')"
else
    send_message "Hourly backup completed"
fi

log INFO "Note: Cleanup handled externally by cleanup_archives.sh"
