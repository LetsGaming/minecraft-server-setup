#!/bin/bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/../../common/load_variables.sh"

log() {
  echo "[$(date +'%F %T')] $*"
}

log "Starting backup cleanup..."

BACKUP_BASE="$SERVER_PATH/backups"

delete_old_backups() {
  local type="$1"
  local max_var="$2"

  if [[ "$type" == "hourly" ]]; then
    local dir="$SERVER_PATH/backups/hourly"
  else
    local dir="$SERVER_PATH/backups/archives/$type"
  fi

  local max_value="${!max_var}"

  if [[ -z "$max_value" || "$max_value" -lt 1 ]]; then
    log "ERROR: $max_var is not set or invalid (value: '$max_value')" >&2
    exit 1
  fi

  log "Checking $type backups in: $dir"
  BACKUPS=($(ls -1t "$dir"/minecraft_backup_*.tar.{gz,zst} 2>/dev/null || true))
  BACKUP_COUNT="${#BACKUPS[@]}"

  log "Found $BACKUP_COUNT $type backup(s); keeping the newest $max_value."

  if [[ "$BACKUP_COUNT" -gt "$max_value" ]]; then
    BACKUPS_TO_DELETE=("${BACKUPS[@]:$max_value}")
    if [[ "${#BACKUPS_TO_DELETE[@]}" -gt 0 ]]; then
      log "Deleting ${#BACKUPS_TO_DELETE[@]} old $type backup(s):"
      for file in "${BACKUPS_TO_DELETE[@]}"; do
        log "Deleting: $file"
        rm -v "$file"
      done
    fi
  else
    log "No $type backups need deletion."
  fi
}

enforce_storage_limit() {
  if [[ -z "$MAX_STORAGE_GB" || "$MAX_STORAGE_GB" -lt 1 ]]; then
    log "MAX_STORAGE_GB not set or invalid — skipping storage limit check."
    return
  fi

  local max_bytes=$((MAX_STORAGE_GB * 1024 * 1024 * 1024))
  local current_bytes
  current_bytes=$(du -sb "$BACKUP_BASE" | cut -f1)

  log "Current backup storage usage: $((current_bytes / 1024 / 1024)) MB (limit: ${MAX_STORAGE_GB} GB)"

  if (( current_bytes <= max_bytes )); then
    log "Storage usage is within limit."
    return
  fi

  # Finde alle Backups, sortiert nach Zeit (älteste zuerst)
  mapfile -t all_backups < <(find "$BACKUP_BASE" -type f -name 'minecraft_backup_*.tar.*' -printf '%T@ %p\n' | sort -n | awk '{print $2}')

  for file in "${all_backups[@]}"; do
    log "Deleting (to reduce size): $file"
    rm -v "$file"
    current_bytes=$(du -sb "$BACKUP_BASE" | cut -f1)
    if (( current_bytes <= max_bytes )); then
      log "Storage usage is now within limit."
      break
    fi
  done
}

# Generationsprinzip
delete_old_backups "hourly"  "MAX_HOURLY_BACKUPS"
delete_old_backups "daily"   "MAX_DAILY_BACKUPS"
delete_old_backups "weekly"  "MAX_WEEKLY_BACKUPS"
delete_old_backups "monthly" "MAX_MONTHLY_BACKUPS"

# Speicherlimit erzwingen
enforce_storage_limit

log "Backup cleanup complete."
