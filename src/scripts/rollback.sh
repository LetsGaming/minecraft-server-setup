#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/server_control.sh"
source "$SCRIPT_DIR/common/archive_restore.sh"
source "$SCRIPT_DIR/common/utils.sh"
BK_COMPONENT=rollback
source "$SCRIPT_DIR/backup/lib/bk_common.sh"

BACKUP_DIR="$BACKUPS_PATH/archives/update"
SKIP_CONFIRMATION=false
DISCARD_OLD=false

print_help() {
  cat <<EOF
Usage: $0 [options]

Rolls back the server to the most recent pre-update backup.

Options:
  --y            Skip confirmation prompt
  --discard-old  Delete the replaced server files instead of keeping them as
                 <server>.pre-restore (the default; RESTORE_KEEP_OLD=false does the same)
  --keep-old     Accepted for compatibility; keeping the old files is the default
  --list         List available update backups and exit
  --help         Show this help message

The archive is unpacked and checked while the server is still running; it is
stopped only for the swap itself.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --y) SKIP_CONFIRMATION=true; shift ;;
    --keep-old) shift ;;
    --discard-old) DISCARD_OLD=true; shift ;;
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

bk_load_config >/dev/null 2>&1 || true
KEEP_MODE=keep
if $DISCARD_OLD || [[ "${RESTORE_KEEP_OLD:-true}" == false ]]; then
  KEEP_MODE=discard
fi

acquire_operation_lock rollback || exit 75

# Find the latest update backup
if [[ ! -d "$BACKUP_DIR" ]]; then
  echo "[ERROR] No update backups directory found: $BACKUP_DIR"
  echo "Run an update first to create a pre-update backup."
  exit 1
fi

LATEST_BACKUP="$(list_backup_files "$BACKUP_DIR" 1 | head -n1 | cut -d' ' -f2-)"

if [[ -z "$LATEST_BACKUP" || ! -e "$LATEST_BACKUP" ]]; then
  echo "[ERROR] No update backups found in $BACKUP_DIR"
  exit 1
fi
# "Newest" is decided by whoever can write into the folder (S-004); from here
# on every check and the extraction use the opened inode.
archive_open_trusted "$LATEST_BACKUP" || exit 1

BACKUP_DATE=$(basename "$LATEST_BACKUP" | sed 's/minecraft_backup_//' | sed 's/\.tar\..*//' | tr '_' ' ')
echo "[INFO] Most recent pre-update backup:"
echo "       File: $(basename "$LATEST_BACKUP")"
echo "       Date: $BACKUP_DATE"
echo "       Size: $(du -sh "$LATEST_BACKUP" | cut -f1)"
echo
echo "[WARN] This will:"
echo "       1. Unpack and check the archive next to the server directory"
echo "       2. Stop the server"
if [[ "$KEEP_MODE" == keep ]]; then
  echo "       3. Replace ALL server files in $SERVER_PATH (the current ones are kept at ${SERVER_PATH%/}.pre-restore)"
else
  echo "       3. Replace ALL server files in $SERVER_PATH (the current ones are deleted)"
fi
echo "       4. Restart the server"

if [[ "$SKIP_CONFIRMATION" != true ]]; then
  read -rp "Proceed with rollback? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "[INFO] Rollback aborted."; exit 0; }
fi

# Staging is prepared while the server still runs (D8): a bad archive costs
# the players no downtime, and the stop-swap-start window shrinks to seconds.
STAGING_DIR="${SERVER_PATH%/}.restore-staging.$$"
SWAPPED=false
_rollback_exit() {
  local rc=$?
  trap - EXIT
  swap_recover
  rm -rf -- "$STAGING_DIR"
  $SWAPPED && rm -rf -- "${SERVER_PATH%/}/.mc-meta"
  archive_close
  release_operation_lock
  exit "$rc"
}
trap _rollback_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "[INFO] Unpacking and checking the archive..."
extract_archive_fd "$AR_FD" "$AR_FORMAT" "$STAGING_DIR" || { echo "[ERROR] Aborting. The server was not stopped and its files were not changed." >&2; exit 1; }
scan_staged_tree "$STAGING_DIR" || { echo "[ERROR] Aborting. The server was not stopped and its files were not changed." >&2; exit 1; }
complete_staged_jars "$STAGING_DIR" "$SERVER_PATH"

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

echo "[INFO] Restoring backup..."
# Logs, crash reports and the event ledger are never in a backup (D5); taken
# from the live tree now that it is quiet.
# shellcheck disable=SC2086
carry_over_live "$SERVER_PATH" "$STAGING_DIR" ${RESTORE_CARRY_OVER:-}
if ! swap_server_dir "$STAGING_DIR" "$SERVER_PATH" "$KEEP_MODE"; then
  restart_after_failure
  exit 1
fi
SWAPPED=true

# Restart the server
echo "[INFO] Starting server..."
systemctl_cmd start

echo "[INFO] Rollback complete. Server is starting with the restored files."
notify_success "rollback_complete" "Server $INSTANCE_NAME has been rolled back to backup from $BACKUP_DATE"

# Wait for it to come up
wait_for_server_ready 120 || echo "[WARN] Server may still be starting. Check logs."

wait_for_notifications
