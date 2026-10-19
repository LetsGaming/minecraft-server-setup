#!/bin/bash
# Undoing a failed run: restore the scripts from the archive, move the layout back, restart the server.
# Sourced by migrate.sh: functions and constants only, nothing runs when it is loaded.
# shellcheck disable=SC2154  # reads globals that migrate.sh and the other modules set

# From here on a failure must not leave the server down or its scripts half
# replaced. On any exit before the end, the scripts folder comes back from the
# archive above if this run touched it, and the server is started again if
# this run stopped it.
_MIGRATE_DONE=false
_MIGRATE_STOPPED_SERVER=false
_MIGRATE_SCRIPTS_TOUCHED=false
# What Step 3 changed, so a failure puts the old layout back.
_S3_INSTANCE_MOVED=false
_S3_VARS_PATCHED=false
_S3_UNIT_FILE=""
_S3_API_CFG_PATCHED=false
_S3_API_MOVED=false
_S3_API_UNIT_FILE=""

_undo_structural_migration() {
  local cfg dir
  if [[ -n "$_S3_API_UNIT_FILE" ]]; then
    sudo sed -i "s|${_new_api_dir}|${_old_api_dir}|g" "$_S3_API_UNIT_FILE" \
      && sudo systemctl daemon-reload || warn "Could not restore the paths in $_S3_API_UNIT_FILE"
  fi
  if $_S3_API_MOVED && [[ -d "$_new_api_dir" && ! -e "$_old_api_dir" ]]; then
    mv -- "$_new_api_dir" "$_old_api_dir" && log "Moved the API wrapper folder back to $_old_api_dir"
  fi
  if $_S3_API_CFG_PATCHED; then
    for dir in "$_old_api_dir" "$_new_api_dir"; do
      cfg="$dir/api-server-config.json"
      [[ -f "$cfg" ]] || continue
      node -e "
        const fs = require('fs');
        const cfg = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
        for (const inst of Object.values(cfg.instances || {})) {
          if (inst.serverPath === process.argv[2]) inst.serverPath = process.argv[3];
        }
        fs.writeFileSync(process.argv[1], JSON.stringify(cfg, null, 2) + '\n');
      " "$cfg" "$_new_instance_dir" "$_old_instance_dir" 2>/dev/null \
        || warn "Could not restore serverPath in $cfg"
      break
    done
  fi
  if [[ -n "$_S3_UNIT_FILE" ]]; then
    sudo sed -i "s|${_new_instance_dir}|${_old_instance_dir}|g" "$_S3_UNIT_FILE" \
      && sudo systemctl daemon-reload || warn "Could not restore the paths in $_S3_UNIT_FILE"
  fi
  if $_S3_VARS_PATCHED; then
    sed -i "s|SERVER_PATH=\"${_new_instance_dir}\"|SERVER_PATH=\"${_old_instance_dir}\"|" "$VARS_FILE"
  fi
  if $_S3_INSTANCE_MOVED && [[ -d "$_new_instance_dir" && ! -e "$_old_instance_dir" ]]; then
    mv -- "$_new_instance_dir" "$_old_instance_dir" && log "Moved the instance folder back to $_old_instance_dir"
  fi
}

_migrate_recover() {
  local rc=$?
  $_MIGRATE_DONE && return
  $DRY_RUN && return
  echo
  err "Migration stopped before it finished (exit $rc). Undoing what it changed..."
  [[ -n "${STAGING_SCRIPTS_DIR:-}" ]] && rm -rf -- "$STAGING_SCRIPTS_DIR"
  [[ -n "${PRESERVE_DIR:-}" ]] && rm -rf -- "$PRESERVE_DIR"
  # A swap interrupted between its two renames: the old tree is still whole.
  if [[ ! -e "$TARGET_SCRIPTS_DIR" && -d "${TARGET_SCRIPTS_DIR%/}.old.$$" ]]; then
    mv -- "${TARGET_SCRIPTS_DIR%/}.old.$$" "$TARGET_SCRIPTS_DIR"
  fi
  if $_MIGRATE_SCRIPTS_TOUCHED && [[ -f "$BACKUP_ARCHIVE" ]]; then
    local restore_dir
    restore_dir="${TARGET_SCRIPTS_DIR%/}.restore.$$"
    rm -rf -- "$restore_dir"
    mkdir -p -- "$restore_dir"
    if tar -C "$restore_dir" -xf "$BACKUP_ARCHIVE" \
      && [[ -d "$restore_dir/$(basename "$TARGET_SCRIPTS_DIR")" ]]; then
      rm -rf -- "${TARGET_SCRIPTS_DIR:?}"
      mv -- "$restore_dir/$(basename "$TARGET_SCRIPTS_DIR")" "$TARGET_SCRIPTS_DIR"
      rm -rf -- "$restore_dir"
      log "Scripts restored from $(basename "$BACKUP_ARCHIVE")"
    else
      rm -rf -- "$restore_dir"
      err "Could not restore the scripts. Do it by hand:"
      info "  rm -rf '$TARGET_SCRIPTS_DIR'"
      info "  tar -C '$(dirname "$TARGET_SCRIPTS_DIR")' -xf '$BACKUP_ARCHIVE'"
    fi
  fi
  _undo_structural_migration
  if $_MIGRATE_STOPPED_SERVER; then
    log "Starting '$INSTANCE_NAME' again..."
    sudo systemctl start "${INSTANCE_NAME}.service" 2>/dev/null \
      || warn "Could not start it: sudo systemctl start ${INSTANCE_NAME}.service"
  fi
}

install_recovery_trap() {
  trap _migrate_recover EXIT
  return 0
}
