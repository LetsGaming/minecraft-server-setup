#!/bin/bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/../../common/load_variables.sh"

log() {
  echo "[$(date +'%F %T')] $*"
}

# See backup.sh's identical helper: de-prioritizes I/O-heavy commands
# (du here) so cleanup does not compete with the game server or the API
# wrapper for CPU/disk.
nice_run() {
  if command -v ionice &>/dev/null; then
    ionice -c2 -n7 nice -n 10 "$@"
  elif command -v nice &>/dev/null; then
    nice -n 10 "$@"
  else
    "$@"
  fi
}

log "Starting backup cleanup..."
BACKUP_BASE="$BACKUPS_PATH"
MAX_UPDATE_BACKUPS="${MAX_UPDATE_BACKUPS:-5}"

# Eviction order when the storage limit is exceeded: the cheapest-to-lose tier
# first, oldest archive first within a tier. Monthly archives are the long-term
# history and go last, so they are never evicted while any hourly, daily,
# weekly or update archive remains.
STORAGE_EVICTION_DIRS=(
  "$BACKUP_BASE/hourly"
  "$BACKUP_BASE/archives/daily"
  "$BACKUP_BASE/archives/weekly"
  "$BACKUP_BASE/archives/update"
  "$BACKUP_BASE/archives/monthly"
)

# remove_file <path>: delete one archive or jar. A file that cannot be removed
# is reported and skipped; one bad file must not abort the whole run (set -e)
# or hide the rest of the cleanup.
remove_file() {
  if rm -v -- "$1"; then
    return 0
  fi
  log "WARN: could not delete $1"
  return 1
}

# list_archives <dir> [oldest-first]: archive paths in a tier directory,
# newest first unless "oldest-first" is given.
list_archives() {
  local dir="$1" order="${2:-newest-first}" flags="-1t"
  [[ "$order" == "oldest-first" ]] && flags="-1tr"
  # shellcheck disable=SC2086  # $flags is one of two fixed literals
  ls $flags "$dir"/minecraft_backup_*.tar.{gz,zst} 2>/dev/null || true
}

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
  mapfile -t backups < <(list_archives "$dir")
  if (( ${#backups[@]} > max_value )); then
    for file in "${backups[@]:$max_value}"; do
      log "Deleting: $file"
      remove_file "$file" || true
    done
  else
    log "No $type backups to delete."
  fi
}

delete_old_hourly_backups() {
  local dir="$BACKUP_BASE/hourly"
  local max="${MAX_HOURLY_BACKUPS:-3}"

  log "Checking hourly backups in: $dir"
  mapfile -t snapshots < <(list_archives "$dir")
  if (( ${#snapshots[@]} > max )); then
    for file in "${snapshots[@]:$max}"; do
      log "Deleting old hourly backup: $file"
      remove_file "$file" || true
    done
  else
    log "No hourly backups to delete."
  fi
}

# Archives made before backup.sh kept real jars symlink into jars/, so a jar
# there is only garbage once no remaining archive links to it. Every archive
# folder counts, general and custom ones included: a jar referenced only by
# one of those used to be deleted after a day (S-002).
# Any archive that cannot be listed aborts the pruning: an unreadable archive
# might be the one that references the jar. Jars younger than a day are kept so
# a backup that has stored a jar but not yet finished its archive is safe.
prune_orphan_jars() {
  local jar_dir="$BACKUP_BASE/jars"
  [[ -d "$jar_dir" ]] || return 0

  log "Checking for orphaned jars in: $jar_dir"
  declare -A referenced=()
  local archive listing target
  [[ -d "$BACKUP_BASE/archives" ]] && {
    while IFS= read -r archive; do
      [[ -n "$archive" ]] || continue
      if [[ "$archive" == *.tar.zst ]]; then
        listing=$(zstd -d "$archive" -c 2>/dev/null | tar -tvf - 2>/dev/null) \
          || { log "WARN: cannot list $archive; skipping jar pruning."; return 0; }
      else
        listing=$(tar -tvzf "$archive" 2>/dev/null) \
          || { log "WARN: cannot list $archive; skipping jar pruning."; return 0; }
      fi
      while IFS= read -r target; do
        [[ -n "$target" ]] && referenced["${target##*/}"]=1
      done < <(printf '%s\n' "$listing" | sed -n 's/.* -> //p')
    done < <(find "$BACKUP_BASE/archives" -type f \( -name '*.tar.zst' -o -name '*.tar.gz' \) 2>/dev/null)
  }

  local jar removed=0
  while IFS= read -r jar; do
    [[ -n "$jar" ]] || continue
    [[ -n "${referenced[${jar##*/}]:-}" ]] && continue
    log "Deleting orphaned jar: $jar"
    remove_file "$jar" && removed=$((removed + 1))
  done < <(find "$jar_dir" -maxdepth 1 -type f -name '*.jar' -mmin +1440 2>/dev/null)
  log "Removed $removed orphaned jar(s)."
}

enforce_storage_limit() {
  [[ -z "$MAX_STORAGE_GB" || "$MAX_STORAGE_GB" -lt 1 ]] && {
    log "MAX_STORAGE_GB not set or invalid — skipping storage check."
    return
  }

  local max_bytes=$((MAX_STORAGE_GB * 1024 * 1024 * 1024))
  local current_bytes
  current_bytes=$(nice_run du -sb "$BACKUP_BASE" | cut -f1)

  log "Current backup usage: $((current_bytes / 1024 / 1024)) MB (limit: ${MAX_STORAGE_GB} GB)"
  log "Used space: $((current_bytes * 100 / (MAX_STORAGE_GB * 1024 * 1024 * 1024)))%"

  (( current_bytes <= max_bytes )) && return

  local dir file file_bytes
  for dir in "${STORAGE_EVICTION_DIRS[@]}"; do
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      # A file's own size, subtracted from the running total, tells us the
      # same thing a fresh `du -sb "$BACKUP_BASE"` would, without a full
      # recursive walk of the whole backups tree after every single deletion.
      file_bytes=$(stat -c%s "$file" 2>/dev/null || echo 0)
      log "Deleting (to free space): $file"
      remove_file "$file" || continue
      current_bytes=$((current_bytes - file_bytes))
      (( current_bytes <= max_bytes )) && return
    done < <(list_archives "$dir" oldest-first)
  done

  log "WARN: still above the ${MAX_STORAGE_GB} GB limit after evicting every archive."
}

# Apply policies
delete_old_hourly_backups
delete_old_archives "daily"   "MAX_DAILY_BACKUPS"
delete_old_archives "weekly"  "MAX_WEEKLY_BACKUPS"
delete_old_archives "monthly" "MAX_MONTHLY_BACKUPS"
delete_old_archives "update"  "MAX_UPDATE_BACKUPS"
prune_orphan_jars
enforce_storage_limit

log "Backup cleanup complete."
