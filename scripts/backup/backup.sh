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
    if ! send_message "Starting archive backup"; then
        log WARN "Failed to send message to server (continuing anyway)"
    fi
    log INFO "Archive mode ON"
else
    if ! send_message "Starting hourly backup"; then
        log WARN "Failed to send message to server (continuing anyway)"
    fi
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
if ! save_and_wait; then
  log WARN "save_and_wait failed (continuing anyway)"
fi
sleep 2  # Let world flush to disk

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
)

# ——— handle .jar files based on mode ———
if $ARCHIVE_MODE; then
  # Include all .jar files for archive mode
  log INFO "Including all .jar files in archive mode"
  for jar in $(find "$SERVER_PATH" -type f -name '*.jar'); do
    INCLUDE_PATHS+=("$jar")  # Include all .jar files in archive mode
  done
else
  # Exclude all .jar files in hourly mode
  log INFO "Excluding .jar files in hourly mode"
  EXCLUDES+=('--exclude=*.jar')
fi

# ——— run rsync and zstd ———
log INFO "Starting backup with rsync and zstd compression..."

# Rsync the files, excluding patterns as needed
rsync -a --exclude="${EXCLUDES[@]}" "${INCLUDE_PATHS[@]}" "$BACKUP_DIR/temp_backup"

# Compress the backup with zstd
log INFO "Compressing backup using zstd..."
zstd -z "$BACKUP_DIR/temp_backup" -o "$FINAL_ARCHIVE" -19  # Use high compression level

# Cleanup temporary backup files
rm -rf "$BACKUP_DIR/temp_backup"

# ——— re‑enable auto‑save ———
log INFO "Re-enabling auto-save..."
if ! enable_auto_save; then
  log WARN "enable_auto_save failed — run /save-on manually!"
fi

# ——— success message ———
log SUCCESS "Backup complete: $FINAL_ARCHIVE"
if $ARCHIVE_MODE; then
    if ! send_message "Archive backup ($ARCHIVE_TYPE) completed"; then
        log WARN "Failed to send message to server (continuing anyway)"
    fi
else
    if ! send_message "Hourly backup completed"; then
        log WARN "Failed to send message to server (continuing anyway)"
    fi
fi

log INFO "Note: Cleanup handled externally by cleanup_archives.sh"
