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
  --archive   Keep this backup in 'archives' so it’s not auto‑pruned
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
    send_message "Starting backup"
    log INFO "Normal backup mode"
fi

# ——— setup ———
BACKUP_DIR="$SERVER_PATH/backups"
DATE=$(date +'%Y-%m-%d_%H-%M-%S')
if $ARCHIVE_MODE; then
  BACKUP_DIR="$BACKUP_DIR/archives"
  log INFO "Archive mode ON — target: $BACKUP_DIR"
else
  log INFO "Normal backup mode — target: $BACKUP_DIR"
fi
mkdir -p "$BACKUP_DIR"
BACKUP_ARCHIVE="$BACKUP_DIR/minecraft_backup_$DATE.tar.gz"

# ——— disable auto‑save ———
log INFO "Disabling auto-save..."
if ! disable_auto_save; then
  log WARN "disable_auto_save failed (continuing anyway)"
fi

# ——— force a save ———
log INFO "Saving world to disk..."
save_and_wait

# ——— build include list ———
cd "$SERVER_PATH"
INCLUDE_PATHS=()
for item in * .*; do
  # Skip . and .. and backups folder
  [[ "$item" == "." || "$item" == ".." || "$item" == "backups" ]] && continue
  INCLUDE_PATHS+=("$item")
done

log INFO "Creating backup archive: $BACKUP_ARCHIVE"
log INFO "Including: ${INCLUDE_PATHS[*]}"

# ——— run tar but don’t exit on non-zero ———
set +e
tar -czf "$BACKUP_ARCHIVE" \
    --ignore-failed-read \
    --warning=no-file-changed \
    "${INCLUDE_PATHS[@]}"
TAR_EXIT=$?
set -e

if [ $TAR_EXIT -ne 0 ]; then
  log WARN "tar exited with code $TAR_EXIT (usually harmless)"
else
  log INFO "Archive created successfully"
fi

# ——— re‑enable auto‑save ———
log INFO "Re-enabling auto-save..."
if ! enable_auto_save; then
  log WARN "enable_auto_save failed — run /save-on manually!"
fi

# ——— success message ———
log SUCCESS "Backup complete: $BACKUP_ARCHIVE"
if $ARCHIVE_MODE; then
    send_message "Archive backup completed at $(date +'%H:%M:%S')"
else
    send_message "Backup completed"
fi

# ——— cleanup old backups ———
if ! $ARCHIVE_MODE && [ -n "${MAX_BACKUPS:-}" ]; then
  COUNT=$(ls -1 "$SERVER_PATH/backups"/minecraft_backup_*.tar.gz 2>/dev/null | wc -l)
  if [ "$COUNT" -gt "$MAX_BACKUPS" ]; then
    log INFO "Cleaning up old backups (total: $COUNT, max: $MAX_BACKUPS)"
    ls -1t "$SERVER_PATH/backups"/minecraft_backup_*.tar.gz \
      | tail -n +"$((MAX_BACKUPS + 1))" \
      | xargs -r rm -v
  else
    log INFO "No cleanup needed (total: $COUNT ≤ $MAX_BACKUPS)"
  fi
elif $ARCHIVE_MODE; then
  log INFO "Archive mode — skipping cleanup"
fi
log INFO "Backup script completed"
