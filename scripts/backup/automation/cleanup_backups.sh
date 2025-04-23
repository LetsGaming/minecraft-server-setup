#!/bin/bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/../../common/load_variables.sh"

log() {
  echo "[$(date +'%F %T')] $*"
}

log "Starting backup cleanup..."
BACKUP_BASE="$SERVER_PATH/backups"

delete_old_archives() {
  local type="$1"
  local max_var="$2"
  local dir="$BACKUP_BASE/archives/$type"
  local max_value="${!max_var}"

  [[ -n "$max_value" && "$max_value" -gt 0 ]] || {
    log "ERROR: $max_var is not set or invalid (value: '$max_value')" >&2
    exit 1
  }

  log "Checking $type backups in: $dir"
  mapfile -t backups < <(ls -1t "$dir"/minecraft_backup_*.tar.{gz,zst} 2>/dev/null || true)
  if (( ${#backups[@]} > max_value )); then
    for file in "${backups[@]:$max_value}"; do
      log "Deleting: $file"
      rm -v "$file"
    done
  else
    log "No $type backups to delete."
  fi
}

delete_old_hourly_backups() {
  local dir="$BACKUP_BASE/hourly"
  local max="${MAX_HOURLY_BACKUPS:-3}"

  log "Checking hourly backups in: $dir"
  mapfile -t snapshots < <(ls -1t "$dir"/minecraft_backup_*.tar.{gz,zst} 2>/dev/null || true)
  if (( ${#snapshots[@]} > max )); then
    for file in "${snapshots[@]:$max}"; do
      log "Deleting old hourly backup: $file"
      rm -v "$file"
    done
  else
    log "No hourly backups to delete."
  fi
}

enforce_storage_limit() {
  [[ -z "$MAX_STORAGE_GB" || "$MAX_STORAGE_GB" -lt 1 ]] && {
    log "MAX_STORAGE_GB not set or invalid — skipping storage check."
    return
  }

  local max_bytes=$((MAX_STORAGE_GB * 1024 * 1024 * 1024))
  local current_bytes
  current_bytes=$(du -sb "$BACKUP_BASE" | cut -f1)

  log "Current backup usage: $((current_bytes / 1024 / 1024)) MB (limit: ${MAX_STORAGE_GB} GB)"
  log "Used space: $((current_bytes * 100 / (MAX_STORAGE_GB * 1024 * 1024 * 1024)))%"

  (( current_bytes <= max_bytes )) && return

  mapfile -t all_backups < <(find "$BACKUP_BASE" -type f -name 'minecraft_backup_*.tar.*' -printf '%T@ %p\n' | sort -n | cut -d' ' -f2-)
  for file in "${all_backups[@]}"; do
    log "Deleting (to free space): $file"
    rm -v "$file"
    current_bytes=$(du -sb "$BACKUP_BASE" | cut -f1)
    (( current_bytes <= max_bytes )) && break
  done
}

# Apply policies
delete_old_hourly_backups
delete_old_archives "daily"   "MAX_DAILY_BACKUPS"
delete_old_archives "weekly"  "MAX_WEEKLY_BACKUPS"
delete_old_archives "monthly" "MAX_MONTHLY_BACKUPS"
enforce_storage_limit

log "Backup cleanup complete."
