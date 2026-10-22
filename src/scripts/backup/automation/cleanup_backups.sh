#!/bin/bash
set -e

CLEANUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CLEANUP_DIR/../../common/load_variables.sh"
source "$CLEANUP_DIR/../../common/utils.sh"
source "$CLEANUP_DIR/../../common/webhook.sh"
BK_COMPONENT=cleanup
source "$CLEANUP_DIR/../lib/bk_common.sh"
source "$CLEANUP_DIR/../lib/bk_state.sh"
source "$CLEANUP_DIR/../lib/bk_archive.sh"
source "$CLEANUP_DIR/../lib/bk_space.sh"

log() { bk_log INFO "$*"; }

MAKE_ROOM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --make-room)
      if [[ ! "${2:-}" =~ ^[0-9]+$ ]]; then
        bk_log ERROR "--make-room needs a number of bytes"
        exit 1
      fi
      MAKE_ROOM="$2"; shift 2 ;;
    --help)
      echo "Usage: $0 [--make-room <bytes>]"
      echo "Applies the retention policy; with --make-room evicts archives in tier order"
      echo "until <bytes> are free (exit 73 when that is not possible)."
      exit 0 ;;
    *) bk_log ERROR "Unknown argument: $1"; exit 1 ;;
  esac
done

# Deleting archives while a restore, rollback or upgrade reads them would pull
# the file out from under it. Retention simply runs again after the next backup.
if ! acquire_operation_lock cleanup; then
  log "Another operation is running; skipping backup cleanup."
  exit 0
fi

bk_load_config || exit 1
bk_probe_priority

BACKUP_BASE="$BACKUPS_PATH"
KNOWN_ARCHIVE_TYPES=(daily weekly monthly update)
# Legacy archives (no sidecar) are checked with a full decompression, which is
# the expensive part of a cleanup run; at most this many per run.
LEGACY_CHECKS_LEFT=2

# remove_file <path>: delete one archive or jar and its sidecar. A file that
# cannot be removed is reported and skipped; one bad file must not abort the
# whole run (set -e) or hide the rest of the cleanup.
remove_file() {
  if rm -v -- "$1"; then
    rm -f -- "$(bk_archive_sidecar_path "$1")" 2>/dev/null || true
    return 0
  fi
  bk_log WARN "could not delete $1"
  return 1
}

# list_archives <dir> [oldest-first]: archive paths in a tier directory,
# newest first unless "oldest-first" is given. The order comes from the
# timestamp in the file name (minecraft_backup_YYYY-MM-DD_HH-MM-SS), which a
# copy, a restore from another disk or a touch cannot change; a name without
# one is placed by its modification time.
list_archives() {
  local dir="$1" order="${2:-newest-first}" file base stamp
  local -a rows=()
  local re='([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})'
  for file in "$dir"/minecraft_backup_*.tar.gz "$dir"/minecraft_backup_*.tar.zst; do
    [[ -f "$file" ]] || continue
    base="${file##*/}"
    if [[ "$base" =~ $re ]]; then
      stamp="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}"
    else
      stamp="$(date -r "$file" +%Y%m%d%H%M%S)"
    fi
    rows+=("$stamp $file")
  done
  (( ${#rows[@]} > 0 )) || return 0
  if [[ "$order" == "oldest-first" ]]; then
    printf '%s\n' "${rows[@]}" | sort | cut -d' ' -f2-
  else
    printf '%s\n' "${rows[@]}" | sort -r | cut -d' ' -f2-
  fi
}

# archive_is_valid <file>: not empty and the compressed stream is intact. The
# sidecar written at publish time answers without reading the archive; an
# archive from before sidecars existed is tested once, niced, and gets a
# "verified-legacy" sidecar so the next run does not test it again.
archive_is_valid() {
  local file="$1" rc=0
  bk_archive_is_valid_quick "$file" || rc=$?
  (( rc == 0 )) && return 0
  (( rc == 1 )) && return 1
  (( LEGACY_CHECKS_LEFT > 0 )) || return 1
  LEGACY_CHECKS_LEFT=$((LEGACY_CHECKS_LEFT - 1))
  case "$file" in
    *.tar.zst) bk_nice zstd -t "$file" > /dev/null 2>&1 || return 1 ;;
    *.tar.gz) bk_nice gzip -t "$file" > /dev/null 2>&1 || return 1 ;;
    *) return 1 ;;
  esac
  bk_archive_write_sidecar "$file" "verified-legacy  ${file##*/}" 2>/dev/null || true
  return 0
}

