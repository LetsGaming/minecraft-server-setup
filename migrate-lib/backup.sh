#!/bin/bash
# The pre-migration archive (step 1) and keeping only the newest few.
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

# Step 1.
create_backup() {
  BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  BACKUP_PARENT="$(dirname "$TARGET_SCRIPTS_DIR")"
  BACKUP_BASE="$(basename "$TARGET_SCRIPTS_DIR")_backup_${BACKUP_TIMESTAMP}"

  echo -e "${BOLD}Step 1: Backup${NC}"
  # Written under a .part name and renamed only after a full listing passed,
  # so a tar that died midway never counts as one of the "newest N" archives.
  local part rc=0
  if $USE_ZSTD; then
    BACKUP_ARCHIVE="${BACKUP_PARENT}/${BACKUP_BASE}.tar.zst"
    part="${BACKUP_PARENT}/.${BACKUP_BASE}.tar.zst.part"
    log "Creating archive: $(basename "$BACKUP_ARCHIVE")"
    # umask 077 (S-029): the archive holds common/variables.txt and its secrets.
    ( umask 077; run_cmd tar -C "$BACKUP_PARENT" -I 'zstd -3' -cf "$part" "$(basename "$TARGET_SCRIPTS_DIR")" ) || rc=$?
  else
    BACKUP_ARCHIVE="${BACKUP_PARENT}/${BACKUP_BASE}.tar.gz"
    part="${BACKUP_PARENT}/.${BACKUP_BASE}.tar.gz.part"
    log "Creating archive: $(basename "$BACKUP_ARCHIVE")"
    ( umask 077; run_cmd tar -C "$BACKUP_PARENT" -czf "$part" "$(basename "$TARGET_SCRIPTS_DIR")" ) || rc=$?
  fi
  $DRY_RUN && return 0
  if (( rc != 0 )); then
    rm -f -- "$part"
    err "Creating the archive failed (tar exit $rc)."
    return 1
  fi
  if $USE_ZSTD; then
    ( set -o pipefail; zstd -dc "$part" | tar -tf - > /dev/null ) 2>/dev/null || rc=1
  else
    tar -tzf "$part" > /dev/null 2>&1 || rc=1
  fi
  if (( rc != 0 )); then
    rm -f -- "$part"
    err "The archive does not list cleanly; removed."
    return 1
  fi
  mv -f -- "$part" "$BACKUP_ARCHIVE"
  [[ -f "$BACKUP_ARCHIVE" ]] && info "Archive size: $(du -sk "$BACKUP_ARCHIVE" | cut -f1)KB"
  return 0
}

# Every run leaves a <scripts>_backup_<stamp> archive next to the scripts
# folder. Keep the newest few (MIGRATE_KEEP_ARCHIVES, default 5; 0 keeps all),
# this run's included.
prune_old_migration_archives() {
  local keep="${MIGRATE_KEEP_ARCHIVES:-5}" name file base count=0
  [[ "$keep" =~ ^[0-9]+$ ]] && (( keep > 0 )) || return 0
  $DRY_RUN && return 0
  name="$(basename "$TARGET_SCRIPTS_DIR")"
  while IFS= read -r file; do
    base="${file##*/}"
    # Exactly <name>_backup_YYYYMMDD_HHMMSS: another instance whose name starts
    # with this one's is not matched.
    [[ "$base" == "${name}_backup_"???????????????.tar.* ]] || continue
    count=$((count + 1))
    if (( count > keep )) && [[ "$file" != "$BACKUP_ARCHIVE" ]]; then
      rm -f -- "$file" && info "Removed old archive: $base"
    fi
  done < <(ls -1 "$BACKUP_PARENT/${name}"_backup_*.tar.* 2>/dev/null | sort -r)
}
