#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/server_control.sh"

BACKUP_DIR="$BACKUPS_PATH/archives/update"
SKIP_CONFIRMATION=false

print_help() {
  cat <<EOF
Usage: $0 [options]

Rolls back the server to the most recent pre-update backup.

Options:
  --y       Skip confirmation prompt
  --list    List available update backups and exit
  --help    Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --y) SKIP_CONFIRMATION=true; shift ;;
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

BACKUP_DATE=$(basename "$LATEST_BACKUP" | sed 's/minecraft_backup_//' | sed 's/\.tar\..*//' | tr '_' ' ')
echo "[INFO] Most recent pre-update backup:"
echo "       File: $(basename "$LATEST_BACKUP")"
echo "       Date: $BACKUP_DATE"
echo "       Size: $(du -sh "$LATEST_BACKUP" | cut -f1)"
echo
echo "[WARN] This will:"
echo "       1. Stop the server"
echo "       2. Replace ALL server files in $SERVER_PATH"
echo "       3. Restart the server"

if [[ "$SKIP_CONFIRMATION" != true ]]; then
  read -rp "Proceed with rollback? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "[INFO] Rollback aborted."; exit 0; }
fi

# Stop the server
echo "[INFO] Stopping server..."
send_message "Server is rolling back to a previous version. Going down now." 2>/dev/null || true
sleep 2
sudo -n systemctl stop "$INSTANCE_NAME".service 2>/dev/null || true
sleep 3

notify_warning "rollback_start" "Server $INSTANCE_NAME is rolling back to backup from $BACKUP_DATE"

# Clear server directory
echo "[INFO] Clearing server files..."
rm -rf "$SERVER_PATH"/*

# Restore backup
echo "[INFO] Restoring backup..."
if [[ "$LATEST_BACKUP" == *.tar.gz ]]; then
  tar -xzf "$LATEST_BACKUP" -C "$SERVER_PATH"
elif [[ "$LATEST_BACKUP" == *.tar.zst ]]; then
  zstd -d "$LATEST_BACKUP" -c | tar -xf - -C "$SERVER_PATH"
fi

# Restart the server
echo "[INFO] Starting server..."
systemctl_cmd start

echo "[INFO] Rollback complete. Server is starting with the restored files."
notify_success "rollback_complete" "Server $INSTANCE_NAME has been rolled back to backup from $BACKUP_DATE"

# Wait for it to come up
wait_for_server_ready 120 || echo "[WARN] Server may still be starting. Check logs."
