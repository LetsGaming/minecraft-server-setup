#!/bin/bash
set -e

# ——— basics ———
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/server_control.sh"

# ——— args ———
ARCHIVE_MODE=false
for arg in "$@"; do
  case $arg in
    --archive) ARCHIVE_MODE=true ;;
    --help)
      cat <<EOF
Usage: $0 [--archive]

Options:
  --archive   Keep this backup in 'archives' so it’s not auto‑pruned
EOF
      exit 0
      ;;
    *)
      echo "$(date +'%F %T') [ERROR] Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

# ——— setup ———
BACKUP_DIR="$SERVER_PATH/backups"
DATE=$(date +'%Y-%m-%d_%H-%M-%S')
if $ARCHIVE_MODE; then
  BACKUP_DIR="$BACKUP_DIR/archives"
  echo "$(date +'%F %T') [INFO] Archive mode ON — target: $BACKUP_DIR"
else
  echo "$(date +'%F %T') [INFO] Normal backup mode — target: $BACKUP_DIR"
fi
mkdir -p "$BACKUP_DIR"
BACKUP_ARCHIVE="$BACKUP_DIR/minecraft_backup_$DATE.tar.gz"

# ——— disable auto‑save ———
echo "$(date +'%F %T') [INFO] Disabling auto-save..."
if ! disable_auto_save; then
  echo "$(date +'%F %T') [WARN] disable_auto_save failed (continuing anyway)"
fi

# ——— force a save ———
echo "$(date +'%F %T') [INFO] Saving world to disk..."
save_and_wait

# ——— build include list ———
cd "$SERVER_PATH"
INCLUDE_PATHS=()
for item in * .*; do
  # Skip . and .. and backups folder
  [[ "$item" == "." || "$item" == ".." || "$item" == "backups" ]] && continue
  INCLUDE_PATHS+=("$item")
done

echo "$(date +'%F %T') [INFO] Creating backup archive:"
echo "               ${BACKUP_ARCHIVE}"
echo "               Including: ${INCLUDE_PATHS[*]}"

# ——— run tar but don’t exit on non-zero ———
set +e
tar -czf "$BACKUP_ARCHIVE" \
    --ignore-failed-read \
    --warning=no-file-changed \
    "${INCLUDE_PATHS[@]}"
TAR_EXIT=$?
set -e

if [ $TAR_EXIT -ne 0 ]; then
  echo "$(date +'%F %T') [WARN] tar exited with code $TAR_EXIT (usually harmless)"
else
  echo "$(date +'%F %T') [INFO] Archive created successfully"
fi

# ——— re‑enable auto‑save ———
echo "$(date +'%F %T') [INFO] Re-enabling auto-save..."
if ! enable_auto_save; then
  echo "$(date +'%F %T') [WARN] enable_auto_save failed — run /save-on manually!"
fi

# ——— success message ———
echo "$(date +'%F %T') [SUCCESS] Backup complete: $BACKUP_ARCHIVE"
send_message "Backup completed at $(date +'%H:%M:%S')"

# ——— cleanup old backups ———
if ! $ARCHIVE_MODE && [ -n "${MAX_BACKUPS:-}" ]; then
  COUNT=$(ls -1 "$SERVER_PATH/backups"/minecraft_backup_*.tar.gz 2>/dev/null | wc -l)
  if [ "$COUNT" -gt "$MAX_BACKUPS" ]; then
    echo "$(date +'%F %T') [INFO] Cleaning up old backups (total: $COUNT, max: $MAX_BACKUPS)"
    ls -1t "$SERVER_PATH/backups"/minecraft_backup_*.tar.gz \
      | tail -n +"$((MAX_BACKUPS + 1))" \
      | xargs -r rm -v
  else
    echo "$(date +'%F %T') [INFO] No cleanup needed (total: $COUNT ≤ $MAX_BACKUPS)"
  fi
elif $ARCHIVE_MODE; then
  echo "$(date +'%F %T') [INFO] Archive mode — skipping cleanup"
fi