# protected_archive <dir>: the newest valid archive of a tier, which is never
# deleted, so retention can thin a tier out but not empty it of anything usable.
protected_archive() {
  local file
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if archive_is_valid "$file"; then
      echo "$file"
      return 0
    fi
  done < <(list_archives "$1")
  return 0
}

# delete_surplus <dir> <keep-count> <label>
delete_surplus() {
  local dir="$1" max_value="$2" label="$3" file keep
  local -a backups=()
  mapfile -t backups < <(list_archives "$dir")
  if (( ${#backups[@]} <= max_value )); then
    log "No $label backups to delete."
    return 0
  fi
  keep="$(protected_archive "$dir")"
  for file in "${backups[@]:$max_value}"; do
    if [[ "$file" == "$keep" ]]; then
      log "Keeping $file: it is the newest valid $label backup."
      continue
    fi
    log "Deleting: $file"
    remove_file "$file" || true
  done
}

delete_old_archives() {
  local type="$1"
  local max_var="$2"
  local dir="$BACKUP_BASE/archives/$type"
  local max_value="${!max_var:-}"

  # A bad value skips this tier only; the rest of the cleanup still runs.
  [[ "$max_value" =~ ^[0-9]+$ ]] || {
    bk_log WARN "$max_var is not set or invalid (value: '$max_value'); skipping the $type count cap"
    return 0
  }
  # 0 means no count limit (S-030); MAX_STORAGE_GB still applies.
  if (( max_value == 0 )); then
    log "$max_var is 0: keeping every $type backup (the storage limit still applies)."
    return
  fi

  log "Checking $type backups in: $dir"
  delete_surplus "$dir" "$max_value" "$type"
}

# The archive folders that are not one of the named tiers.
custom_archive_dirs() {
  local dir name known
  [[ -d "$BACKUP_BASE/archives" ]] || return 0
  for dir in "$BACKUP_BASE"/archives/*/; do
    [[ -d "$dir" ]] || continue
    dir="${dir%/}"
    name="${dir##*/}"
    for known in "${KNOWN_ARCHIVE_TYPES[@]}"; do
      [[ "$name" == "$known" ]] && continue 2
    done
    echo "$dir"
  done
}

delete_old_custom_archives() {
  local dir
  if [[ ! "$MAX_CUSTOM_BACKUPS" =~ ^[0-9]+$ ]]; then
    bk_log WARN "MAX_CUSTOM_BACKUPS is invalid (value: '$MAX_CUSTOM_BACKUPS'); skipping the custom count cap"
    return 0
  fi
  if (( MAX_CUSTOM_BACKUPS == 0 )); then
    log "MAX_CUSTOM_BACKUPS is 0: keeping every general and custom archive (the storage limit still applies)."
    return
  fi
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    log "Checking ${dir##*/} backups in: $dir"
    delete_surplus "$dir" "$MAX_CUSTOM_BACKUPS" "${dir##*/}"
  done < <(custom_archive_dirs)
}

delete_old_hourly_backups() {
  local dir="$BACKUP_BASE/hourly"
  local max="${MAX_HOURLY_BACKUPS:-3}"

  # 0 means no count limit (S-030). It used to mean "keep none" and deleted
  # every hourly backup, the newest one included.
  if [[ ! "$max" =~ ^[0-9]+$ ]] || (( max == 0 )); then
    log "MAX_HOURLY_BACKUPS is ${max:-unset}: no count limit on hourly backups (the storage limit still applies)."
    return
  fi

  log "Checking hourly backups in: $dir"
  delete_surplus "$dir" "$max" "hourly"
}

# Archives made before backup.sh kept real jars symlink into jars/, so a jar
# there is only garbage once no remaining archive links to it. Every archive
# folder counts, general and custom ones included (S-002). Any archive that
# cannot be listed aborts the pruning: an unreadable archive might be the one
# that references the jar. Jars younger than a day are kept so a backup that
# has stored a jar but not yet finished its archive is safe.
# Listing every archive means decompressing every one of them, so it happens
# only when a jar is old enough to be a candidate, and at most once a day.
prune_orphan_jars() {
  local jar_dir="$BACKUP_BASE/jars"
  [[ -d "$jar_dir" ]] || return 0

  local -a candidates=()
  mapfile -t candidates < <(find "$jar_dir" -maxdepth 1 -type f -name '*.jar' -mmin +1440 2>/dev/null)
  if (( ${#candidates[@]} == 0 )); then
    if [[ -z "$(ls -A "$jar_dir" 2>/dev/null)" ]]; then
      rmdir -- "$jar_dir" 2>/dev/null && log "Removed the empty legacy jars/ folder."
    fi
    return 0
  fi
  local today
  today="$(date +%F)"
  if bk_state_flag_exists "jarscan_$today"; then
    log "Orphaned jars were already checked today; skipping."
    return 0
  fi

  log "Checking for orphaned jars in: $jar_dir"
  declare -A referenced=()
  local archive target
  [[ -d "$BACKUP_BASE/archives" ]] && {
    while IFS= read -r archive; do
      [[ -n "$archive" ]] || continue
      local tmp_list
      tmp_list="$(mktemp "${TMPDIR:-/tmp}/jarscan.XXXXXX")"
      if [[ "$archive" == *.tar.zst ]]; then
        ( set -o pipefail; bk_nice zstd -dc "$archive" 2>/dev/null | bk_nice tar -tvf - 2>/dev/null | sed -n 's/.* -> //p' > "$tmp_list" ) \
          || { rm -f -- "$tmp_list"; bk_log WARN "cannot list $archive; skipping jar pruning."; return 0; }
      else
        ( set -o pipefail; bk_nice tar -tvzf "$archive" 2>/dev/null | sed -n 's/.* -> //p' > "$tmp_list" ) \
          || { rm -f -- "$tmp_list"; bk_log WARN "cannot list $archive; skipping jar pruning."; return 0; }
      fi
      while IFS= read -r target; do
        [[ -n "$target" ]] && referenced["${target##*/}"]=1
      done < "$tmp_list"
      rm -f -- "$tmp_list"
    done < <(find "$BACKUP_BASE/archives" -type f \( -name 'minecraft_backup_*.tar.zst' -o -name 'minecraft_backup_*.tar.gz' \) 2>/dev/null)
  }

  local jar removed=0
  for jar in "${candidates[@]}"; do
    [[ -n "${referenced[${jar##*/}]:-}" ]] && continue
    log "Deleting orphaned jar: $jar"
    remove_file "$jar" && removed=$((removed + 1))
  done
  log "Removed $removed orphaned jar(s)."
  bk_state_flag_touch "jarscan_$today"
  if [[ -z "$(ls -A "$jar_dir" 2>/dev/null)" ]]; then
    rmdir -- "$jar_dir" 2>/dev/null && log "Removed the empty legacy jars/ folder."
  fi
  return 0
}

# The pre-restore copy a restore or rollback kept is deleted after
# RESTORE_KEEP_OLD_DAYS (0 keeps it until the next restore replaces it).
expire_pre_restore() {
  local kept="${SERVER_PATH%/}.pre-restore" days="${RESTORE_KEEP_OLD_DAYS:-7}"
  [[ -d "$kept" ]] || return 0
  [[ "$days" =~ ^[0-9]+$ ]] && (( days > 0 )) || return 0
  if [[ -n "$(find "$kept" -maxdepth 0 -mtime +"$((days - 1))" 2>/dev/null)" ]]; then
    log "Deleting the pre-restore copy kept more than $days days ago: $kept"
    rm -rf -- "$kept" || bk_log WARN "could not delete $kept"
  fi
  return 0
}

# Eviction order when the storage limit is exceeded: the cheapest-to-lose tier
# first, oldest archive first within a tier. General and custom archives come
# after the named tiers. Monthly archives are the long-term history and go
# last, so they are never evicted while any other archive remains.
storage_eviction_dirs() {
  echo "$BACKUP_BASE/hourly"
  echo "$BACKUP_BASE/archives/daily"
  echo "$BACKUP_BASE/archives/weekly"
  echo "$BACKUP_BASE/archives/update"
  custom_archive_dirs
  echo "$BACKUP_BASE/archives/monthly"
}

# evict_until <bytes-to-free> <label>: deletes archives in eviction order until
# that many bytes were freed, never the newest valid archive of a tier. A file
# with more than one hard link frees nothing when deleted. Leaves the bytes
# freed in EVICTED_BYTES; returns 1 when the target was not reached.
EVICTED_BYTES=0
evict_until() {
  local target="$1" label="$2" freed=0 dir file file_bytes keep links
  EVICTED_BYTES=0
  while IFS= read -r dir; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    keep="$(protected_archive "$dir")"
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      if [[ "$file" == "$keep" ]]; then
        log "Keeping $file: it is the newest valid backup of its kind."
        continue
      fi
      file_bytes=$(bk_file_size "$file")
      links=$(bk_link_count "$file")
      (( links > 1 )) && file_bytes=0
      log "Deleting ($label): $file"
      remove_file "$file" || continue
      freed=$((freed + file_bytes))
      EVICTED_BYTES=$freed
      (( freed >= target )) && return 0
    done < <(list_archives "$dir" oldest-first)
  done < <(storage_eviction_dirs)
  return 1
}

enforce_storage_limit() {
  [[ -z "${MAX_STORAGE_GB:-}" || ! "$MAX_STORAGE_GB" =~ ^[0-9]+$ || "$MAX_STORAGE_GB" -lt 1 ]] && {
    log "MAX_STORAGE_GB not set or invalid, skipping the storage check."
    return
  }

  local max_bytes=$((MAX_STORAGE_GB * 1024 * 1024 * 1024))
  local current_bytes
  # Staging (.stage), the sidecars (.meta), a legacy backup in flight
  # (tmp_backup) and the legacy jars/ folder are not archives that eviction
  # could free, and counting them would make a healthy run look like an overflow.
  current_bytes=$(bk_nice du -sb --exclude=tmp_backup --exclude=jars --exclude=.stage --exclude=.meta "$BACKUP_BASE" | cut -f1)

  log "Current backup usage: $((current_bytes / 1024 / 1024)) MB (limit: ${MAX_STORAGE_GB} GB)"
  log "Used space: $((current_bytes * 100 / (MAX_STORAGE_GB * 1024 * 1024 * 1024)))%"

  (( current_bytes <= max_bytes )) && return

  if evict_until $((current_bytes - max_bytes)) "to free space"; then
    return
  fi
  current_bytes=$((current_bytes - EVICTED_BYTES))
  bk_log WARN "still above the ${MAX_STORAGE_GB} GB limit after evicting every archive that may be evicted."
  notify_warning "storage_warning" "Backups use $((current_bytes / 1024 / 1024)) MB, still above the ${MAX_STORAGE_GB} GB limit after evicting every archive that may be evicted."
  wait_for_notifications
}

# --make-room <bytes>: called by the backup preflight before a run that would
# not fit. Evicts until that much is free on the backups filesystem.
make_room() {
  local want="$1" avail short
  avail="$(bk_space_available "$BACKUP_BASE")" || { bk_log WARN "Cannot measure free space"; return 0; }
  if (( avail >= want )); then
    log "Already $(bk_human_bytes "$avail") free; nothing to evict."
    return 0
  fi
  short=$((want - avail))
  log "Need $(bk_human_bytes "$short") more free space; evicting in tier order."
  if evict_until "$short" "to make room"; then
    log "Freed $(bk_human_bytes "$EVICTED_BYTES")."
    return 0
  fi
  bk_log ERROR "Could not free enough space: $(bk_human_bytes "$EVICTED_BYTES") freed, $(bk_human_bytes "$short") needed."
  return "$BK_EX_NOSPACE"
}

if [[ -n "$MAKE_ROOM" ]]; then
  make_room "$MAKE_ROOM"
  exit $?
fi

log "Starting backup cleanup..."
delete_old_hourly_backups
delete_old_archives "daily"   "MAX_DAILY_BACKUPS"
delete_old_archives "weekly"  "MAX_WEEKLY_BACKUPS"
delete_old_archives "monthly" "MAX_MONTHLY_BACKUPS"
delete_old_archives "update"  "MAX_UPDATE_BACKUPS"
delete_old_custom_archives
prune_orphan_jars
expire_pre_restore
enforce_storage_limit

log "Backup cleanup complete."
