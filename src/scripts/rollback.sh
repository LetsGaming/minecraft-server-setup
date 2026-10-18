#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/server_control.sh"
source "$SCRIPT_DIR/common/archive_restore.sh"
source "$SCRIPT_DIR/common/utils.sh"

BACKUP_DIR="$BACKUPS_PATH/archives/update"
SKIP_CONFIRMATION=false
KEEP_OLD=false

print_help() {
  cat <<EOF
Usage: $0 [options]

Rolls back the server to the most recent pre-update backup.

Options:
  --y         Skip confirmation prompt
  --keep-old  Keep the replaced server files as <server>.pre-restore instead of
              deleting them (an earlier .pre-restore copy is replaced)
  --list      List available update backups and exit
  --help      Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --y) SKIP_CONFIRMATION=true; shift ;;
    --keep-old) KEEP_OLD=true; shift ;;
    --list)
      echo "Available update backups in $BACKUP_DIR:"
      if [[ -d "$BACKUP_DIR" ]]; then
        ls -lht "$BACKUP_DIR"/minecraft_backup_*.tar.{gz,zst} 2>/dev/null || echo "  (none)"
      else
        echo "  (backup directory does not exist)"
      fi
      exit 0
      ;;
    --help) print_help; exit 0 ;;
    *) echo "[ERROR] Unknown argument: $1"; print_help; exit 1 ;;
  esac
done

acquire_operation_lock rollback || exit 75

# Find the latest update backup
if [[ ! -d "$BACKUP_DIR" ]]; then
  echo "[ERROR] No update backups directory found: $BACKUP_DIR"
  echo "Run an update first to create a pre-update backup."
  exit 1
fi

LATEST_BACKUP=$(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.tar.zst' -o -name '*.tar.gz' \) -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)

if [[ -z "$LATEST_BACKUP" || ! -e "$LATEST_BACKUP" ]]; then
  echo "[ERROR] No update backups found in $BACKUP_DIR"
  exit 1
fi
# "Newest" is decided by whoever can write into the folder (S-004).
archive_is_trusted "$LATEST_BACKUP" || exit 1

BACKUP_DATE=$(basename "$LATEST_BACKUP" | sed 's/minecraft_backup_//' | sed 's/\.tar\..*//' | tr '_' ' ')
echo "[INFO] Most recent pre-update backup:"
echo "       File: $(basename "$LATEST_BACKUP")"
echo "       Date: $BACKUP_DATE"
echo "       Size: $(du -sh "$LATEST_BACKUP" | cut -f1)"
echo
echo "[WARN] This will:"
echo "       1. Stop the server"
echo "       2. Replace ALL server files in $SERVER_PATH (only after the archive checks out)"
echo "       3. Restart the server"

if [[ "$SKIP_CONFIRMATION" != true ]]; then
  read -rp "Proceed with rollback? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "[INFO] Rollback aborted."; exit 0; }
fi

# Check the archive before the server goes down: a bad archive must not cost
# the players any downtime, let alone the world.
echo "[INFO] Validating archive..."
validate_archive "$LATEST_BACKUP" || exit 1

restart_after_failure() {
  echo "[WARN] Rollback failed; the server files were not changed. Starting the server again..."
  systemctl_cmd start || echo "[WARN] Could not start the server. Start it manually."
}

# Stop the server
echo "[INFO] Stopping server..."
send_message "Server is rolling back to a previous version. Going down now." 2>/dev/null || true
sleep 2
if ! systemctl_cmd stop; then
  echo "[ERROR] Could not stop $INSTANCE_NAME.service; aborting. Server files were not changed." >&2
  exit 1
fi
for _ in $(seq 1 15); do
  server_is_running || break
  sleep 2
done
if ! require_server_stopped; then
  echo "[ERROR] Aborting. Server files were not changed." >&2
  exit 1
fi

notify_warning "rollback_start" "Server $INSTANCE_NAME is rolling back to backup from $BACKUP_DATE"

# Extract next to the server directory and swap, so a failure leaves the
# current files in place.
STAGING_DIR="${SERVER_PATH%/}.restore-staging.$$"
trap 'swap_recover; rm -rf -- "$STAGING_DIR" "${SERVER_PATH%/}/.mc-meta"; release_operation_lock' EXIT
trap 'exit 130' INT TERM

echo "[INFO] Restoring backup..."
if ! extract_archive "$LATEST_BACKUP" "$STAGING_DIR"; then
  restart_after_failure
  exit 1
fi
complete_staged_jars "$STAGING_DIR" "$SERVER_PATH"
# Extraction takes a while; confirm nothing started the server in the meantime.
if ! require_server_stopped; then
  echo "[ERROR] Aborting. Server files were not changed." >&2
  exit 1
fi
if ! swap_server_dir "$STAGING_DIR" "$SERVER_PATH" "$($KEEP_OLD && echo keep)"; then
  restart_after_failure
  exit 1
fi

# Restart the server
echo "[INFO] Starting server..."
systemctl_cmd start

echo "[INFO] Rollback complete. Server is starting with the restored files."
notify_success "rollback_complete" "Server $INSTANCE_NAME has been rolled back to backup from $BACKUP_DATE"

# Wait for it to come up
wait_for_server_ready 120 || echo "[WARN] Server may still be starting. Check logs."

wait_for_notifications
